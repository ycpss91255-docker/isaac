#!/usr/bin/env python3
"""Generate the consolidated 6.0.1 physics re-validation review PDF (zh-TW).

One multi-page PDF holding, for EVERY reviewed experiment, a quantitative data
TABLE (not a single number) that is:
  * traceable to its log     -- each page prints the source JSON path + sha256,
  * reproducible             -- each page prints the exact container command,
  * post-audit corrected     -- verdict + corrected conclusion from the
                                2026-09 adversarial physics-validity audit and
                                the subsequent driver fixes / re-runs.

Body text is zh-TW (this is cyc's acceptance doc, not a git artifact). Rendered
with matplotlib (PdfPages) using the container's Noto Sans CJK font -- no
network, no extra deps beyond what Isaac ships.

Run inside the devel container (matplotlib + Noto CJK present)::

    W=/home/<user>/work/worktree/<wt>          # this worktree (logs live here)
    # canonical output goes to the isaac_ws-level doc/ (container /home/<user>/work/doc):
    just exec -t devel /isaac-sim/python.sh $W/test/gen_review_pdf.py \\
        --test-dir $W/test --out /home/<user>/work/doc/6.0.1_physics_revalidation_review.pdf
"""

import argparse
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
from matplotlib import font_manager
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

# Treat text literally: reproduce commands contain '$', '_', '--'.
matplotlib.rcParams["text.parse_math"] = False
matplotlib.rcParams["axes.unicode_minus"] = False

# Register a CJK font so zh-TW renders (not tofu). The Isaac container ships NO
# CJK font, so the font is loaded by PATH: --font, else a copy vendored next to
# this script (test/.notocjk.ttc), else the host Noto paths (present only if the
# container has them). The committed PDF embeds a subset, so it renders CJK
# without the font; regenerating needs the font present.
_CJK_NAME = "DejaVu Sans"


def _init_cjk_font(font_arg, test_dir):
    global _CJK_NAME
    cands = []
    if font_arg:
        cands.append(font_arg)
    cands += [
        str(Path(test_dir) / ".notocjk.ttc"),
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    ]
    for fp in cands:
        if not Path(fp).is_file():
            continue
        try:
            font_manager.fontManager.addfont(fp)
            _CJK_NAME = font_manager.FontProperties(fname=fp).get_name()
            break
        except Exception:  # noqa: BLE001
            continue
    matplotlib.rcParams["font.family"] = "sans-serif"
    matplotlib.rcParams["font.sans-serif"] = [_CJK_NAME, "DejaVu Sans"]
    # Monospace text (reproduce commands) may carry CJK notes -> glyph fallback.
    matplotlib.rcParams["font.monospace"] = ["DejaVu Sans Mono", _CJK_NAME]

W = "$W"  # = /home/<user>/work/worktree/<wt> ; see the methodology page.
PY = f"just exec -t devel env PYTHONPATH={W}/framework /isaac-sim/python.sh"


def _sha256(path):
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]
    except Exception:  # noqa: BLE001
        return "MISSING"


def _load(test_dir, name):
    p = Path(test_dir) / name
    try:
        return json.loads(p.read_text())
    except Exception as exc:  # noqa: BLE001
        return {"__load_error__": f"{type(exc).__name__}: {exc}"}


def f(x, nd=4):
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, (int, float)):
        ax = abs(x)
        if x != 0 and (ax < 1e-3 or ax >= 1e5):
            return f"{x:.3e}"
        return f"{x:.{nd}f}"
    return str(x)


# ---------------------------------------------------------------------------
# Per-experiment table extractors: each returns (columns, rows). Numbers only;
# note rows carry short zh-TW labels.
# ---------------------------------------------------------------------------
def t_212(d):
    cols = ["k (N/m)", "下垂 (mm)", "mg/k 預測 (mm)", "k_eff/k", "drift (mm)"]
    rows = []
    for p in d.get("points", []):
        dr = p["droop_mm"]
        ratio = p["predicted_mm"] / dr if dr else float("nan")
        rows.append([f(p["stiffness"]), f(dr), f(p["predicted_mm"]),
                     f(ratio, 3), f(p["drift_mm"])])
    dc = d.get("damping_control", {})
    rows.append(["--- 阻尼對照 @ k=%s (mg/k=%s mm) ---"
                 % (f(dc.get("fixed_stiffness")), f(dc.get("predicted_mm"))),
                 "", "", "", ""])
    for p in dc.get("points", []):
        rows.append([f"factor {f(p['damping_factor'],2)} (d={f(p['damping'],1)})",
                     f(p["droop_mm"]), f(dc.get("predicted_mm")), "",
                     f(p["drift_mm"])])
    rows.append([f"擺幅={f(dc.get('droop_spread_mm'))} mm -> {dc.get('verdict')}",
                 "", "", "", ""])
    return cols, rows


def t_215(d):
    cols = ["物體 (link 類)", "max 位置誤差 (m)", "max 角誤差 (deg)",
            "pusher frames", "零誤差"]
    rows = [[f"{b['name']} ({b['kind']})", f(b["max_pos_err_m"]),
             f(b["max_ang_err_deg"]), str(b["pusher_carried_frames"]),
             str(b["zero_error"])] for b in d.get("bodies", [])]
    rows.append([f"all_zero_error = {d.get('all_zero_error')}", "", "", "", ""])
    return cols, rows


def t_216(d):
    cols = ["k (N/m)", "穩態誤差 (mrad)", "RMS 追蹤 (mrad)", "備註"]
    rows = []
    for p in d.get("stiffness_sweep", []):
        sp = p.get("step_phase", {})
        sse_rad = sp.get("steady_state_error_rad")
        rows.append([f(p.get("stiffness_stored")),
                     f(sse_rad * 1000.0 if sse_rad is not None else None),
                     "", "revolute 繞 +Z (重力零力矩)"])
    rep = d.get("repeatability", {})
    rms = rep.get("rms_tracking_error_rad_per_run", [None])
    rows.append([f"重複性 k={f(rep.get('ref_stiffness'))}",
                 "", f((rms[0] or 0) * 1000.0), "3 runs, spread %s mrad"
                 % f(rep.get("rms_spread_mrad"))])
    return cols, rows


def t_219(d):
    cols = ["子測", "case", "結果", "撐住/夾住"]
    rows = []
    for p in d.get("effort_clamp", {}).get("points", []):
        rows.append(["力矩飽和",
                     "maxForce=%sN (%.2gx 重量)" % (f(p["max_force_N"]),
                                                    p["max_force_vs_load"]),
                     "下垂=%s mm" % f(p["droop_mm"]),
                     "撐住" if p["held_target"] else "STALL@limit"])
    vc = d.get("velocity_clamp", {})
    rows.append(["速度夾", "limit 0.3 vs 1000",
                 "峰速 %s -> %s m/s" % (f(vc.get("high_limit_peak_velocity")),
                                       f(vc.get("low_limit_peak_velocity"))),
                 str(vc.get("clamp_confirmed"))])
    pl = d.get("position_limit", {})
    rows.append(["行程極限",
                 "命令 %s m, upper %s m" % (f(pl.get("commanded_target_m")),
                                            f(pl.get("upper_limit_m"))),
                 "停在 %s m" % f(pl.get("settled_position_m")),
                 str(pl.get("clamped_at_limit"))])
    si = d.get("solver_iterations", {})
    rows.append(["solver 迭代", "1 / 4 / 32",
                 "下垂擺幅 %s mm" % f(si.get("droop_spread_mm")),
                 "與迭代無關=%s" % (not si.get("sensitive_to_iterations"))])
    for c in d.get("gain_scaling_pi_over_180", {}).get("cases", []):
        rows.append(["gain 換算", "%s (%s)" % (c["joint_kind"], c["drive_axis"]),
                     "stored/Kp=%s" % f(c["ratio_stored_over_Kp"]),
                     "符合=%s" % c["matches_expected"]])
    return cols, rows


def t_218(d):
    cols = ["mu", "最大乾淨載步 (m)", "最小滑脫步 (m)", "解析 d_crit (m)",
            "monotonic"]
    rows = []
    for _key, v in sorted(d.get("threshold_by_friction", {}).items()):
        rows.append([f(v["mu"], 2), f(v["max_carried_ramp_step_m"]),
                     f(v["min_slipped_ramp_step_m"]), f(v["analytic_d_crit_m"]),
                     str(v["carried_slipped_monotonic"])])
    rows.append([f"friction_monotonic = {d.get('friction_monotonic')}",
                 "", "", "", ""])
    return cols, rows


def t_220(d):
    cols = ["物體", "指標", "數值"]
    pl = d.get("plate", {})
    cu = d.get("cube", {})
    fp = cu.get("final_pos_m", [None])
    bp = cu.get("baseline_pos_m", [None])
    disp = (fp[0] - bp[0]) if (fp[0] is not None and bp[0] is not None) else None
    rows = [
        ["plate (kinematic)", "接觸時 max 位置誤差 (m)",
         f(pl.get("max_pos_err_contact_m")) + "  [float32 地板; 定義使然]"],
        ["plate (kinematic)", "接觸 frames", str(pl.get("contact_frames"))],
        ["cube (dynamic)", "位移 x (m)", f(disp) + "  [真的被推動]"],
        ["傳遞", "one_way_transfer_ok", str(d.get("one_way_transfer_ok"))],
    ]
    return cols, rows


def t_221(d):
    cols = ["質量 (kg)", "static give |z| (m)", "", ""]
    rows = []
    gm = d.get("give_rises_with_mass", {}).get("rigid", {})
    for m, g in zip(gm.get("masses_kg", []), gm.get("static_give_norm_m", [])):
        rows.append([f(m), f(g), "", ""])
    rows.append(["--- give 在 1000x 質量下逐位元相同 => 在 float32 地板下 ---",
                 "", "", ""])
    rows.append(["上界: give < ~2e-7 m @ 9810 N", "=> 接縫剛度",
                 "> ~5e10 N/m", ""])
    rows.append(["compliant_confirmed=%s  force_transfer_ok=%s"
                 % (d.get("compliant_confirmed"), d.get("force_transfer_ok")),
                 "鏈式版(#308): SIGSEGV, 沒跑成", "", ""])
    return cols, rows


def t_227(d):
    cols = ["joint", "撐重 (kg)", "下垂 (mm)", "mg/k 預測 (mm)", "drift (mm)"]
    rows = []
    for p in d.get("chain", {}).get("per_joint", []):
        rows.append([p["joint"], f(p["supported_mass_kg"]), f(p["sag_mm"]),
                     f(p["predicted_mm"]), f(p["drift_mm"])])
    cp = d.get("coupling", {})
    rows.append(["耦合: 移 %s 到 %s m, 差 %s mm"
                 % (cp.get("moved_joint"), f(cp.get("moved_target_m")),
                    f(cp.get("moved_reached_mm_short"))), "", "", "", ""])
    return cols, rows


def t_229(d):
    cols = ["lane", "底盤位移 (m)", "arm 位移 (m)", "follow ratio", "帶得動"]
    rows = []
    for ln in d.get("lanes", []):
        rows.append([ln["tag"], f(ln["base_travel_x_m"]),
                     f(ln["arm_root_travel_x_m"]), f(ln["follow_ratio"]),
                     str(ln["topology_A_carries"])])
    rows.append([f"finding: {d.get('finding')}", "", "", "", ""])
    return cols, rows


def t_d1(d):
    cols = ["k (N/m)", "箱子位移 (m)", "接觸 back-off (mm)",
            "no-cube 落後 (mm)", "純接觸反作用 (mm)"]
    rows = []
    for p in d.get("points", []):
        rows.append([f(p["stiffness"]), f(p["cube_displacement_x_m"]),
                     f(p["backoff_contact_mm"]),
                     f(p["control_following_lag_mm"]),
                     f(p["contact_reaction_mm"])])
    rows.append(["feed-forward=%s; 純接觸反作用 = back-off - no-cube 對照"
                 % d.get("feedforward"), "", "", "", ""])
    return cols, rows


def t_d2(d, d_fine):
    cols = ["k (N/m)", "payload lag std-dt (mm)", "payload lag fine-dt (mm)",
            "交付OK(std)", "載台誤差 (mm)"]
    fine = {p["stiffness"]: p for p in (d_fine or {}).get("points", [])}
    rows = []
    for p in d.get("points", []):
        fp = fine.get(p["stiffness"], {})
        rows.append([f(p["stiffness"]), f(p["payload_lag_mm"]),
                     f(fp.get("payload_lag_mm")), str(p["delivery_ok"]),
                     f(p["carrier_track_err_max_mm"])])
    rows.append(["std dt=%s ; fine dt=%s (4x): 高 k slip 隨 dt 細化而崩塌"
                 % (f(d.get("physics_dt")), f((d_fine or {}).get("physics_dt"))),
                 "", "", "", ""])
    return cols, rows


def t_colA(d):
    cols = ["collider prim", "type", "解析box", "meshAPI", "approx", "world xyz"]
    rows = []
    for c in d.get("colliders", []):
        rows.append([c["path"].split("/")[-1], c["type"],
                     str(c["is_analytic_cube"]),
                     str(c["has_mesh_collision_api"]), str(c["approximation"]),
                     str(c.get("world_translate"))])
    rows.append(["A1 三個都保留=%s  A2 全解析box無hull=%s  Scope分組=%s"
                 % (d.get("A1_all_three_kept"),
                    d.get("A2_all_analytic_boxes_no_hull"),
                    d.get("colliders_grouped_under_scope")),
                 "", "", "", "", ""])
    return cols, rows


def t_colB(d):
    cols = ["lane", "approximation", "maxHulls", "探針最終z (m)", "進入口袋"]
    rows = []
    for ln in d.get("lanes", []):
        rows.append([ln["lane"], ln["approximation"],
                     str(ln["max_convex_hulls"]), f(ln["probe_final_z_m"]),
                     str(ln["entered_pocket"])])
    rows.append(["slot=%sm probe=%sm; entered if z<%s (wall_top=%s base=%s)"
                 % (f(d.get("slot_width_m")), f(d.get("probe_width_m")),
                    f(d.get("enter_z_threshold_m")), f(d.get("wall_top_z_m")),
                    f(d.get("base_top_z_m"))), "", "", "", ""])
    return cols, rows


# ---------------------------------------------------------------------------
# Charts: for subtle (mm/um/nm-scale, near-static) experiments a plot conveys
# the quantitative story better than a video ever could. Each draws onto a fig.
# ---------------------------------------------------------------------------
_NAVY = "#1f3b57"


def _sci(v, _pos):
    """Plain-text power-of-ten tick label (mathtext is globally off)."""
    import math
    if v <= 0:
        return ""
    e = int(round(math.log10(v)))
    if abs(v - 10.0 ** e) <= 1e-6 * max(1.0, v):
        return "1" if e == 0 else ("1e%d" % e)
    return "%g" % v


def _fix_log(ax, which="both"):
    from matplotlib.ticker import FuncFormatter, NullFormatter
    fmt = FuncFormatter(_sci)
    axes = {"x": [ax.xaxis], "y": [ax.yaxis], "both": [ax.xaxis, ax.yaxis]}[which]
    for a in axes:
        a.set_major_formatter(fmt)
        a.set_minor_formatter(NullFormatter())


def _chart_212(fig, d):
    pts = d.get("points", [])
    ax1 = fig.add_axes([0.13, 0.55, 0.78, 0.33])
    k = [p["stiffness"] for p in pts]
    ax1.loglog(k, [p["predicted_mm"] for p in pts], "o--", color="#999",
               label="mg/k 預測")
    ax1.loglog(k, [p["droop_mm"] for p in pts], "s-", color=_NAVY,
               label="實測下垂")
    ax1.set_xlabel("剛度 k (N/m)")
    ax1.set_ylabel("下垂 (mm)")
    ax1.set_title("下垂 vs 剛度:高 k 低於 mg/k 預測", fontsize=10)
    ax1.legend(fontsize=8)
    ax1.grid(True, which="both", alpha=0.3)
    _fix_log(ax1, "both")
    dc = d.get("damping_control", {})
    dp = dc.get("points", [])
    ax2 = fig.add_axes([0.13, 0.10, 0.78, 0.30])
    if dp:
        ax2.axhline(dc.get("predicted_mm") or 0, color="#c0392b", ls="--",
                    label="mg/k(此處下垂應為定值)")
        ax2.axhline(0, color="#bbb", lw=0.6)
        ax2.plot([p["damping_factor"] for p in dp], [p["droop_mm"] for p in dp],
                 "o-", color=_NAVY, label="實測下垂")
        ax2.set_xlabel("阻尼倍數 (x critical) @ k=%.0e"
                       % (dc.get("fixed_stiffness") or 0))
        ax2.set_ylabel("下垂 (mm)")
        ax2.set_title("阻尼對照:下垂隨阻尼擺動 -> solver 假象", fontsize=10)
        ax2.legend(fontsize=8)
        ax2.grid(True, alpha=0.3)


def _chart_d2(fig, d, dfine):
    ax = fig.add_axes([0.13, 0.12, 0.78, 0.76])
    pts = d.get("points", [])
    fine = {p["stiffness"]: p for p in (dfine or {}).get("points", [])}
    k = [p["stiffness"] for p in pts]
    ax.semilogx(k, [p["payload_lag_mm"] for p in pts], "s-", color="#c0392b",
                label="payload lag @ dt=1/60")
    ax.semilogx(k, [fine.get(p["stiffness"], {}).get("payload_lag_mm", 0)
                    for p in pts], "o-", color=_NAVY,
                label="payload lag @ dt=1/240(4x 細)")
    ax.set_xlabel("載台 drive 剛度 k (N/m)")
    ax.set_ylabel("payload 交付落後 (mm)")
    ax.set_title("載運:高 k 的 payload 滑動是 (k*dt) 假象,dt 細化即崩塌",
                 fontsize=10)
    ax.legend(fontsize=8)
    ax.grid(True, which="both", alpha=0.3)
    _fix_log(ax, "x")


def _chart_227(fig, d):
    import numpy as np
    ax = fig.add_axes([0.12, 0.12, 0.80, 0.76])
    per = d.get("chain", {}).get("per_joint", [])
    names = [p["joint"] for p in per]
    x = np.arange(len(names))
    ax.bar(x - 0.19, [p["predicted_mm"] for p in per], 0.38, color="#999",
           label="mg/k 預測")
    ax.bar(x + 0.19, [p["sag_mm"] for p in per], 0.38, color=_NAVY,
           label="實測下垂")
    ax.set_xticks(x)
    ax.set_xticklabels(names)
    ax.set_ylabel("各節下垂 (mm)")
    ax.set_title("多關節下垂:各節實測 ~= 預測", fontsize=10)
    ax.legend(fontsize=8)
    ax.grid(True, axis="y", alpha=0.3)


def _chart_218(fig, d):
    ax = fig.add_axes([0.12, 0.12, 0.80, 0.76])
    tb = d.get("threshold_by_friction", {})
    items = sorted(tb.values(), key=lambda v: v["mu"])
    mu = [v["mu"] for v in items]
    ax.plot(mu, [v["analytic_d_crit_m"] for v in items], "o--", color="#999",
            label="解析 d_crit = dt*sqrt(2*mu*g*L)")
    ax.plot(mu, [v["max_carried_ramp_step_m"] for v in items], "^-",
            color="#2e7d32", label="最大乾淨載運步")
    ax.plot(mu, [v["min_slipped_ramp_step_m"] for v in items], "v-",
            color="#c0392b", label="最小滑脫步")
    ax.set_xlabel("摩擦係數 mu")
    ax.set_ylabel("每 tick 載運步 (m)")
    ax.set_title("kinematic 載運門檻隨 mu 上升(對上解析式)", fontsize=10)
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)


def _chart_221(fig, d):
    ax = fig.add_axes([0.13, 0.12, 0.78, 0.76])
    gm = d.get("give_rises_with_mass", {}).get("rigid", {})
    m = gm.get("masses_kg", [])
    g = gm.get("static_give_norm_m", [])
    ax.loglog(m, g, "s-", color=_NAVY, label="實測 give(持平=float32 讀取地板)")
    if m and g:
        g0 = g[0] if g[0] else 2.38e-8
        ax.loglog(m, [g0 * mm / m[0] for mm in m], "--", color="#c0392b",
                  label="真有 compliance 時的線性 give(未觀察到)")
    ax.set_xlabel("負載質量 (kg)")
    ax.set_ylabel("static give |z| (m)")
    ax.set_title("接縫 give 在 1000x 負載下持平 -> 在讀取地板下(僅上界)",
                 fontsize=10)
    ax.legend(fontsize=8)
    ax.grid(True, which="both", alpha=0.3)
    _fix_log(ax, "both")


def _chart_219(fig, d):
    import numpy as np
    ax = fig.add_axes([0.12, 0.16, 0.80, 0.72])
    pts = d.get("effort_clamp", {}).get("points", [])
    labels = ["maxF=%.4g N\n(%.2gx 負載)" % (p["max_force_N"],
              p["max_force_vs_load"]) for p in pts]
    droop = [min(p["droop_mm"], 50.0) for p in pts]  # clamp stall bar for scale
    colors = ["#2e7d32" if p["held_target"] else "#c0392b" for p in pts]
    x = np.arange(len(pts))
    ax.bar(x, droop, 0.5, color=colors)
    for i, p in enumerate(pts):
        ax.text(i, droop[i], "撐住" if p["held_target"] else "STALL",
                ha="center", va="bottom", fontsize=8)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=7)
    ax.set_ylabel("下垂 (mm;stall 為顯示夾在 50)")
    ax.set_title("力矩飽和:maxForce < 重量(98.1 N)-> stall,非下垂", fontsize=10)
    ax.grid(True, axis="y", alpha=0.3)


def chart_page(pdf, exp, test_dir):
    fig = plt.figure(figsize=(8.27, 11.69))
    fig.text(0.06, 0.955, f"{exp['id']}  {exp['title']} -- 圖表", fontsize=13,
             fontweight="bold", va="top")
    exp["chart"](fig)
    log = exp.get("log")
    prov = "" if not log else (
        f"log: test/{log}   sha256:{_sha256(Path(test_dir) / log)}   "
        f"|  reproduce: see the table page")
    fig.text(0.06, 0.04, prov, fontsize=7, family="monospace", va="bottom")
    pdf.savefig(fig)
    plt.close(fig)


def build_registry(test_dir):
    d212 = _load(test_dir, ".prove-A-212-sag.json")
    d215 = _load(test_dir, ".prove-B-215-hold.json")
    d216 = _load(test_dir, ".prove-A-216-tracking.json")
    d219 = _load(test_dir, ".prove-A-219-limits.json")
    d218 = _load(test_dir, ".prove-B-218-carry.json")
    dcolA = _load(test_dir, ".verify-collision-import.json")
    dcolB = _load(test_dir, ".verify-decomp-pocket.json")
    d220 = _load(test_dir, ".prove-B-220-push.json")
    d221 = _load(test_dir, ".prove-C-221-seam.json")
    d227 = _load(test_dir, ".prove-A-227-multijoint.json")
    d229 = _load(test_dir, ".prove-C-229-basecarry.json")
    dd1 = _load(test_dir, ".l25-dynamic-push.json")
    dd2 = _load(test_dir, ".l25-dynamic-carry.json")
    dd2f = _load(test_dir, ".l25-dynamic-carry-finedt.json")
    reg = [
        dict(id="#212", title="單關節下垂 vs 剛度 (L2.5/L3)",
             verdict="QUESTIONABLE -> 已修 (加 damping 對照)",
             log=".prove-A-212-sag.json",
             cmd=f"{PY} {W}/src/script/exp_l25_sag_sweep.py "
                 f"--out {W}/test/.prove-A-212-sag.json",
             tbl=t_212(d212),
             concl="damping 對照(固定 k=1e6、掃 damping)顯示 droop 從 -0.10 擺到 "
                   "+0.05 mm、低 damping 甚至負值(overshoot)。真穩態(drift=0)下 "
                   "droop 必等於 mg/k=0.098 mm 與 damping 無關 —— 但實測隨 damping "
                   "變、且都不在 0.098 上。所以高 k undershoot(k_eff/k 到 5.4x)是 "
                   "TGS implicit-drive 把 damping 摺進有效剛性的 solver 假象,不是剛性 "
                   "特性。ADR-0021 D1a「no floor / beats prediction」要刪;可辯護的只剩 "
                   "「in-range 沒撞 float32 地板」。"),
        dict(id="#215", title="逐 link 真 kinematic 替換 (L2 hold)",
             verdict="QUESTIONABLE(曾 crash) -> 已修 (NameError; 重跑乾淨)",
             log=".prove-B-215-hold.json",
             cmd=f"{PY} {W}/src/script/exp_l2_kinematic_substitution.py "
                 f"--out {W}/test/.prove-B-215-hold.json",
             tbl=t_215(d215),
             concl="修掉 NameError(contact_frames[nm])後,committed driver 才真的 "
                   "產出此表。kinematic body 在 10 kg 負載 + 接觸下撐到 float32 "
                   "read-back 地板(6e-8..4.6e-7 m);dynamic body 一步會掉 1.36 mm "
                   "—— kinematic vs dynamic 分野成立。「無視接觸」那半是 kinematic "
                   "定義使然(靜置 pusher 壓在無視外力的 body 上不算獨立壓力測試),已 "
                   "改述。"),
        dict(id="#216", title="L3 軌跡追蹤精度",
             verdict="QUESTIONABLE -> 改稿 (單位 + 不適用的地板)",
             log=".prove-A-216-tracking.json",
             cmd=f"{PY} {W}/src/script/exp_traj_tracking.py "
                 f"--out {W}/test/.prove-A-216-tracking.json",
             tbl=t_216(d216),
             concl="driver 報的是弧度/毫弧度(mrad),原稿誤標成 mm(角度當距離)。此 "
                   "joint 繞 +Z revolute,重力對該軸零力矩 -> 理想穩態誤差 ~0,不是 "
                   "mg/k;原稿「地板 mg/k=1.962 mm」是從 prismatic 實驗搬來、不適用,"
                   "「1.757 對 1.962」是巧合。正解:報 mrad 角度追蹤誤差,無重力地板可比。"),
        dict(id="#219", title="drive 極限:力矩 / 速度 / 行程",
             verdict="QUESTIONABLE(provenance) -> 已修 (重跑對齊 driver)",
             log=".prove-A-219-limits.json",
             cmd=f"{PY} {W}/src/script/exp_drive_limits.py "
                 f"--out {W}/test/.prove-A-219-limits.json",
             tbl=t_219(d219),
             concl="重跑使數字對齊 committed driver。重物是 98.1 N(10 kg)—— 原稿的 "
                   "「49 N 重物」把一個 0.5x maxForce case(49.05 N)誤標成重量。"
                   "maxForce >= mg 才撐得住(下垂 mg/k);< mg 則 stall 到 lower "
                   "limit。行程極限 0.5 m 夾住 2.0 m 命令。下垂與 solver 迭代數無關;"
                   "revolute drive 存 Kp*pi/180。"),
        dict(id="#218", title="kinematic 載運速度上限 (解析 d_crit)",
             verdict="MINOR (報 mu-dependent 門檻)",
             log=".prove-B-218-carry.json",
             cmd=f"{PY} {W}/src/script/exp_l2_carry_speed_limit.py "
                 f"--out {W}/test/.prove-B-218-carry.json",
             tbl=t_218(d218),
             concl="推導成立:d_crit = dt*sqrt(2*mu*g*L_back) 對上實測 carried/"
                   "slipped 門檻、隨 mu 單調上升(0.035..0.077 m/tick)。要報 "
                   "mu-dependent 門檻,不是粗略單一帶;高速「發射到 5.19 m」是接觸穿透 "
                   "注入能量的 solver 假象,不是物理發現。"),
        dict(id="#220", title="kinematic 推 dynamic 物 (單向傳遞)",
             verdict="QUESTIONABLE -> 措辭軟化",
             log=".prove-B-220-push.json",
             cmd=f"{PY} {W}/src/script/exp_l2_push_dynamic.py "
                 f"--out {W}/test/.prove-B-220-push.json",
             tbl=t_220(d220),
             concl="plate「接觸下 track 0.000」是 kinematic 定義使然(每 tick teleport "
                   "+ 不積分 -> 任何反作用在 read-back 前被丟掉),max_pos_err<1e-4 是 "
                   "float32 地板、保證成立無法證偽 —— 改述為 true-by-definition。真正 "
                   "的量測是推箱:normal-overlap depenetration 傳 ~1.19 m 位移。單向 "
                   "傳遞成立。"),
        dict(id="#221", title="maximal loop-joint 接縫 compliance",
             verdict="QUESTIONABLE -> 改寫成上界",
             log=".prove-C-221-seam.json",
             cmd=f"{PY} {W}/src/script/exp_l2_loop_joint_boundary.py "
                 f"--out {W}/test/.prove-C-221-seam.json",
             tbl=t_221(d221),
             concl="static give 在 1/10/100/1000 kg 逐位元相同(2.38e-8 m)-> 是 "
                   "float32 量化殘差,不是量到的 compliance。此 run 只能給上界:give "
                   "< ~2e-7 m @ 9810 N => 接縫剛度 > ~5e10 N/m(對實用負載有效剛性)。"
                   "要刪具體 give 值、「give 隨質量成長」/ monotonic(四值相同,vacuous)、"
                   "「駁斥 #308」—— #308 是鏈式 joint 疊加,這只跑了單一個(鏈版 "
                   "SIGSEGV)。"),
        dict(id="#227", title="3 關節串接下垂累加",
             verdict="MINOR (幾何恆等式措辭)",
             log=".prove-A-227-multijoint.json",
             cmd=f"{PY} {W}/src/script/exp_multijoint_sag.py "
                 f"--out {W}/test/.prove-A-227-multijoint.json",
             tbl=t_227(d227),
             concl="乾淨的垂直 prismatic 串接;實測 tip 總和 60.3 mm vs 預測 58.9 mm "
                   "(+2.4% 真耦合)。「tip 誤差 = 各節 sag 相加」是串接鏈的幾何恆等式,"
                   "不是量到的 solver 耦合發現 —— 真正的發現是實測總和 ~= 預測總和。"),
        dict(id="#229", title="底盤帶浮動 articulation (negative)",
             verdict="MINOR (數字對齊 committed JSON)",
             log=".prove-C-229-basecarry.json",
             cmd=f"{PY} {W}/src/script/exp_l2_base_carries_arm.py "
                 f"--out {W}/test/.prove-C-229-basecarry.json",
             tbl=t_229(d229),
             concl="真 PhysX negative:USD 階層 parent 帶不動浮動 articulation "
                   "(follow_ratio ~0,arm 動 ~0 而底盤移 2.5 m)—— 必須用 joint。原稿 "
                   "數字(底盤 1.5 m / arm 發散到 2.369 m)是 stale、甚至暗示被乾淨 "
                   "follow=0 run 否定的發散;已改成 committed JSON(底盤 2.5 / arm 0 / "
                   "follow 0)。"),
        dict(id="D1", title="L2.5 動態推:推板 back-off vs 剛度",
             verdict="QUESTIONABLE -> 已修 (no-cube 對照 + feed-forward)",
             log=".l25-dynamic-push.json",
             cmd=f"{PY} {W}/src/script/exp_l25_dynamic_interaction.py --mode push "
                 f"--out {W}/test/.l25-dynamic-push.json",
             tbl=t_d1(dd1),
             concl="加了 drive velocity feed-forward + 同規格 no-cube 對照 lane。"
                   "結果:對照(following-lag)back-off ~= 接觸 back-off,所以純接觸 "
                   "反作用 ~0(<0.13 mm)。原稿歸給接觸的軟端 back-off,其實是 "
                   "drive-following / startup lag,不是有限彈簧反作用 —— 確認審查。"),
        dict(id="D2", title="L2.5 動態載:payload lag vs 剛度 + dt",
             verdict="FLAWED -> 已修 (feed-forward + dt 對照)",
             log=".l25-dynamic-carry.json",
             cmd=f"{PY} {W}/src/script/exp_l25_dynamic_interaction.py --mode carry "
                 f"--out {W}/test/.l25-dynamic-carry.json\n"
                 f"# fine-dt control (4x): --dt 0.004166667 --steps 1200 "
                 f"--warmup 240 --settle 480 "
                 f"--out {W}/test/.l25-dynamic-carry-finedt.json",
             tbl=t_d2(dd2, dd2f),
             concl="原本「越硬對 payload 越差」是錯的、方向相反。第一性原理:a=0.75 "
                   "m/s^2 只需 0.75 N 摩擦 vs 靜摩擦上限 4.9 N(6.5x)-> 連續運動下任何 "
                   "k 都零滑。高 k slip 是 (k*dt) 離散化假象:stiff drive 在單 substep "
                   "內 snap 到 per-tick 位置階梯 -> 衝擊 -> 破壞摩擦,dt 不 << drive "
                   "自然週期 2*pi*sqrt(m/k) 時發生。dt 細化即崩塌(k=1e5:154->19 mm;"
                   "k=1e6/1e7 要更細)。交付以 payload lag 判,不是載台 tracking err "
                   "(後者可 <0.05 mm 而貨物大幅落後)。L2.5 能載;dt 要配剛度。"),
        dict(id="Collision A1/A2", title="多 box <collision> 匯入保真",
             verdict="實測確認(真 UrdfConverter)",
             log=".verify-collision-import.json",
             cmd=f"{PY} {W}/src/script/../test/verify_collision_import.py "
                 f"--out {W}/test/.verify-collision-import.json",
             tbl=t_colA(dcolA),
             concl="1-link URDF 帶 3 個 box <collision>(不同原點)匯入 6.0.1 → 3 個獨立 "
                   "UsdGeom.Cube colliders 在正確原點、各只掛 CollisionAPI(無 "
                   "MeshCollisionAPI/approximation = PxBoxGeometry)、直接在 link 下(無 "
                   "colliders Scope)、無 ghost/duplicate。A1(全保留)+ A2(全解析 box、"
                   "無 convexHull)實測成立 —— box-union 匯入地基乾淨。"),
        dict(id="Collision decomp", title="convex_decomposition 對功能性口袋",
             verdict="實測:tuning 問題非原理不能(反駁 §2.2)",
             log=".verify-decomp-pocket.json",
             cmd=f"{PY} {W}/src/script/../test/verify_decomp_pocket.py "
                 f"--out {W}/test/.verify-decomp-pocket.json "
                 f"[--mp4 {W}/viz/decomp_pocket.mp4]",
             tbl=t_colB(dcolB),
             concl="U-channel 口袋 + 掉落探針:convexHull 填滿口袋(探針卡頂 z=0.75);"
                   "convexDecomposition maxHulls 8 與 64 都保住口袋(探針落底 z=0.4625,"
                   "= base_top 0.3 + 半高 0.15)。所以 decomposition 能保住功能性口袋 —— "
                   "對乾淨可 box 分解的矩形件(pallet/牙叉)可行,forklift_b 那種薄多零件 "
                   "美術資產才 hull 數爆掉。文件 §2.2「disqualified」overstated。"),
        dict(id="限制①",
             title="articulation + kinematic maximal loop-joint SIGSEGV",
             verdict="MINOR (陳述正確;上游 bug)",
             log=None,
             cmd=f"{PY} {W}/src/script/repro_artic_kinematic_loopjoint_sigsegv.py "
                 f"# native SIGSEGV -> writes no JSON",
             tbl=(["對照組", "結果"],
                  [["dynamic body (無 ArticulationRootAPI)", "exit 0 (存活)"],
                   ["floating articulation + get_transforms", "SIGSEGV"],
                   ["只讀 body、不讀 transforms", "存活"],
                   ["完全不 readback", "存活"],
                   ["=> 觸發 = artic 拓樸 x world.step 後對 kinematic 錨點 "
                    "get_transforms", ""]]),
             concl="乾淨 bisection 把 native SIGSEGV(libomni.physx.tensors)隔離到一個 "
                   "文件上合法的 PhysX 構造 -> 上游引擎缺陷(isaac-sim/IsaacSim#803),"
                   "workaround = 用 plain dynamic body。註:ADR-0008 舊措辭「crash at "
                   "physics-view init」已 stale;repro 把它定位在 world.step 後的 "
                   "get_transforms readback。"),
        dict(id="限制②",
             title="PhysX 禁止 kinematic articulation LINK",
             verdict="MINOR (陳述正確;PhysX 5.4 明文)",
             log=None,
             cmd="(doc constraint; #229 usd_child is supporting evidence, not proof)",
             tbl=(["事實", "來源"],
                  [["articulation 內 link 不能 kinematic",
                    "PhysX 5.4 Articulations 文件"],
                   ["真 L2 替換目標 = 散裝 rigid body",
                    "ADR-0008 clause 4 / ADR-0021 D2"],
                   ["#229 證的是互補命題",
                    "支持證據,非此明文限制的證明"]]),
             concl="核心宣稱正確引 PhysX 5.4 文件。小瑕:原稿「#229 即證此」over-"
                   "attribute —— #229 證的是「浮動 root 不被 kinematic USD parent 帶 "
                   "動」,是支持證據,不是「link 不能 kinematic」的證明。"),
        dict(id="限制③",
             title="#205 / #171 / #166 卡 CAD 模型延後",
             verdict="SOUND (純粹 asset 卡關)",
             log=None,
             cmd="(not run: blocked on the user's CAD model)",
             tbl=(["實驗", "卡點"],
                  [["#205 實車 e2e", "需 user CAD 模型 (ADR-0021)"],
                   ["#171 代表性機器人 e2e", "需 CAD 模型"],
                   ["#166 DAE 顏色匯入", "需 CAD (pipeline 在 ADR-0020)"]]),
             concl="確認純粹 asset 卡關、非技術不可能:DAE 顏色匯入 pipeline(ADR-0020)"
                   "與 CAD 依賴(ADR-0021)都已明訂,只差模型。"),
    ]
    charts = {
        "#212": lambda fig: _chart_212(fig, d212),
        "D2": lambda fig: _chart_d2(fig, dd2, dd2f),
        "#227": lambda fig: _chart_227(fig, d227),
        "#218": lambda fig: _chart_218(fig, d218),
        "#221": lambda fig: _chart_221(fig, d221),
        "#219": lambda fig: _chart_219(fig, d219),
    }
    for e in reg:
        if e["id"] in charts:
            e["chart"] = charts[e["id"]]
    return reg


def _wrap(text, width=52):
    import textwrap
    out = []
    for para in text.split("\n"):
        out.extend(textwrap.wrap(para, width=width) or [""])
    return out


def title_page(pdf, test_dir):
    fig = plt.figure(figsize=(8.27, 11.69))
    ax = fig.add_subplot(111)
    ax.axis("off")
    lines = [
        ("Isaac Sim 6.0.1 物理再驗證 —— 驗收資料表", 16, "bold", "sans"),
        ("審查後修正版;每支實驗可追溯 log + 可重現", 10, "italic", "sans"),
        ("", 8, "normal", "sans"),
        ("環境", 12, "bold", "sans"),
        ("  Isaac Sim 6.0.1 / Isaac Lab 3.0 (v3.0.0-beta2.patch1), Kit Python 3.12",
         9, "normal", "sans"),
        ("  GPU: NVIDIA GeForce RTX 5090 (31 GiB); driver 610.43.02; Warp 1.13.0",
         9, "normal", "sans"),
        ("  容器 image: yunchien/isaac:devel (BASE_IMAGE=nvcr.io/nvidia/isaac-sim:"
         "6.0.1)", 9, "normal", "sans"),
        ("  physics dt: 1/60 s(除非某支的 fine-dt 對照另有標示)", 9, "normal",
         "sans"),
        ("", 8, "normal", "sans"),
        ("重現方式(在 isaac worktree 根目錄)", 12, "bold", "sans"),
        ("  W=/home/<user>/work/worktree/<wt>   # this worktree inside container",
         9, "mono", "mono"),
        ("  just setup apply && just run -t devel -d       # start devel container",
         9, "mono", "mono"),
        ("  # then run each per-page command (env PYTHONPATH=$W/framework is only",
         9, "mono", "mono"),
        ("  # needed by URDF-import drivers, harmless elsewhere)", 9, "mono",
         "mono"),
        ("", 8, "normal", "sans"),
        ("判定圖例(2026-09 對抗式物理有效性審查)", 12, "bold", "sans"),
        ("  FLAWED       headline 結論錯了;已修 + 重新驗證", 9, "normal", "sans"),
        ("  QUESTIONABLE 設計/provenance 有洞;已修(加對照/重跑)或改稿", 9,
         "normal", "sans"),
        ("  MINOR        結論成立;僅措辭/數字對齊", 9, "normal", "sans"),
        ("  SOUND        乾淨", 9, "normal", "sans"),
        ("", 8, "normal", "sans"),
        ("統計:1 FLAWED, 7 QUESTIONABLE, 5 MINOR, 1 SOUND -> 皆已處理。", 10,
         "bold", "sans"),
        ("定性 L2/L2.5/L3 階層一直是對的;這次修的是框架要依賴的量化 / 機制宣稱。",
         9, "normal", "sans"),
    ]
    y = 0.96
    for txt, sz, style, fam in lines:
        weight = "bold" if style == "bold" else "normal"
        st = "italic" if style == "italic" else "normal"
        family = "monospace" if fam == "mono" else "sans-serif"
        ax.text(0.02, y, txt, fontsize=sz, fontweight=weight, fontstyle=st,
                family=family, transform=ax.transAxes, va="top")
        y -= 0.023 + sz * 0.0013
    pdf.savefig(fig)
    plt.close(fig)


def exp_page(pdf, exp, test_dir):
    fig = plt.figure(figsize=(8.27, 11.69))

    hax = fig.add_axes([0.06, 0.86, 0.91, 0.11])
    hax.axis("off")
    hax.text(0.0, 1.0, f"{exp['id']}  {exp['title']}", fontsize=13,
             fontweight="bold", va="top")
    hax.text(0.0, 0.52, f"判定: {exp['verdict']}", fontsize=10,
             color="#8a1500", va="top")
    log = exp.get("log")
    prov = "log: (none -- see reproduce command)" if not log else (
        f"log: test/{log}   sha256:{_sha256(Path(test_dir) / log)}")
    hax.text(0.0, 0.16, prov, fontsize=8, family="monospace", va="top")

    cols, rows = exp["tbl"]
    tax = fig.add_axes([0.06, 0.34, 0.91, 0.5])
    tax.axis("off")
    if rows:
        tbl = tax.table(cellText=[[str(c) for c in r] for r in rows],
                        colLabels=cols, loc="upper left", cellLoc="left")
        tbl.auto_set_font_size(False)
        tbl.set_fontsize(7.0)
        tbl.scale(1.0, 1.3)
        for (r, _c), cell in tbl.get_celld().items():
            cell.set_edgecolor("#cccccc")
            if r == 0:
                cell.set_facecolor("#1f3b57")
                cell.set_text_props(color="white", fontweight="bold")

    cax = fig.add_axes([0.06, 0.20, 0.91, 0.12])
    cax.axis("off")
    cax.text(0.0, 1.0, "重跑:", fontsize=9, fontweight="bold", va="top")
    y = 0.78
    for ln in _wrap(exp["cmd"], width=104):
        cax.text(0.0, y, ln, fontsize=7, family="monospace", va="top")
        y -= 0.16

    concax = fig.add_axes([0.06, 0.03, 0.91, 0.16])
    concax.axis("off")
    concax.text(0.0, 1.0, "修正結論:", fontsize=9, fontweight="bold", va="top")
    y = 0.88
    for ln in _wrap(exp["concl"], width=52):
        concax.text(0.0, y, ln, fontsize=8.5, va="top")
        y -= 0.075

    pdf.savefig(fig)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--font", default=None,
                    help="Path to a CJK font (.ttc/.otf) for zh-TW rendering. "
                         "Default: test/.notocjk.ttc then host Noto paths.")
    args = ap.parse_args()

    _init_cjk_font(args.font, args.test_dir)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    reg = build_registry(args.test_dir)
    n_pages = 1
    with PdfPages(args.out) as pdf:
        title_page(pdf, args.test_dir)
        for exp in reg:
            exp_page(pdf, exp, args.test_dir)
            n_pages += 1
            if exp.get("chart"):
                chart_page(pdf, exp, args.test_dir)
                n_pages += 1
    print("wrote", args.out, "with", n_pages, "pages; font:", _CJK_NAME)


if __name__ == "__main__":
    main()
