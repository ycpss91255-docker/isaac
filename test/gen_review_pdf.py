#!/usr/bin/env python3
"""Generate the consolidated 6.0.1 physics re-validation review PDF.

One multi-page PDF holding, for EVERY reviewed experiment, a quantitative data
TABLE (not a single number) that is:
  * traceable to its log     -- each page prints the source JSON path + sha256,
  * reproducible             -- each page prints the exact container command,
  * post-audit corrected     -- verdict + corrected conclusion from the
                                2026-09 adversarial physics-validity audit and
                                the subsequent driver fixes / re-runs.

Reads the committed / re-run JSON logs under ``<repo>/test/`` and renders with
matplotlib (PdfPages) -- no network, no extra deps beyond what Isaac ships.

Run inside the devel container (matplotlib present)::

    W=/home/<user>/work/worktree/<wt>
    just exec -t devel /isaac-sim/python.sh $W/test/gen_review_pdf.py \\
        --test-dir $W/test --out $W/doc/6.0.1_physics_revalidation_review.pdf
"""

import argparse
import hashlib
import json
import os
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

# Treat text literally: reproduce commands contain '$', '_', '--' which must not
# be parsed as TeX math / subscripts / minus signs.
matplotlib.rcParams["text.parse_math"] = False
matplotlib.rcParams["axes.unicode_minus"] = False

# Container workspace placeholder shown in reproduce commands.
W = "$W"  # = /home/<user>/work/worktree/<wt> ; see the methodology page.
PY = f"just exec -t devel env PYTHONPATH={W}/framework /isaac-sim/python.sh"


def _sha256(path):
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]
    except Exception:
        return "MISSING"


def _load(test_dir, name):
    p = Path(test_dir) / name
    try:
        return json.loads(p.read_text())
    except Exception as exc:  # noqa: BLE001
        return {"__load_error__": f"{type(exc).__name__}: {exc}"}


def f(x, nd=4):
    """Format a number compactly; pass through non-numbers."""
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, (int, float)):
        ax = abs(x)
        if x != 0 and (ax < 1e-3 or ax >= 1e5):
            return f"{x:.3e}"
        return f"{x:.{nd}f}"
    return str(x)


# ---------------------------------------------------------------------------
# Per-experiment table extractors: each returns (columns, rows).
# ---------------------------------------------------------------------------
def t_212(d):
    cols = ["k (N/m)", "droop (mm)", "mg/k pred (mm)", "k_eff/k", "drift (mm)"]
    rows = []
    for p in d.get("points", []):
        dr = p["droop_mm"]
        ratio = p["predicted_mm"] / dr if dr else float("nan")
        rows.append([f(p["stiffness"]), f(dr), f(p["predicted_mm"]),
                     f(ratio, 3), f(p["drift_mm"])])
    dc = d.get("damping_control", {})
    rows.append(["--- damping control @ k=%s (pred mg/k=%s mm) ---"
                 % (f(dc.get("fixed_stiffness")), f(dc.get("predicted_mm"))),
                 "", "", "", ""])
    for p in dc.get("points", []):
        rows.append([f"factor {f(p['damping_factor'],2)} (d={f(p['damping'],1)})",
                     f(p["droop_mm"]), f(dc.get("predicted_mm")), "",
                     f(p["drift_mm"])])
    rows.append([f"spread={f(dc.get('droop_spread_mm'))} mm -> {dc.get('verdict')}",
                 "", "", "", ""])
    return cols, rows


def t_215(d):
    cols = ["body (link class)", "max pos err (m)", "max ang err (deg)",
            "pusher frames", "zero-err"]
    rows = [[f"{b['name']} ({b['kind']})", f(b["max_pos_err_m"]),
             f(b["max_ang_err_deg"]), str(b["pusher_carried_frames"]),
             str(b["zero_error"])] for b in d.get("bodies", [])]
    rows.append([f"all_zero_error = {d.get('all_zero_error')}", "", "", "", ""])
    return cols, rows


def t_216(d):
    cols = ["k (N/m)", "steady-state err (mrad)", "rms track err (mrad)",
            "note"]
    rows = []
    for p in d.get("stiffness_sweep", []):
        sp = p.get("step_phase", {})
        sse_rad = sp.get("steady_state_error_rad")
        rows.append([f(p.get("stiffness_stored")),
                     f(sse_rad * 1000.0 if sse_rad is not None else None),
                     "", "per-DOF; revolute axis +Z (zero gravity torque)"])
    rep = d.get("repeatability", {})
    rms = rep.get("rms_tracking_error_rad_per_run", [None])
    rows.append([f"repeatability k={f(rep.get('ref_stiffness'))}",
                 "", f((rms[0] or 0) * 1000.0), "3 runs, spread %s mrad"
                 % f(rep.get("rms_spread_mrad"))])
    return cols, rows


def t_219(d):
    cols = ["sub-test", "case", "result", "held/clamped"]
    rows = []
    for p in d.get("effort_clamp", {}).get("points", []):
        rows.append(["effort clamp",
                     "maxForce=%sN (%.2gx load)" % (f(p["max_force_N"]),
                                                    p["max_force_vs_load"]),
                     "droop=%s mm" % f(p["droop_mm"]),
                     "held" if p["held_target"] else "STALL@limit"])
    vc = d.get("velocity_clamp", {})
    rows.append(["velocity clamp", "limit 0.3 vs 1000",
                 "peak %s -> %s m/s" % (f(vc.get("high_limit_peak_velocity")),
                                        f(vc.get("low_limit_peak_velocity"))),
                 str(vc.get("clamp_confirmed"))])
    pl = d.get("position_limit", {})
    rows.append(["position limit",
                 "cmd %s m, upper %s m" % (f(pl.get("commanded_target_m")),
                                           f(pl.get("upper_limit_m"))),
                 "settled %s m" % f(pl.get("settled_position_m")),
                 str(pl.get("clamped_at_limit"))])
    si = d.get("solver_iterations", {})
    rows.append(["solver iters", "1 / 4 / 32 iters",
                 "droop spread %s mm" % f(si.get("droop_spread_mm")),
                 "iter-indep=%s" % (not si.get("sensitive_to_iterations"))])
    for c in d.get("gain_scaling_pi_over_180", {}).get("cases", []):
        rows.append(["gain scaling", "%s (%s)" % (c["joint_kind"], c["drive_axis"]),
                     "stored/Kp=%s" % f(c["ratio_stored_over_Kp"]),
                     "match=%s" % c["matches_expected"]])
    return cols, rows


def t_218(d):
    cols = ["mu", "max carried step (m)", "min slipped step (m)",
            "analytic d_crit (m)", "monotonic"]
    rows = []
    for key, v in sorted(d.get("threshold_by_friction", {}).items()):
        rows.append([f(v["mu"], 2), f(v["max_carried_ramp_step_m"]),
                     f(v["min_slipped_ramp_step_m"]), f(v["analytic_d_crit_m"]),
                     str(v["carried_slipped_monotonic"])])
    rows.append([f"friction_monotonic = {d.get('friction_monotonic')}",
                 "", "", "", ""])
    return cols, rows


def t_220(d):
    cols = ["object", "metric", "value"]
    pl = d.get("plate", {})
    cu = d.get("cube", {})
    fp = cu.get("final_pos_m", [None])
    bp = cu.get("baseline_pos_m", [None])
    disp = (fp[0] - bp[0]) if (fp[0] is not None and bp[0] is not None) else None
    rows = [
        ["plate (kinematic)", "max pos err under contact (m)",
         f(pl.get("max_pos_err_contact_m")) + "  [float32 floor; true-by-def]"],
        ["plate (kinematic)", "contact frames", str(pl.get("contact_frames"))],
        ["cube (dynamic)", "displacement x (m)", f(disp) + "  [genuine push]"],
        ["transfer", "one_way_transfer_ok", str(d.get("one_way_transfer_ok"))],
    ]
    return cols, rows


def t_221(d):
    cols = ["mass (kg)", "static give |z| (m)", "body travel (m)", "built"]
    rows = []
    gm = d.get("give_rises_with_mass", {}).get("rigid", {})
    masses = gm.get("masses_kg", [])
    gives = gm.get("static_give_norm_m", [])
    for m, g in zip(masses, gives):
        rows.append([f(m), f(g), "", ""])
    rows.append(["--- give identical across 1000x mass => below float32 floor ---",
                 "", "", ""])
    rows.append(["upper bound: give < ~2e-7 m @ 9810 N", "=> seam stiffness",
                 "> ~5e10 N/m", ""])
    rows.append(["compliant_confirmed=%s  force_transfer_ok=%s"
                 % (d.get("compliant_confirmed"), d.get("force_transfer_ok")),
                 "chain variant (#308): SIGSEGV, never run", "", ""])
    return cols, rows


def t_227(d):
    cols = ["joint", "supported mass (kg)", "sag (mm)", "mg/k pred (mm)",
            "drift (mm)"]
    rows = []
    for p in d.get("chain", {}).get("per_joint", []):
        rows.append([p["joint"], f(p["supported_mass_kg"]), f(p["sag_mm"]),
                     f(p["predicted_mm"]), f(p["drift_mm"])])
    cp = d.get("coupling", {})
    rows.append(["coupling: moved %s to %s m, reached %s mm short"
                 % (cp.get("moved_joint"), f(cp.get("moved_target_m")),
                    f(cp.get("moved_reached_mm_short"))), "", "", "", ""])
    return cols, rows


def t_229(d):
    cols = ["lane", "base travel (m)", "arm travel (m)", "follow ratio",
            "carries"]
    rows = []
    for ln in d.get("lanes", []):
        rows.append([ln["tag"], f(ln["base_travel_x_m"]),
                     f(ln["arm_root_travel_x_m"]), f(ln["follow_ratio"]),
                     str(ln["topology_A_carries"])])
    rows.append([f"finding: {d.get('finding')}", "", "", "", ""])
    return cols, rows


def t_d1(d):
    cols = ["k (N/m)", "cube disp (m)", "backoff contact (mm)",
            "control lag (mm)", "contact reaction (mm)"]
    rows = []
    for p in d.get("points", []):
        rows.append([f(p["stiffness"]), f(p["cube_displacement_x_m"]),
                     f(p["backoff_contact_mm"]),
                     f(p["control_following_lag_mm"]),
                     f(p["contact_reaction_mm"])])
    rows.append(["feed-forward=%s; contact reaction = backoff - no-cube control"
                 % d.get("feedforward"), "", "", "", ""])
    return cols, rows


def t_d2(d, d_fine):
    cols = ["k (N/m)", "payload lag std-dt (mm)", "payload lag fine-dt (mm)",
            "delivery ok (std)", "carrier err (mm)"]
    fine = {p["stiffness"]: p for p in (d_fine or {}).get("points", [])}
    rows = []
    for p in d.get("points", []):
        fp = fine.get(p["stiffness"], {})
        rows.append([f(p["stiffness"]), f(p["payload_lag_mm"]),
                     f(fp.get("payload_lag_mm")), str(p["delivery_ok"]),
                     f(p["carrier_track_err_max_mm"])])
    rows.append(["std dt=%s ; fine dt=%s (4x): high-k slip collapses with dt"
                 % (f(d.get("physics_dt")), f((d_fine or {}).get("physics_dt"))),
                 "", "", "", ""])
    return cols, rows


# ---------------------------------------------------------------------------
# Experiment registry: id, title, verdict, log, reproduce cmd, conclusion.
# ---------------------------------------------------------------------------
def build_registry(test_dir):
    d212 = _load(test_dir, ".prove-A-212-sag.json")
    d215 = _load(test_dir, ".prove-B-215-hold.json")
    d216 = _load(test_dir, ".prove-A-216-tracking.json")
    d219 = _load(test_dir, ".prove-A-219-limits.json")
    d218 = _load(test_dir, ".prove-B-218-carry.json")
    d220 = _load(test_dir, ".prove-B-220-push.json")
    d221 = _load(test_dir, ".prove-C-221-seam.json")
    d227 = _load(test_dir, ".prove-A-227-multijoint.json")
    d229 = _load(test_dir, ".prove-C-229-basecarry.json")
    dd1 = _load(test_dir, ".l25-dynamic-push.json")
    dd2 = _load(test_dir, ".l25-dynamic-carry.json")
    dd2f = _load(test_dir, ".l25-dynamic-carry-finedt.json")
    reg = [
        dict(id="#212", title="Single-joint sag vs stiffness (L2.5/L3)",
             verdict="QUESTIONABLE -> FIXED (damping control added)",
             log=".prove-A-212-sag.json",
             cmd=f"{PY} {W}/src/script/exp_l25_sag_sweep.py "
                 f"--out {W}/test/.prove-A-212-sag.json",
             tbl=t_212(d212),
             concl="Damping control (fixed k=1e6, sweep damping) shows droop "
                   "swings -0.10..+0.05 mm and even goes NEGATIVE at low damping "
                   "-- at true steady state (drift=0) droop must equal mg/k=0.098 "
                   "mm regardless of damping. So the high-k undershoot (k_eff/k up "
                   "to 5.4x) is a TGS implicit-drive spring-stiffening artifact, "
                   "NOT a stiffness property. ADR-0021 D1a 'no floor / beats "
                   "prediction' is refuted; the defensible claim is only 'no "
                   "float32 floor hit in-range'."),
        dict(id="#215", title="Per-link true-kinematic substitution (L2 hold)",
             verdict="QUESTIONABLE (crashed) -> FIXED (NameError; re-run clean)",
             log=".prove-B-215-hold.json",
             cmd=f"{PY} {W}/src/script/exp_l2_kinematic_substitution.py "
                 f"--out {W}/test/.prove-B-215-hold.json",
             tbl=t_215(d215),
             concl="NameError (contact_frames[nm]) fixed -> committed driver now "
                   "produces the table. Kinematic bodies hold to the float32 "
                   "read-back floor (6e-8..4.6e-7 m) under 10 kg load + contact, "
                   "vs a dynamic body that would fall 1.36 mm/step -- the "
                   "kinematic-vs-dynamic distinction is real. The 'ignores "
                   "contact' half is true-by-definition (softened, not a stress "
                   "test)."),
        dict(id="#216", title="L3 trajectory tracking precision",
             verdict="QUESTIONABLE -> DOC CORRECTED (units + inapplicable floor)",
             log=".prove-A-216-tracking.json",
             cmd=f"{PY} {W}/src/script/exp_traj_tracking.py "
                 f"--out {W}/test/.prove-A-216-tracking.json",
             tbl=t_216(d216),
             concl="Driver reports RADIANS/mrad; the acceptance doc mislabeled "
                   "them 'mm' (an angle as a distance). The joint is revolute "
                   "about +Z so gravity gives ZERO torque -> ideal steady-state "
                   "error ~0, NOT mg/k; the doc's 'analytic floor mg/k=1.962 mm' "
                   "was imported from the prismatic experiment and is "
                   "inapplicable. Correct metric: angular tracking error in mrad, "
                   "no gravity floor."),
        dict(id="#219", title="Drive limits: effort / velocity / position",
             verdict="QUESTIONABLE (provenance) -> FIXED (re-run matches driver)",
             log=".prove-A-219-limits.json",
             cmd=f"{PY} {W}/src/script/exp_drive_limits.py "
                 f"--out {W}/test/.prove-A-219-limits.json",
             tbl=t_219(d219),
             concl="Re-run so numbers match the committed driver. Payload weight "
                   "is 98.1 N (10 kg) -- the doc's '49 N weight' mislabeled a "
                   "0.5x maxForce CASE (49.05 N) as the weight. maxForce >= mg "
                   "holds (droop mg/k); maxForce < mg stalls at the lower limit. "
                   "Position limit 0.5 m clamps a 2.0 m command. Droop is "
                   "solver-iteration-independent; revolute drive stores Kp*pi/180."),
        dict(id="#218", title="Kinematic carry speed limit (analytic d_crit)",
             verdict="MINOR (report mu-dependent threshold)",
             log=".prove-B-218-carry.json",
             cmd=f"{PY} {W}/src/script/exp_l2_carry_speed_limit.py "
                 f"--out {W}/test/.prove-B-218-carry.json",
             tbl=t_218(d218),
             concl="Bracket derivation sound: d_crit = dt*sqrt(2*mu*g*L_back) "
                   "matches the measured carried/slipped threshold and rises "
                   "monotonically with mu (0.035..0.077 m/tick). Report the "
                   "mu-dependent threshold, not a coarse single band; the "
                   "high-speed 'launch to 5.19 m' endpoint is a contact-"
                   "penetration artifact, not a physical finding."),
        dict(id="#220", title="Kinematic pushes dynamic (one-way transfer)",
             verdict="QUESTIONABLE -> WORDING SOFTENED",
             log=".prove-B-220-push.json",
             cmd=f"{PY} {W}/src/script/exp_l2_push_dynamic.py "
                 f"--out {W}/test/.prove-B-220-push.json",
             tbl=t_220(d220),
             concl="Plate 'tracks 0.000 under contact' is true-by-definition of "
                   "kinematic (teleport per tick + never integrated -> any "
                   "reaction discarded before read-back), not a measurement -- "
                   "stated as such. The genuine finding is the cube-push: normal-"
                   "overlap depenetration imparts ~1.19 m displacement. One-way "
                   "transfer holds."),
        dict(id="#221", title="Maximal loop-joint seam compliance",
             verdict="QUESTIONABLE -> REFRAMED AS UPPER BOUND",
             log=".prove-C-221-seam.json",
             cmd=f"{PY} {W}/src/script/exp_l2_loop_joint_boundary.py "
                 f"--out {W}/test/.prove-C-221-seam.json",
             tbl=t_221(d221),
             concl="static_give is bit-for-bit identical (2.38e-8 m) across "
                   "1/10/100/1000 kg -> it is the float32 quantization residual, "
                   "not a measured compliance. The run yields only an UPPER BOUND: "
                   "give < ~2e-7 m at 9810 N => seam stiffness > ~5e10 N/m "
                   "(effectively rigid for practical loads). Drop the specific "
                   "give values, the 'mass-invariant' / monotonic sub-claims, and "
                   "'refutes PhysX #308' -- #308 is about CHAINED joints; only a "
                   "single joint ran (the chain variant SIGSEGVs)."),
        dict(id="#227", title="3-joint serial sag accumulation",
             verdict="MINOR (geometric-identity wording)",
             log=".prove-A-227-multijoint.json",
             cmd=f"{PY} {W}/src/script/exp_multijoint_sag.py "
                 f"--out {W}/test/.prove-A-227-multijoint.json",
             tbl=t_227(d227),
             concl="Clean vertical-prismatic stack; measured tip sum 60.3 mm vs "
                   "predicted 58.9 mm (+2.4% real coupling). 'tip error = sum of "
                   "per-joint sags' is a geometric identity of a serial chain, not "
                   "a discovered solver coupling -- the genuine finding is "
                   "measured-sum ~= predicted-sum."),
        dict(id="#229", title="Base carries a floating articulation (negative)",
             verdict="MINOR (doc numbers corrected to committed JSON)",
             log=".prove-C-229-basecarry.json",
             cmd=f"{PY} {W}/src/script/exp_l2_base_carries_arm.py "
                 f"--out {W}/test/.prove-C-229-basecarry.json",
             tbl=t_229(d229),
             concl="Genuine PhysX negative: a USD-hierarchy parent does NOT carry "
                   "a floating articulation (follow_ratio ~0, arm rides 0 while "
                   "base moves 2.5 m) -- a joint is forced. The acceptance doc's "
                   "numbers (base 1.5 m / arm diverges to 2.369 m) were STALE and "
                   "even implied divergence the clean follow=0 run contradicts; "
                   "corrected to the committed JSON (base 2.5 / arm 0 / follow 0)."),
        dict(id="D1", title="L2.5 dynamic push: pusher back-off vs stiffness",
             verdict="QUESTIONABLE -> FIXED (no-cube control + feed-forward)",
             log=".l25-dynamic-push.json",
             cmd=f"{PY} {W}/src/script/exp_l25_dynamic_interaction.py --mode push "
                 f"--out {W}/test/.l25-dynamic-push.json",
             tbl=t_d1(dd1),
             concl="Added drive velocity feed-forward + an identical NO-CUBE "
                   "control lane. Result: control (following-lag) back-off ~= the "
                   "contact back-off at every k, so the PURE contact reaction is "
                   "~0 (<0.13 mm). The soft-end 'back-off' the original attributed "
                   "to contact was drive-following / startup lag, not finite-"
                   "spring reaction -- confirming the audit."),
        dict(id="D2", title="L2.5 dynamic carry: payload lag vs stiffness + dt",
             verdict="FLAWED -> FIXED (feed-forward + dt-refinement control)",
             log=".l25-dynamic-carry.json",
             cmd=f"{PY} {W}/src/script/exp_l25_dynamic_interaction.py --mode carry "
                 f"--out {W}/test/.l25-dynamic-carry.json\n"
                 f"# fine-dt control (4x): --dt 0.004166667 --steps 1200 "
                 f"--warmup 240 --settle 480 "
                 f"--out {W}/test/.l25-dynamic-carry-finedt.json",
             tbl=t_d2(dd2, dd2f),
             concl="The 'stiffer is worse for the payload' conclusion was "
                   "BACKWARDS. First principles: a=0.75 m/s^2 needs 0.75 N "
                   "friction vs 4.9 N static limit (6.5x) -> zero slip in "
                   "continuous motion at any k. The high-k slip is a (k*dt) "
                   "discretization artifact: a stiff drive snaps the per-tick "
                   "position staircase impulsively when dt is not << the drive "
                   "natural period 2*pi*sqrt(m/k). It COLLAPSES with 4x finer dt "
                   "(k=1e5: 154 mm -> 19 mm; k=1e6/1e7 need finer still). Delivery "
                   "is judged on the PAYLOAD lag, not the carrier tracking error "
                   "(which can be <0.05 mm while the cargo lags). L2.5 CAN carry; "
                   "match dt to stiffness."),
        dict(id="Limit (1)",
             title="Articulation + kinematic maximal loop-joint SIGSEGV",
             verdict="MINOR (correctly stated; upstream bug)",
             log=None,
             cmd=f"{PY} {W}/src/script/repro_artic_kinematic_loopjoint_sigsegv.py "
                 f"# native SIGSEGV -> writes no JSON",
             tbl=(["control", "outcome"],
                  [["dynamic body (no ArticulationRootAPI)", "exit 0 (survives)"],
                   ["floating articulation + get_transforms", "SIGSEGV"],
                   ["body-only readback", "survives"],
                   ["no readback", "survives"],
                   ["=> trigger = artic topology x get_transforms "
                    "on kinematic anchor after world.step", ""]]),
             concl="Clean bisection isolates a native SIGSEGV in "
                   "libomni.physx.tensors to a documented-legitimate PhysX "
                   "construct -> upstream engine defect (isaac-sim/IsaacSim#803), "
                   "workaround = plain dynamic body. Note the older ADR-0008 "
                   "wording ('crash at physics-view init') is stale; the repro "
                   "pins it to the post-step get_transforms readback."),
        dict(id="Limit (2)",
             title="PhysX forbids kinematic articulation LINKS",
             verdict="MINOR (correctly stated; PhysX 5.4 doc)",
             log=None,
             cmd="(documentation constraint; #229 usd_child is supporting "
                 "evidence, not proof)",
             tbl=(["fact", "source"],
                  [["links inside an articulation cannot be kinematic",
                    "PhysX 5.4 Articulations doc"],
                   ["true-L2 substitution target = standalone rigid body",
                    "ADR-0008 clause 4 / ADR-0021 D2"],
                   ["#229 proves the COMPLEMENTARY proposition",
                    "supporting, not proof of the clause"]]),
             concl="Core claim correctly attributed to PhysX 5.4 docs. Minor: the "
                   "doc's '#229 proves this' over-attributes -- #229 shows a "
                   "floating root is not dragged by a kinematic USD parent, which "
                   "is supporting evidence, not a proof that links cannot be "
                   "kinematic."),
        dict(id="Limit (3)",
             title="#205 / #171 / #166 deferred on missing CAD",
             verdict="SOUND (genuinely asset-blocked)",
             log=None,
             cmd="(no run: blocked on the user's CAD model)",
             tbl=(["experiment", "blocker"],
                  [["#205 real-vehicle e2e", "needs user CAD model (ADR-0021)"],
                   ["#171 representative-robot e2e", "needs CAD model"],
                   ["#166 DAE color import", "needs CAD (pipeline in ADR-0020)"]]),
             concl="Confirmed genuinely asset-blocked, not a technical "
                   "impossibility: the DAE color-import pipeline (ADR-0020) and "
                   "the CAD dependency (ADR-0021) are specified; only the asset "
                   "is missing."),
    ]
    return reg


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def _wrap(text, width=96):
    import textwrap
    out = []
    for para in text.split("\n"):
        out.extend(textwrap.wrap(para, width=width) or [""])
    return out


def title_page(pdf, test_dir):
    fig = plt.figure(figsize=(8.27, 11.69))
    fig.subplots_adjust(left=0.07, right=0.95, top=0.93, bottom=0.05)
    ax = fig.add_subplot(111)
    ax.axis("off")
    lines = [
        ("Isaac Sim 6.0.1 Physics Re-validation -- Review Data Tables", 16, "bold"),
        ("Post-audit corrected; every experiment traceable to log + reproducible",
         10, "italic"),
        ("", 8, "normal"),
        ("Environment", 12, "bold"),
        ("  Isaac Sim 6.0.1 / Isaac Lab 3.0 (v3.0.0-beta2.patch1), Kit Python 3.12",
         9, "normal"),
        ("  GPU: NVIDIA GeForce RTX 5090 (31 GiB); driver 610.43.02; Warp 1.13.0 "
         "(CUDA 12.9)", 9, "normal"),
        ("  Container image: yunchien/isaac:devel (base BASE_IMAGE="
         "nvcr.io/nvidia/isaac-sim:6.0.1)", 9, "normal"),
        ("  Physics dt: 1/60 s (unless a per-experiment fine-dt control says "
         "otherwise)", 9, "normal"),
        ("", 8, "normal"),
        ("Reproduce (from the isaac worktree root)", 12, "bold"),
        ("  W=/home/<user>/work/worktree/<wt>   # container path of this worktree",
         9, "mono"),
        ("  just setup apply && just run -t devel -d       # start devel container",
         9, "mono"),
        ("  # then run each per-page command (env PYTHONPATH=$W/framework is only",
         9, "mono"),
        ("  # required for URDF-import drivers but is harmless everywhere)",
         9, "mono"),
        ("", 8, "normal"),
        ("Verdict legend (2026-09 adversarial physics-validity audit)", 12, "bold"),
        ("  FLAWED       headline conclusion was wrong; fixed + re-verified",
         9, "normal"),
        ("  QUESTIONABLE design/provenance gap; fixed (control added / re-run) "
         "or doc corrected", 9, "normal"),
        ("  MINOR        conclusion holds; wording / number alignment only",
         9, "normal"),
        ("  SOUND        clean", 9, "normal"),
        ("", 8, "normal"),
        ("Tally: 1 FLAWED, 7 QUESTIONABLE, 5 MINOR, 1 SOUND -> all addressed.",
         10, "bold"),
        ("Qualitative L2/L2.5/L3 hierarchy was always correct; this pass fixed "
         "the", 9, "normal"),
        ("quantitative / mechanistic claims the framework depends on.", 9,
         "normal"),
    ]
    y = 0.96
    for txt, sz, style in lines:
        weight = "bold" if style == "bold" else "normal"
        st = "italic" if style == "italic" else "normal"
        fam = "monospace" if style == "mono" else "sans-serif"
        ax.text(0.0, y, txt, fontsize=sz, fontweight=weight, fontstyle=st,
                family=fam, transform=ax.transAxes, va="top")
        y -= 0.021 + sz * 0.0013
    pdf.savefig(fig)
    plt.close(fig)


def exp_page(pdf, exp, test_dir):
    fig = plt.figure(figsize=(8.27, 11.69))
    fig.subplots_adjust(left=0.06, right=0.97, top=0.95, bottom=0.04)

    # Header
    hax = fig.add_axes([0.06, 0.86, 0.91, 0.11])
    hax.axis("off")
    hax.text(0.0, 1.0, f"{exp['id']}  {exp['title']}", fontsize=13,
             fontweight="bold", va="top")
    hax.text(0.0, 0.55, f"Verdict: {exp['verdict']}", fontsize=10,
             color="#8a1500", va="top")
    log = exp.get("log")
    prov = "log: (none -- see command)" if not log else (
        f"log: test/{log}   sha256:{_sha256(Path(test_dir) / log)}")
    hax.text(0.0, 0.2, prov, fontsize=8, family="monospace", va="top")

    # Table
    cols, rows = exp["tbl"]
    tax = fig.add_axes([0.06, 0.34, 0.91, 0.5])
    tax.axis("off")
    if rows:
        tbl = tax.table(cellText=[[str(c) for c in r] for r in rows],
                        colLabels=cols, loc="upper left", cellLoc="left")
        tbl.auto_set_font_size(False)
        tbl.set_fontsize(7.2)
        tbl.scale(1.0, 1.25)
        for (r, c), cell in tbl.get_celld().items():
            cell.set_edgecolor("#cccccc")
            if r == 0:
                cell.set_facecolor("#1f3b57")
                cell.set_text_props(color="white", fontweight="bold")

    # Reproduce command
    cax = fig.add_axes([0.06, 0.20, 0.91, 0.12])
    cax.axis("off")
    cax.text(0.0, 1.0, "Reproduce:", fontsize=9, fontweight="bold", va="top")
    y = 0.78
    for ln in _wrap(exp["cmd"], width=104):
        cax.text(0.0, y, ln, fontsize=7, family="monospace", va="top")
        y -= 0.16

    # Conclusion
    concax = fig.add_axes([0.06, 0.04, 0.91, 0.15])
    concax.axis("off")
    concax.text(0.0, 1.0, "Corrected conclusion:", fontsize=9,
                fontweight="bold", va="top")
    y = 0.86
    for ln in _wrap(exp["concl"], width=104):
        concax.text(0.0, y, ln, fontsize=8, va="top")
        y -= 0.085

    pdf.savefig(fig)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test-dir", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    reg = build_registry(args.test_dir)
    with PdfPages(args.out) as pdf:
        title_page(pdf, args.test_dir)
        for exp in reg:
            exp_page(pdf, exp, args.test_dir)
    print("wrote", args.out, "with", 1 + len(reg), "pages")


if __name__ == "__main__":
    main()
