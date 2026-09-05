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


def _video_still(mp4, out_png, frac=0.65):
    """Grab one representative frame from an MP4 so the PDF can SHOW the video.

    A PDF cannot play video, and a bare filename in a reproduce command is not
    evidence a reader can check. Each experiment that ships an MP4 therefore
    carries a still from it, with the file name printed underneath."""
    try:
        if Path(out_png).is_file():
            return str(out_png)
        if not Path(mp4).is_file():
            return None
        import imageio.v2 as iio
        import imageio
        frames = iio.mimread(mp4, memtest=False)
        if not frames:
            return None
        i = min(int(len(frames) * frac), len(frames) - 1)
        imageio.imwrite(str(out_png), frames[i])
        return str(out_png)
    except Exception:  # noqa: BLE001
        return None


# experiment id -> (mp4 filename, frame fraction, what the still shows)
_VIDEOS = {
    "#215": ("l2_kinematic_hold.mp4", 0.60,
             "四種形狀的 kinematic body 沿同一條 SE(3) 軌跡移動,彼此完全不變形、不落後。"),
    "#220": ("l2_push.mp4", 0.70,
             "kinematic 推板推動 dynamic 箱子:箱子被推走,推板本身完全不受反作用影響。"),
    "D1": ("push_k1e6.mp4", 0.75,
           "L2.5 推板(k=1e6)推箱。與無箱對照組相比,推板的 back-off 幾乎一樣 —— "
           "那是 drive 跟隨落後,不是接觸反作用。"),
    "D2": ("l25_carry.mp4", 0.70,
           "L2.5 載台載 payload:高剛度時 payload 相對載台滑動,細化 dt 後消失。"),
    "Collision decomp": ("decomp_pocket.mp4", 0.90,
                         "合成 U-channel 口袋 + 掉落探針:convexHull 那條卡在口袋頂端,"
                         "兩條 convexDecomposition 都落到口袋底。"),
    "Collision 插入": ("pallet_insertion.mp4", 1.00,
                       "真實棧板牙叉插入。綠色(convexDecomposition)整組穿透棧板、兩側都露出來;"
                       "黃色(convexHull)與橘色(boundingCube)停在近端面上。"),
}

# videos that exist but belong to experiments outside this review's scope
_EXTRA_VIDEOS = [
    ("modela_forklift.mp4", "#94 Model A forklift_blocky 的 SE(2) 滑行穩定度(車輛動作)"),
    ("push_k1e4.mp4", "D1 的低剛度對照(k=1e4),與 push_k1e6.mp4 成對比較"),
]


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


def t_fidelity(d):
    a = d.get("authored", {})
    cols = ["項目", "授權值 (URDF)", "USD 讀回", "保真"]
    rows = [
        ["mass (kg)", f(a.get("mass")), f(d.get("mass_read")),
         str(d.get("A4_mass_exact"))],
        ["diagonal inertia",
         "[%s, %s, %s]" % (f(a.get("ixx")), f(a.get("iyy")), f(a.get("izz"))),
         str([round(v, 4) for v in (d.get("diagonal_inertia_read") or [])]),
         str(d.get("A4_inertia_preserved"))],
        ["collider world xyz (m)",
         str(d.get("A3_expected_world_translate")),
         str(d.get("collider_world_translate_read")),
         str(d.get("A3_origin_preserved"))],
    ]
    return cols, rows


def _assets_of(d):
    """Normalise both probe formats (single-asset legacy / batch) to a list."""
    if not d:
        return []
    if "assets" in d:
        return d["assets"]
    return [d] if d.get("url") else []


def t_real_assets(dicts):
    cols = ["官方資產", "mesh", "三角形", "collider", "approximation", "尺寸 (m)"]
    rows, seen = [], set()
    for d in dicts:
        for a in _assets_of(d):
            name = str(a.get("url", "")).split("/")[-1]
            if not name or name in seen:
                continue
            seen.add(name)
            if a.get("error"):
                rows.append([name, "-", "-", "-", "ERROR", "-"])
                continue
            ap = sorted({str(c.get("approximation"))
                         for c in a.get("colliders", [])})
            rows.append([name, str(a.get("mesh_count")),
                         str(a.get("total_triangles")),
                         str(a.get("collider_count")), ", ".join(ap),
                         str(a.get("world_size"))])
    return cols, rows


def t_entry_map(maps):
    cols = ["碰撞近似法", "開口格數 / 總格", "叉孔", "叉孔高度那一列的剖面 (.=開口 #=實心)"]
    rows, marks = [], {}
    for i, (name, d) in enumerate(maps):
        asc = (d or {}).get("ascii_map_top_to_bottom", [])
        opens = sum(r.count(".") for r in asc)
        total = sum(len(r) for r in asc)
        zs = (d or {}).get("zs", [])
        line = ""
        if zs and asc:
            j = min(range(len(zs)), key=lambda k: abs(zs[k] - 0.05))
            line = asc[j]
        has = bool(total and opens > total * 0.1)
        rows.append([name, "%d / %d" % (opens, total),
                     "有" if has else "無", line])
        marks[(i, 2)] = "ok" if has else "bad"
    return cols, rows, marks


def t_insertion(d):
    cols = ["碰撞近似法", "y=-0.15 叉孔", "y=0 中柱", "y=+0.15 叉孔",
            "最深穿透 (m)", "可插入"]
    rows, marks = [], {}
    for i, L in enumerate(d.get("lanes", [])):
        by = {round(float(k["lateral_y"]), 2): k for k in L.get("forks", [])}

        def cell(y):
            k = by.get(y)
            if not k:
                return "-", None
            return ("%.3f  %s" % (k["penetration_depth_m"],
                                  "插入" if k["entered"] else "擋住"),
                    "ok" if k["entered"] else "bad")
        vals = [cell(-0.15), cell(0.0), cell(0.15)]
        for j, (_t, m) in enumerate(vals):
            marks[(i, j + 1)] = m
        ent = bool(L.get("any_entered"))
        marks[(i, 5)] = "ok" if ent else "bad"
        rows.append([L["lane"], vals[0][0], vals[1][0], vals[2][0],
                     f(L.get("best_penetration_m")), "是" if ent else "否"])
    return cols, rows, {k: v for k, v in marks.items() if v}


def t_urdf_mesh(d):
    obj = d.get("exported_obj", {})
    cols = ["項目", "值"]
    rows = [
        ["來源 mesh", str(d.get("source_mesh", "")).split("/")[-1]],
        ["匯出 OBJ", "%s verts / %s faces"
         % (obj.get("verts"), obj.get("faces"))],
        ["importer 實際寫入的 approximation",
         ", ".join(d.get("importer_approximations") or [])],
        ["硬寫死 convexHull", str(d.get("importer_forced_convex_hull"))],
        ["匯入後 entry 面開口格數", str(d.get("entry_open_cells"))],
        ["tunnel 存活", str(d.get("tunnels_survived_import"))],
    ]
    for c in d.get("importer_authored_colliders", []):
        rows.append(["collider %s" % c["path"].split("/")[-1],
                     "%s / %s" % (c["type"], c["approximation"])])
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


def _chart_212(fig, d, rect):
    pts = d.get("points", [])
    x0, y0, w, h = rect
    ax1 = fig.add_axes([x0 + 0.050, y0 + h * 0.635, w - 0.065, h * 0.305])
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
    ax2 = fig.add_axes([x0 + 0.050, y0 + h * 0.135, w - 0.065, h * 0.285])
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


def _chart_d2(fig, d, dfine, rect):
    x0, y0, w, h = rect
    ax = fig.add_axes([x0 + 0.050, y0 + h * 0.21, w - 0.065, h * 0.66])
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


def _chart_227(fig, d, rect):
    import numpy as np
    x0, y0, w, h = rect
    ax = fig.add_axes([x0 + 0.050, y0 + h * 0.21, w - 0.065, h * 0.66])
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


def _chart_218(fig, d, rect):
    x0, y0, w, h = rect
    ax = fig.add_axes([x0 + 0.050, y0 + h * 0.21, w - 0.065, h * 0.66])
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


def _chart_221(fig, d, rect):
    x0, y0, w, h = rect
    ax = fig.add_axes([x0 + 0.050, y0 + h * 0.21, w - 0.065, h * 0.66])
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


def _chart_219(fig, d, rect):
    import numpy as np
    x0, y0, w, h = rect
    ax = fig.add_axes([x0 + 0.050, y0 + h * 0.21, w - 0.065, h * 0.66])
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


def _chart_insertion(fig, d, rect):
    """Horizontal bars. The blocked lanes are ~0 m, so a plain bar chart renders
    them as NOTHING (the old version's real flaw). Every bar therefore carries an
    explicit end label, and blocked lanes get a visible stub + '擋' marker."""
    import numpy as np
    x0, y0, w, h = rect
    ax = fig.add_axes([x0 + 0.175, y0 + h * 0.19, w - 0.195, h * 0.72])
    lanes = d.get("lanes", [])
    ys = [(-0.15, "y=-0.15 叉孔"), (0.0, "y=0 中柱"), (0.15, "y=+0.15 叉孔")]
    colors = ["#2e7d32", "#8a8f98", "#1f3b57"]
    labels, vals, cols = [], [], []
    for L in lanes:
        by = {round(float(k["lateral_y"]), 2): k for k in L.get("forks", [])}
        for j, (yv, yl) in enumerate(ys):
            k = by.get(yv, {})
            labels.append(f"{L['lane']}  |  {yl}")
            vals.append(max(float(k.get("penetration_depth_m", 0.0)), 0.0))
            cols.append(colors[j])
    ypos = np.arange(len(labels))
    ax.barh(ypos, vals, 0.72, color=cols)
    thr = float(d.get("enter_threshold_m", 0.3))
    ax.axvline(thr, color="#c0392b", ls="--", lw=1.0)
    ax.text(thr, -0.75, " 進入門檻 %.2f m" % thr, color="#c0392b",
            fontsize=6.5, va="bottom")
    vmax = max(vals + [1.0])
    for i, v in enumerate(vals):
        if v < thr:
            ax.plot([0.006 * vmax], [i], marker="x", color="#a8271a", ms=4)
            ax.text(0.02 * vmax, i, "擋住  %.3f m" % v, va="center",
                    fontsize=6.5, color="#a8271a")
        else:
            ax.text(v - 0.01 * vmax, i, "插入 %.2f m  " % v, va="center",
                    ha="right", fontsize=6.5, color="white", fontweight="bold")
    ax.set_yticks(ypos)
    ax.set_yticklabels(labels, fontsize=6.5)
    ax.invert_yaxis()
    ax.set_xlabel("牙叉穿透深度 (m) -- 棧板全長 1.21 m", fontsize=7.5)
    ax.set_xlim(0, vmax * 1.08)
    ax.tick_params(axis="x", labelsize=7)
    ax.grid(True, axis="x", alpha=0.25)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)


def _chart_entry_maps(fig, maps, rect):
    """The entry-face occupancy MAP -- the one visual a table cannot carry.

    Each panel is the 17x13 (y,z) raycast grid of the pallet's fork-entry face
    under one approximation: dark = solid there, light = the ray passed through.
    Side by side you SEE the two fork tunnels appear only under decomposition."""
    import numpy as np
    from matplotlib.colors import ListedColormap
    x0, y0, w, h = rect
    n = max(len(maps), 1)
    gap = 0.018
    pw = (w - gap * (n - 1)) / n
    cmap = ListedColormap(["#26333f", "#d8f0dc"])
    for i, (name, d) in enumerate(maps):
        asc = (d or {}).get("ascii_map_top_to_bottom", []) or ["#"]
        ys = (d or {}).get("ys", [])
        zs = (d or {}).get("zs", [])
        grid = np.array([[0 if ch == "#" else 1 for ch in row] for row in asc])
        ax = fig.add_axes([x0 + i * (pw + gap), y0 + h * 0.16, pw, h * 0.70])
        ax.imshow(grid, cmap=cmap, aspect="auto", interpolation="nearest",
                  vmin=0, vmax=1)
        opens = int(grid.sum())
        ax.set_title("%s\n開口 %d / %d 格" % (name, opens, grid.size),
                     fontsize=7.5, fontweight="bold", pad=4)
        if ys:
            tk = [0, len(ys) // 2, len(ys) - 1]
            ax.set_xticks(tk)
            ax.set_xticklabels(["%.2f" % ys[t] for t in tk], fontsize=6)
        # y ticks only on the leftmost panel -- otherwise each panel's labels
        # are drawn over its neighbour.
        if zs and i == 0:
            tk = [0, len(zs) // 2, len(zs) - 1]
            ax.set_yticks(tk)
            ax.set_yticklabels(["%.2f" % zs[t] for t in tk], fontsize=6)
            ax.set_ylabel("z 叉孔高度 (m)", fontsize=7)
        else:
            ax.set_yticks([])
        ax.set_xlabel("y 橫向位置 (m)", fontsize=7)
        for s in ax.spines.values():
            s.set_edgecolor("#aab2bb")


def build_registry(test_dir):
    d212 = _load(test_dir, ".prove-A-212-sag.json")
    d215 = _load(test_dir, ".prove-B-215-hold.json")
    d216 = _load(test_dir, ".prove-A-216-tracking.json")
    d219 = _load(test_dir, ".prove-A-219-limits.json")
    d218 = _load(test_dir, ".prove-B-218-carry.json")
    dcolA = _load(test_dir, ".verify-collision-import.json")
    dcolB = _load(test_dir, ".verify-decomp-pocket.json")
    dfid = _load(test_dir, ".verify-import-fidelity.json")
    d220 = _load(test_dir, ".prove-B-220-push.json")
    d221 = _load(test_dir, ".prove-C-221-seam.json")
    d227 = _load(test_dir, ".prove-A-227-multijoint.json")
    d229 = _load(test_dir, ".prove-C-229-basecarry.json")
    dd1 = _load(test_dir, ".l25-dynamic-push.json")
    dd2 = _load(test_dir, ".l25-dynamic-carry.json")
    dd2f = _load(test_dir, ".l25-dynamic-carry-finedt.json")
    # real open-source (NVIDIA) asset collision experiments
    dra1 = _load(test_dir, ".verify-real-asset-collision.json")
    dra2 = _load(test_dir, ".verify-real-asset-batch.json")
    dra3 = _load(test_dir, ".o3dyn-pockets.json")
    dmapD = _load(test_dir, ".pallet-entry-map.json")
    dmapB = _load(test_dir, ".pallet-entry-map-boundingCube.json")
    dmapH = _load(test_dir, ".pallet-entry-map-convexHull.json")
    dins = _load(test_dir, ".verify-real-pallet-insertion.json")
    dumesh = _load(test_dir, ".verify-urdf-mesh-collision.json")
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
        dict(id="Collision A3/A4", title="link 原點 + CAD 慣量 匯入保真",
             verdict="實測確認(A3 origin + A4 inertia 保真)",
             log=".verify-import-fidelity.json",
             cmd=f"{PY} {W}/src/script/../test/verify_import_fidelity.py "
                 f"--out {W}/test/.verify-import-fidelity.json",
             tbl=t_fidelity(dfid),
             concl="合成 URDF(已知 mass 7.5、三個相異對角慣量、box 在非零原點)匯入後讀 "
                   "USD:mass 精確、diagonalInertia 與 URDF 張量一致(未被重算)、collider "
                   "world 原點 = 授權原點 x joint。A3(原點)+ A4(CAD 慣量)保真成立 —— "
                   "sw2urdf 的最高價值輸出(CAD 慣量)不會在轉換中被破壞;留作 CI regression "
                   "guard 防匯入器版本漂移。"),
        dict(id="Collision 真實資產", title="官方 prop 的 collision approximation 光譜",
             verdict="實測確認(直連 HTTPS 繞過壞掉的本地 Hub)",
             log=".verify-real-asset-batch.json",
             cmd=f"{PY} {W}/test/verify_real_asset_collision.py "
                 f"--url <https-asset-url>[,...] "
                 f"--out {W}/test/.verify-real-asset-batch.json",
             tbl=t_real_assets([dra1, dra2, dra3]),
             concl="本地 Omniverse Hub daemon 在容器內起不來(寫不了 /tmp/hub-*.config."
                   "json),但 NVIDIA 資產伺服器本身正常(host 與容器 curl 皆 HTTP 200)"
                   " —— 用 Usd.Stage.Open 直連 HTTPS 可完全繞過 Hub。實測 5 個官方 prop:"
                   "同樣是棧板,NVIDIA 出了三種碰撞狀態 —— pallet.usd 是 boundingCube"
                   "(口袋消失)、o3dyn_pallet.usd 是 convexDecomposition(口袋保留)、"
                   "pallet_holder.usd 根本沒授權碰撞。連 KLT 的「_visual_collision」版也"
                   "只是 boundingCube。結論:凹槽能不能用,取決於 authoring 時選的近似法,"
                   "與 mesh 品質無關;且 convexDecomposition 是原廠自己在用的正解 —— "
                   "「decomposition disqualified」不成立。"),
        dict(id="Collision entry 圖", title="entry 面佔據圖(raycast 定位 tunnel)",
             verdict="實測:三種近似的通透性差異可視化",
             log=".pallet-entry-map.json",
             cmd=f"{PY} {W}/test/verify_pallet_entry_map.py "
                 f"--approx convexDecomposition "
                 f"--out {W}/test/.pallet-entry-map.json",
             tbl=t_entry_map([("boundingCube", dmapB), ("convexHull", dmapH),
                              ("convexDecomposition", dmapD)]),
             concl="對 pallet 的 -x 進叉面掃 17x13 的 (y,z) 網格射線,量第一個命中點,"
                   "直接畫出碰撞體的通透結構。boundingCube 全實心(0 開口);convexHull "
                   "僅剩邊緣 sliver(hull 依定義填滿凹陷);convexDecomposition 出現兩條"
                   "清楚 tunnel(y=+-0.15、z<=0.09),頂板以上仍實心 —— 與真實棧板幾何吻合。"
                   "這張圖也是修正實驗的工具:牙叉原本瞄在 y=+-0.26 全撞 block,靠它才定位"
                   "到真正的 tunnel。"),
        dict(id="Collision 插入", title="真實 pallet 牙叉插入:三法同場對照",
             verdict="決定性實測(根因確認)",
             log=".verify-real-pallet-insertion.json",
             cmd=f"{PY} {W}/test/verify_real_pallet_insertion.py "
                 f"--out {W}/test/.verify-real-pallet-insertion.json "
                 f"[--mp4 {W}/doc/viz/pallet_insertion.mp4]",
             tbl=t_insertion(dins),
             concl="同一顆官方 pallet.usd,只換 collider approximation:牙叉(1-DOF "
                   "prismatic 滑軌、0.5 m/s coast、開 CCD)從 -x 面插入。free_control"
                   "(無 pallet)穿透 2.628 m 驗證機構;boundingCube 與 convexHull 三個"
                   "位置全擋(~0);convexDecomposition 在兩條真 tunnel 穿透 2.628 m、"
                   "卻在真中柱(y=0)正確擋住(0.005)。最後這一格是最強證據:decomposition "
                   "不是「什麼都放行」,而是忠實還原真實幾何 —— 該開的開、該實的實。"),
        dict(id="Collision importer", title="真實 mesh 走我們的 URDF importer",
             verdict="決定性實測(ADR-0020 核心主張確認)",
             log=".verify-urdf-mesh-collision.json",
             cmd=f"{PY} {W}/test/verify_urdf_mesh_collision_path.py "
                 f"--out {W}/test/.verify-urdf-mesh-collision.json",
             tbl=t_urdf_mesh(dumesh),
             concl="前面的實驗都動「預先授權好的 USD」,沒走到我們的匯入路徑。這支把同一份"
                   "真實幾何繞回自家 pipeline:pallet mesh -> OBJ -> URDF <collision>"
                   "<mesh> -> model_import._convert_urdf。結果 importer 一律寫 "
                   "convexHull,匯入後 entry 面開口 0 格、tunnel 全滅。也就是說「作者在 "
                   "URDF 裡想指定別的近似法」這條路不存在,任何第三方 URDF 帶凹形碰撞 mesh "
                   "進來都會無聲失去口袋。這正是 ADR-0020 選 box-union 的實證依據 —— "
                   "<collision><box> 會匯入成真正的 UsdGeom.Cube(見 Collision A1/A2),"
                   "是唯一繞得開這道硬寫死關卡的授權方式。"),
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
    _maps = [("boundingCube", dmapB), ("convexHull", dmapH),
             ("convexDecomposition", dmapD)]
    charts = {
        "#212": (lambda fig, r: _chart_212(fig, d212, r), 0.34, None),
        "D2": (lambda fig, r: _chart_d2(fig, dd2, dd2f, r), 0.24, None),
        "#227": (lambda fig, r: _chart_227(fig, d227, r), 0.22, None),
        "#218": (lambda fig, r: _chart_218(fig, d218, r), 0.22, None),
        "#221": (lambda fig, r: _chart_221(fig, d221, r), 0.22, None),
        "#219": (lambda fig, r: _chart_219(fig, d219, r), 0.22, None),
        "Collision entry 圖": (
            lambda fig, r: _chart_entry_maps(fig, _maps, r), 0.29,
            "同一顆棧板的進叉面,三種近似法並排:深色=該處實心(射線立刻被擋住),"
            "淺色=射線穿過去,也就是開口。兩條貫穿的叉孔只在 convexDecomposition 出現;"
            "convexHull 只剩最左邊那條細縫,那是射線擦過棧板外緣,不是叉孔。"),
        "Collision 插入": (
            lambda fig, r: _chart_insertion(fig, dins, r), 0.28,
            "被擋住的組別穿透深度接近 0,長條圖上等於看不見,因此每一列都標上實際數值。"),
    }
    for e in reg:
        c = charts.get(e["id"])
        if c:
            e["chart"], e["chart_h"], e["chart_cap"] = c
    # column widths where the default even split reads badly
    _widths = {
        "Collision 真實資產": [1.5, 0.5, 0.7, 0.6, 1.6, 1.5],
        "Collision entry 圖": [1.3, 1.0, 0.5, 2.6],
        "Collision importer": [1.6, 3.0],
        "Collision 插入": [1.5, 1.2, 1.2, 1.2, 1.0, 0.6],
    }
    for e in reg:
        if e["id"] in _widths:
            e["widths"] = _widths[e["id"]]
    return reg


_TOKEN_RE = None


def _dw(ch):
    """Display columns: CJK / fullwidth glyphs occupy two, everything else one."""
    o = ord(ch)
    return 2 if (0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0xA4CF
                 or 0xAC00 <= o <= 0xD7A3 or 0xF900 <= o <= 0xFAFF
                 or 0xFE30 <= o <= 0xFE4F or 0xFF00 <= o <= 0xFF60
                 or 0xFFE0 <= o <= 0xFFE6) else 1


def _width(s):
    return sum(_dw(c) for c in s)


# Characters that must not be pushed to the start of a new line.
_NO_LINE_START = set("，。、；：？！）」』】》〉·…%),;:.?!]}>")


def _wrap(text, width=52):
    """CJK-aware greedy wrap in DISPLAY columns.

    textwrap treats a run of CJK as one unbreakable word and then chops it at an
    arbitrary offset, which is what made the old pages ragged. Here ASCII tokens
    (paths, flags, numbers) stay intact while CJK breaks per character, and
    closing punctuation is never orphaned onto the next line.
    """
    global _TOKEN_RE
    if _TOKEN_RE is None:
        import re
        _TOKEN_RE = re.compile(
            r"[A-Za-z0-9_@:/\\.\-+=$%#\[\]{}<>*'\"()]+|\s+|.", re.S)

    out = []
    for para in text.split("\n"):
        toks = _TOKEN_RE.findall(para)
        line, w = "", 0
        for t in toks:
            if t.isspace():
                if w == 0:
                    continue
                t, tw = " ", 1
            else:
                tw = _width(t)
            # An ASCII run longer than the whole measure (e.g. a long identifier
            # or a path) cannot be kept intact -- split it, or it overflows the
            # cell and collides with the next column.
            if tw > width:
                if w > 0:
                    out.append(line.rstrip())
                    line, w = "", 0
                while _width(t) > width:
                    cut, cw = "", 0
                    for ch in t:
                        chw = _dw(ch)
                        if cw + chw > width:
                            break
                        cut += ch
                        cw += chw
                    out.append(cut)
                    t = t[len(cut):]
                tw = _width(t)
                if not t:
                    continue
            if w + tw > width and w > 0 and t not in _NO_LINE_START:
                out.append(line.rstrip())
                line, w = "", 0
                if t == " ":
                    continue
            line += t
            w += tw
        out.append(line.rstrip())
    return out or [""]


# ---------------------------------------------------------------------------
# Flowing document layout engine.
#
# The previous revision drew ONE experiment per fixed-position page, which left
# roughly two thirds of every page empty and stranded the conclusion in 8pt type
# at the bottom edge. This engine instead flows content top-to-bottom across
# pages like a normal technical document: headings, full-width tables with a
# navy header, left-bar callouts for the takeaway, inline charts, and code
# blocks -- each measures itself and breaks to a new page only when it must.
# ---------------------------------------------------------------------------
_PAGE_W, _PAGE_H = 8.27, 11.69
_ML, _MR, _MTOP, _MBOT = 0.075, 0.955, 0.945, 0.058
_TEXTW_IN = (_MR - _ML) * _PAGE_W
_INK = "#1a1a1a"
_MUTED = "#5b6672"
_RULE = "#c9d0d8"
_OKC = "#1c6b2e"
_BADC = "#a8271a"

_KIND = {
    "info": ("#1f3b57", "#eef2f7"),
    "ok": ("#2e7d32", "#edf6ee"),
    "warn": ("#b06a00", "#fdf4e6"),
    "bad": ("#b0281a", "#fbeded"),
}


def _lh(pt, k=1.62):
    """Line height in figure fraction for a given point size."""
    return pt * k / (_PAGE_H * 72.0)


def _cols(pt, frac=1.0, mono=False):
    """How many display columns fit across the text measure at this size."""
    per = (0.60 if mono else 0.50) * pt / 72.0
    return max(12, int(_TEXTW_IN * frac / per))


class Doc:
    """Minimal flowing-layout renderer over matplotlib PdfPages."""

    def __init__(self, pdf, note=""):
        self.pdf = pdf
        self.note = note
        self.fig = None
        self.y = 0.0
        self.page = 0

    # -- primitives ---------------------------------------------------------
    def _rect(self, x, y, w, h, fc, ec="none", lw=0.0):
        from matplotlib.patches import Rectangle
        self.fig.add_artist(Rectangle((x, y), w, h, facecolor=fc, edgecolor=ec,
                                      linewidth=lw,
                                      transform=self.fig.transFigure))

    def _hline(self, x1, x2, y, color=_RULE, lw=0.8):
        from matplotlib.lines import Line2D
        self.fig.add_artist(Line2D([x1, x2], [y, y], color=color, lw=lw,
                                   transform=self.fig.transFigure))

    def _close_page(self):
        if self.fig is None:
            return
        self._hline(_ML, _MR, 0.044, color="#e2e6ea", lw=0.7)
        self.fig.text(_ML, 0.030, self.note, fontsize=6.8, color="#98a2ad",
                      va="center")
        self.fig.text(_MR, 0.030, str(self.page), fontsize=7.5, color="#98a2ad",
                      va="center", ha="right")
        self.pdf.savefig(self.fig)
        plt.close(self.fig)
        self.fig = None

    def newpage(self):
        self._close_page()
        self.page += 1
        self.fig = plt.figure(figsize=(_PAGE_W, _PAGE_H))
        self.y = _MTOP

    def need(self, h):
        if self.fig is None or self.y - h < _MBOT:
            self.newpage()

    def space(self, h=0.010):
        self.y -= h

    def close(self):
        self._close_page()

    # -- blocks -------------------------------------------------------------
    def para(self, s, pt=8.5, color=_INK, weight="normal", indent=0.0,
             mono=False, gap=0.009):
        fam = "monospace" if mono else "sans-serif"
        frac = 1.0 - indent / (_MR - _ML)
        for ln in _wrap(str(s), _cols(pt, frac, mono)):
            self.need(_lh(pt))
            self.fig.text(_ML + indent, self.y, ln, fontsize=pt, color=color,
                          fontweight=weight, family=fam, va="top")
            self.y -= _lh(pt)
        self.y -= gap

    def bullets(self, items, pt=8.5):
        for it in items:
            lines = _wrap(str(it), _cols(pt, 0.95))
            for i, ln in enumerate(lines):
                self.need(_lh(pt))
                if i == 0:
                    self.fig.text(_ML + 0.004, self.y, "•", fontsize=pt,
                                  color="#1f3b57", va="top")
                self.fig.text(_ML + 0.020, self.y, ln, fontsize=pt, color=_INK,
                              va="top")
                self.y -= _lh(pt)
        self.y -= 0.009

    def h1(self, s):
        self.space(0.016)
        self.need(_lh(15) + 0.030)
        self.fig.text(_ML, self.y, s, fontsize=14.5, fontweight="bold",
                      color="#1f3b57", va="top")
        self.y -= _lh(14.5) + 0.004
        self._hline(_ML, _MR, self.y, color="#1f3b57", lw=1.1)
        self.y -= 0.014

    def h2(self, s, tag=None, tag_color=_MUTED):
        self.space(0.010)
        self.need(_lh(11) * 3 + 0.020)
        self.fig.text(_ML, self.y, s, fontsize=10.8, fontweight="bold",
                      color=_INK, va="top")
        self.y -= _lh(10.8) + 0.002
        if tag:
            self.fig.text(_ML, self.y, tag, fontsize=7.8, color=tag_color,
                          va="top")
            self.y -= _lh(7.8)
        self.y -= 0.007

    def callout(self, title, body, kind="info", pt=8.4):
        bar, bg = _KIND.get(kind, _KIND["info"])
        blines = _wrap(str(body), _cols(pt, 0.92)) if body else []
        h = 0.010 + (_lh(8.8) if title else 0.0) + len(blines) * _lh(pt) + 0.010
        if h > (_MTOP - _MBOT) * 0.75:      # too tall to box -> plain text
            if title:
                self.para(title, pt=8.8, weight="bold", color=bar, gap=0.003)
            self.para(body, pt=pt)
            return
        self.need(h + 0.009)
        top = self.y
        self._rect(_ML, top - h, _MR - _ML, h, bg)
        self._rect(_ML, top - h, 0.0055, h, bar)
        yy = top - 0.010
        if title:
            self.fig.text(_ML + 0.020, yy, title, fontsize=8.8,
                          fontweight="bold", color=bar, va="top")
            yy -= _lh(8.8)
        for ln in blines:
            self.fig.text(_ML + 0.020, yy, ln, fontsize=pt, color=_INK,
                          va="top")
            yy -= _lh(pt)
        self.y = top - h - 0.011

    def code(self, s, pt=7.0):
        lines = []
        for para in str(s).split("\n"):
            lines.extend(_wrap(para, _cols(pt, 0.95, mono=True)))
        h = 0.008 + len(lines) * _lh(pt, 1.5) + 0.008
        self.need(h + 0.006)
        top = self.y
        self._rect(_ML, top - h, _MR - _ML, h, "#f4f6f8", "#e2e6ea", 0.5)
        yy = top - 0.008
        for ln in lines:
            self.fig.text(_ML + 0.011, yy, ln, fontsize=pt, family="monospace",
                          color="#33414f", va="top")
            yy -= _lh(pt, 1.5)
        self.y = top - h - 0.010

    def table(self, cols, rows, widths=None, pt=7.3, marks=None):
        n = len(cols)
        widths = widths or [1.0] * n
        tot = float(sum(widths)) or 1.0
        W = _MR - _ML
        cw = [W * w / tot for w in widths]
        pad = 0.005

        def wrap_cell(v, i, fs):
            avail_in = (cw[i] - 2 * pad) * _PAGE_W
            return _wrap(str(v), max(4, int(avail_in / (0.5 * fs / 72.0))))

        def draw_header():
            cells = [wrap_cell(c, i, pt) for i, c in enumerate(cols)]
            h = max(len(c) for c in cells) * _lh(pt) + 0.008
            self.need(h + _lh(pt) * 4)
            top = self.y
            self._rect(_ML, top - h, W, h, "#1f3b57")
            x = _ML
            for i, ls in enumerate(cells):
                yy = top - 0.005
                for ln in ls:
                    self.fig.text(x + pad, yy, ln, fontsize=pt, color="white",
                                  fontweight="bold", va="top")
                    yy -= _lh(pt)
                x += cw[i]
            self.y = top - h

        draw_header()
        for ri, row in enumerate(rows):
            cells = [wrap_cell(v, i, pt) for i, v in enumerate(row)]
            h = max(len(c) for c in cells) * _lh(pt) + 0.008
            if self.y - h < _MBOT:
                self.newpage()
                draw_header()
            top = self.y
            self._rect(_ML, top - h, W, h,
                       "#ffffff" if ri % 2 == 0 else "#f6f8fa", "#e4e8ed", 0.5)
            x = _ML
            for i, ls in enumerate(cells):
                mk = (marks or {}).get((ri, i))
                col = {"ok": _OKC, "bad": _BADC}.get(mk, _INK)
                yy = top - 0.005
                for ln in ls:
                    self.fig.text(x + pad, yy, ln, fontsize=pt, color=col,
                                  fontweight="bold" if mk else "normal",
                                  va="top")
                    yy -= _lh(pt)
                x += cw[i]
            self.y = top - h
        self.y -= 0.011

    def chart(self, fn, h=0.20, caption=None):
        self.need(h + 0.014)
        top = self.y
        fn(self.fig, [_ML, top - h, _MR - _ML, h])
        self.y = top - h - 0.008
        if caption:
            self.para(caption, pt=7.4, color=_MUTED)

    def image(self, png, width_frac=0.84, caption=None):
        """Place a raster image at true aspect ratio, centred on the measure."""
        try:
            import matplotlib.image as mpimg
            im = mpimg.imread(png)
        except Exception:  # noqa: BLE001
            return
        ih, iw = im.shape[0], im.shape[1]
        w = (_MR - _ML) * width_frac
        h = w * (_PAGE_W / _PAGE_H) * (ih / float(iw))
        self.need(h + 0.016)
        top = self.y
        ax = self.fig.add_axes([_ML + ((_MR - _ML) - w) / 2.0, top - h, w, h])
        ax.imshow(im)
        ax.axis("off")
        self.y = top - h - 0.007
        if caption:
            self.para(caption, pt=7.4, color=_MUTED)


# ---------------------------------------------------------------------------
# Document content
# ---------------------------------------------------------------------------
def _verdict_kind(v):
    for key, kind in (("FLAWED", "bad"), ("QUESTIONABLE", "warn"),
                      ("決定性", "ok"), ("實測", "ok"), ("MINOR", "info"),
                      ("SOUND", "ok")):
        if key in v:
            return kind
    return "info"


# One-line takeaway per experiment: the single sentence a reader should carry
# away. Everything else on the page is evidence for this line.
_KEYS = {
    "#212": "高剛度下的 undershoot 是 solver 假象,不是真實剛性 —— 固定 k 只改 damping,"
            "下垂就從 -0.10 擺到 +0.05 mm,真穩態下它應該恆等於 mg/k。",
    "#215": "kinematic body 撐到 float32 讀數地板(6e-8 m),同條件的 dynamic body 一步掉 "
            "1.36 mm —— kinematic 與 dynamic 的分野成立。",
    "#216": "原稿把角度當距離:這支報的是 mrad,不是 mm;而且此關節重力零力矩,根本沒有 "
            "mg/k 地板可比。",
    "#219": "maxForce 只要小於負載重量就 stall 在行程底,不是「下垂變大」—— 兩者是不同的失效。",
    "#218": "載運速度上限是 mu 相依的門檻,不是硬性上限;超速後的「發射」是穿透假象,不是物理。",
    "#220": "kinematic 推 dynamic 是單向傳遞:被推的箱子有反應,推板完全不受反作用力影響。",
    "#221": "接縫 give 在 float32 讀數地板之下,所以這支只能給出「上界」,不能宣稱剛性數值。",
    "#227": "三關節下垂就是各關節下垂的幾何疊加,沒有額外的耦合放大。",
    "#229": "浮動 articulation 不會被 kinematic 的 USD 父層帶動 —— 畫面上看起來被拖著走是 "
            "USD 階層的視覺假象,物理上 follow_ratio 約等於 0。",
    "D1": "推板的 back-off 是 drive 跟隨落後,不是接觸反作用 —— 拿掉箱子的對照組 back-off 幾乎一樣。",
    "D2": "高剛度時 payload 打滑是 (k·dt) 離散化假象:dt 一細化就消失。L2.5 載得動,但 dt 要配剛度。",
    "Collision A1/A2": "URDF 裡寫 3 個 box,匯入後就是 3 個真正的 UsdGeom.Cube 碰撞體 —— "
                       "沒有被轉成 hull、沒有多餘分組。",
    "Collision decomp": "convexDecomposition 保得住功能性口袋(maxHulls 8 與 64 都可以),"
                        "所以「原理上不可行」的說法不成立,那是 hull 數的調參問題。",
    "Collision A3/A4": "CAD 慣量與 link 原點在 URDF→USD 轉換中原封不動 —— sw2urdf 最有價值的"
                       "輸出不會被轉換破壞。",
    "Collision 真實資產": "同樣一種棧板,NVIDIA 自己出了三種碰撞狀態(方塊/分解/根本沒有)——"
                          "所以凹槽能不能用,取決於 authoring 選的近似法,與 mesh 品質無關。",
    "Collision entry 圖": "把進叉面掃成佔據圖後,叉孔的有無一眼可見:方塊與 hull 是整片實心,"
                          "只有 decomposition 出現兩條貫穿的孔。",
    "Collision 插入": "決定性證據:decomposition 讓牙叉插進兩條真叉孔、卻在真中柱擋住 —— "
                      "它不是「什麼都放行」,而是忠實還原真實幾何。",
    "Collision importer": "我們的 URDF importer 對 <collision><mesh> 一律寫死 convexHull,"
                          "作者想指定別的近似法這條路並不存在 —— 這就是必須用 box-union 的原因。",
    "限制①": "把 kinematic 錨點焊進 articulation 會讓 PhysX tensor 直接 SIGSEGV,是上游引擎缺陷,"
             "改用 plain dynamic body 可繞開。",
    "限制②": "PhysX 明文禁止 articulation 內的 link 是 kinematic,所以真 L2 只能做在散裝 rigid body。",
    "限制③": "這三支不是技術做不到,是還沒拿到真實 CAD 模型。",
}


def _key_of(exp):
    k = _KEYS.get(exp["id"])
    if k:
        return k
    head = str(exp.get("concl", "")).split("。")[0]
    return head + "。" if head else ""


def cover(doc, reg):
    doc.newpage()
    doc.y = 0.895
    doc.fig.text(_ML, doc.y, "Isaac Sim 6.0.1 物理再驗證", fontsize=26,
                 fontweight="bold", color=_INK, va="top")
    doc.y -= 0.056
    doc.fig.text(_ML, doc.y, "驗收資料表 —— 每支實驗附量化資料、可追溯 log、可重現",
                 fontsize=11.5, color=_MUTED, va="top")
    doc.y -= 0.026
    doc._hline(_ML, _MR, doc.y, color="#1f3b57", lw=1.8)
    doc.y -= 0.034

    doc.callout(
        "這份文件在回答什麼",
        "2026-09 的對抗式審查對 14 支物理實驗逐一挑錯,再加上 collision pipeline 的"
        "獨立查證。每一節都是同一個結構:先給一句結論,再給支撐它的量化表格,"
        "最後給重跑指令。所有數字都來自 test/ 下的 JSON log,頁面附 sha256 可對帳。",
        kind="info")

    doc.h1("環境")
    doc.table(
        ["項目", "值"],
        [["Isaac Sim / Isaac Lab", "6.0.1 / 3.0 (v3.0.0-beta2.patch1)、Kit Python 3.12"],
         ["GPU / 驅動", "NVIDIA GeForce RTX 5090 (31 GiB)、driver 610.43.02"],
         ["Warp", "1.13.0"],
         ["容器 image", "yunchien/isaac:devel (BASE_IMAGE=nvcr.io/nvidia/isaac-sim:6.0.1)"],
         ["physics dt", "1/60 s(fine-dt 對照另有標示)"]],
        widths=[1.0, 3.2])

    doc.h1("判定圖例")
    doc.table(
        ["判定", "意義"],
        [["FLAWED", "headline 結論本身是錯的;已修正並重新驗證"],
         ["QUESTIONABLE", "設計或資料來源有洞;已補對照組 / 重跑,或改寫論述"],
         ["MINOR", "結論成立,只修措辭或對齊數字"],
         ["SOUND / 實測確認", "乾淨,或由本次實測直接證實"]],
        widths=[1.0, 4.0])
    doc.para("統計:1 FLAWED、7 QUESTIONABLE、5 MINOR、1 SOUND,皆已處理。"
             "定性的 L2 / L2.5 / L3 階層一直是對的;這次修的是框架要依賴的量化與機制宣稱。",
             pt=8.5)

    doc.h1("結果總覽")
    doc.para("每列一支實驗。詳細資料表與重跑指令見後續各節。", pt=8.3, color=_MUTED)
    rows, marks = [], {}
    for i, e in enumerate(reg):
        rows.append([e["id"], e["title"], e["verdict"], _key_of(e)])
        k = _verdict_kind(e["verdict"])
        marks[(i, 2)] = "ok" if k == "ok" else ("bad" if k == "bad" else None)
    marks = {k: v for k, v in marks.items() if v}
    doc.table(["編號", "實驗", "判定", "一句話結論"], rows,
              widths=[0.60, 1.50, 1.45, 4.2], pt=6.9, marks=marks)

    doc.h1("影片索引")
    doc.para("PDF 無法播放影片,因此每支有影片的實驗都在該節附一張關鍵幀,"
             "檔案本身放在 doc/viz/。影片只做給「動作在畫面上看得清、而且動作本身就是結論」"
             "的實驗;效應在 mm/µm 級或動作會誤導結論的,一律用圖表而不出影片。",
             pt=8.3, color=_MUTED)
    vrows = [[eid, "doc/viz/" + _VIDEOS[eid][0], _VIDEOS[eid][2]]
             for eid in _VIDEOS]
    vrows += [["(本審查範圍外)", "doc/viz/" + n, c] for n, c in _EXTRA_VIDEOS]
    doc.table(["實驗", "檔案", "畫面內容"], vrows,
              widths=[1.0, 1.6, 5.0], pt=7.0)


def section(doc, title, blurb=None):
    doc.h1(title)
    if blurb:
        doc.para(blurb, pt=8.5, color=_MUTED)


def experiment(doc, exp, test_dir, viz_dir=None):
    kind = _verdict_kind(exp["verdict"])
    doc.h2(f"{exp['id']}  {exp['title']}", tag=f"判定:{exp['verdict']}",
           tag_color=_KIND.get(kind, _KIND["info"])[0])
    doc.callout("結論", _key_of(exp), kind=kind)

    tbl = exp["tbl"]
    cols, rows = tbl[0], tbl[1]
    marks = tbl[2] if len(tbl) > 2 else None
    widths = exp.get("widths")
    if rows:
        doc.table(cols, rows, widths=widths, marks=marks)

    if exp.get("chart"):
        doc.chart(exp["chart"], h=exp.get("chart_h", 0.21),
                  caption=exp.get("chart_cap"))

    vid = _VIDEOS.get(exp["id"])
    if vid and viz_dir:
        name, frac, cap = vid
        still = _video_still(Path(viz_dir) / name,
                             Path(test_dir) / (".still_" + name + ".png"), frac)
        if still:
            doc.image(still, caption="影片 doc/viz/%s 的畫面。%s" % (name, cap))

    doc.para("說明", pt=9.0, weight="bold", gap=0.003)
    doc.para(exp["concl"], pt=8.4)

    log = exp.get("log")
    prov = ("log: (none -- see the reproduce command below)" if not log else
            f"log: test/{log}   sha256: {_sha256(Path(test_dir) / log)}")
    doc.para(prov, pt=7.0, color=_MUTED, mono=True, gap=0.004)
    doc.code(exp["cmd"])


_SECTIONS = [
    ("1. L2.5 / L3 馬達位置控制(會下垂)",
     "用最小幾何(cube / prismatic)隔離單一物理行為,避免真車模型的複雜幾何汙染量測。",
     ["#212", "#227", "#216", "#219"]),
    ("2. 真 L2 kinematic(瞬移、無視外力)",
     "只能做在散裝 rigid body —— PhysX 禁止 articulation 內的 link 是 kinematic。",
     ["#215", "#218", "#220"]),
    ("3. Hybrid 與整合", None, ["#221", "#229"]),
    ("4. L2.5 動態互動(實際部署的 actuator)",
     "dynamic body + 高剛度 drive,才是實際會部署的形態。",
     ["D1", "D2"]),
    ("5. Collision pipeline",
     "這一節回答一個具體問題:為什麼牙叉插不進棧板的叉孔?先用合成幾何隔離,"
     "再用 NVIDIA 官方資產驗證,最後把同一份真實幾何送回我們自己的 importer。",
     ["Collision A1/A2", "Collision decomp", "Collision A3/A4",
      "Collision 真實資產", "Collision entry 圖", "Collision 插入",
      "Collision importer"]),
    ("6. 已知限制", None, ["限制①", "限制②", "限制③"]),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--font", default=None,
                    help="Path to a CJK font (.ttc/.otf) for zh-TW rendering. "
                         "Default: test/.notocjk.ttc then host Noto paths.")
    ap.add_argument("--viz-dir", default=None,
                    help="Directory holding the MP4s (default: <out dir>/viz). "
                         "One still per video is embedded in its section.")
    args = ap.parse_args()
    viz_dir = Path(args.viz_dir) if args.viz_dir else Path(args.out).parent / "viz"

    _init_cjk_font(args.font, args.test_dir)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    reg = build_registry(args.test_dir)
    by_id = {e["id"]: e for e in reg}

    with PdfPages(args.out) as pdf:
        doc = Doc(pdf, note="Isaac Sim 6.0.1 物理再驗證 — 驗收資料表")
        cover(doc, reg)
        for title, blurb, ids in _SECTIONS:
            section(doc, title, blurb)
            for eid in ids:
                e = by_id.get(eid)
                if e is None:
                    continue
                experiment(doc, e, args.test_dir, viz_dir=viz_dir)
        doc.close()
        n = doc.page
    print("wrote", args.out, "with", n, "pages; font:", _CJK_NAME)


if __name__ == "__main__":
    main()
