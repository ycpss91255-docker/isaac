# Reproducible Acceptance Harness

Ties the Isaac Sim 6.0.1 environment to every acceptance item so anyone can
re-run a driver from a clean clone and confirm the recorded numbers, and, for
the visual items, watch the same scene live over WebRTC.

All numbers below were recorded on a real GPU (RTX 5090), Isaac Sim 6.0.1 /
Isaac Lab 3.0. Each numeric driver writes its results as JSON to a mounted
`--out` path (stdout through the docker wrapper is not reliably captured, so the
file is the source of truth). Acceptance = read the JSON back on the host and
check the key numbers match.

Driver source: `src/script/exp_*.py`. Container path convention: the repo root
is mounted at `/home/<user>/work` (see README "Cache layout" / "Container
user"), so a driver is `/home/<user>/work/src/script/<driver>.py` and outputs
land under `/home/<user>/work/test/`. Substitute `<user>` with `USER_NAME` from
`.env`.

---

## 1. Environment spin-up (from a clean clone)

### 1.1 One-time host setup

```bash
./script/init_isaac_dirs.sh   # first time only -- creates 8 host-owned cache dirs
just docker build                    # builds devel stage (~16 GB image)
```

`init_isaac_dirs.sh` MUST run before `just docker build`; skipping it lets the docker
daemon create the cache mounts as root and Isaac Sim then fails to write.

### 1.2 Generate `.env.generated` + `compose.yaml`

`just docker setup apply` regenerates `.env.generated` (compose variable cache) and
`compose.yaml` (the profile-gated services: `devel`, `test`, `headless`,
`stream`, `producer`) from `.setup.conf` + system detection. `apply` is the
default subcommand, so a bare `just docker setup` does the same. `just docker build` /
`just docker run` auto-regenerate on drift, so an explicit apply is only needed for a
scripted/CI path or after editing `.setup.conf`.

```bash
just docker setup apply           # regenerate .env.generated + compose.yaml
```

### 1.3 One-shot headless run (per experiment)

The `test` compose service is the `devel-test` Dockerfile stage with a GPU
reservation (`.setup.conf [stage:devel-test]`, base #493), so it can boot
headless Isaac. Run a driver once and let the container exit:

```bash
docker compose --env-file .env.generated --profile test run --rm test \
  /isaac-sim/python.sh /home/<user>/work/src/script/<driver>.py \
  --out /home/<user>/work/test/<results>.json
```

First headless launch spends 1-3 min compiling shaders; subsequent launches
start in `< 30s` from the persisted caches. Read `<results>.json` back on the
host to accept.

### 1.4 Live-watch path (WebRTC)

To watch a driver render live instead of only reading JSON, use the `stream`
stage (`ISAAC_LIVESTREAM=2`) plus an exec of the driver. Exact README commands:

```bash
just docker run -t stream -d                                   # idle container + WebRTC streaming
just docker exec -t stream /isaac-sim/python.sh <driver>       # launch the driver into it
just docker stop                                                  # cleanup
```

Connect a viewer while `stream` is running:

- Desktop: the Isaac Sim WebRTC Streaming Client. Server = `localhost` (same
  machine) or the server LAN IP. Do NOT append `:8011` or any port.
- Browser: the `omniverse_web_viewer` sidecar (bundled at `web_viewer/`). After
  `git submodule update --init --recursive web_viewer` and creating
  `config/host.yaml`, `just docker run -t stream -d` brings up the viewer; open
  Chrome/Chromium at `http://<host-ip>:5173`.

Only one client can connect at a time (NVIDIA limitation). First-time shader
compile takes 1-3 min before the viewport renders. Firewall must allow
`8011/tcp` and `49100/tcp`. See README "Connecting to the WebRTC livestream".

Note: the numeric drivers boot headless with rendering off -- exec'ing them into
`stream` still only produces JSON. The scenes meant to be watched are the
`--mode viz` render of `exp_l25_dynamic_interaction.py` (section 3),
`exp_visual_metric_acceptance.py` (renders a real RTX frame), and
`exp_modela_usd_stability.py` (visible chassis motion).

---

## 2. Per-experiment acceptance

Command column is the one-shot `test`-profile form of section 1.3; only the
driver + `--out` differ. Substitute `<user>`. All paths are container paths.

| Acceptance | Driver (`src/script/`) | One-shot command (after the `docker compose ... --profile test run --rm test` prefix) | Expected key numbers | Physics requirement | Live-view |
|---|---|---|---|---|---|
| A-212-sag (#212) | `exp_l25_sag_sweep.py` | `/isaac-sim/python.sh .../exp_l25_sag_sweep.py --out .../test/.sag-sweep.json` | droop = m*g/k: ~19.4 mm @ k=5000, 0.79 mm @ k=1e5, 0.018 mm @ k=1e6; drift 0 | L2.5 finite-spring droop tracks load/stiffness (mg/k); monotone convergence, no precision floor | numbers only |
| A-227-multijoint (#227) | `exp_multijoint_sag.py` | `/isaac-sim/python.sh .../exp_multijoint_sag.py --masses 5.0 5.0 5.0 --target 0.0 --step-delta 0.5 --settle-steps 800 --coupling-steps 1100 --out .../test/.multijoint-sag.json` | tip total 60.21 mm, additive over 3 links (30.34/20.05/9.82 base->tip, sum-of-predicted 58.86, ratio 1.023); cross-joint transient ~45.0 mm -> residual ~0.012 mm. NOTE: the args matter -- bare defaults use masses 1/1/1 and give ~12 mm | Serial position-drive sag compounds linearly (Sum mg/k); held joints deviate then re-settle | numbers only |
| A-216-tracking (#216) | `exp_traj_tracking.py` | `/isaac-sim/python.sh .../exp_traj_tracking.py --out .../test/.traj-tracking.json` | ANGULAR (revolute joint, radians): sine-tracking RMS ~3.578 mrad at ref stiffness 5000 (sweep 500/5000/50000 -> 22.9/3.58/0.081 mrad, i.e. 1/k); steady-state ~1.8e-7 rad (~0, float32 floor); repeat spread 0 (deterministic). NOTE: the 5.1 #216 mm figure was a prismatic setup; this reval driver is revolute (mrad) | L3 tracking error scales 1/k, steady-state at the float32 floor; runs reproducible across resets | numbers only |
| A-219-limits (#219) | `exp_drive_limits.py` | `/isaac-sim/python.sh .../exp_drive_limits.py --out .../test/.drive-limits.json` | 30 N cap cannot hold 49 N load (stalls ~0, gap 0.800 m); 500 N cap reaches ~0.79 mm; joint pos hard-clamps at 1.000 m, overshoot 0 | Effort clamp is a hard ceiling (stiffness cannot rescue); joint position limit clamps exactly | numbers only |
| A-189-gain (#189) | `exp_revolute_gain_scaling.py` | `/isaac-sim/python.sh .../exp_revolute_gain_scaling.py --out .../test/.gain-scaling.json` | angular gains stored *pi/180 (per-degree): 180 deg -> pi exactly (double-apply would give 0.0548); linear drive takes no conversion | USD stores angular drive gains per-degree while config Kp is per-radian; conversion applied once, angular-only (#168) | numbers only |
| B-215-hold (#215) | `exp_l2_kinematic_substitution.py` | `/isaac-sim/python.sh .../exp_l2_kinematic_substitution.py --out .../test/.l2-kinematic.json` | kinematic zero-error hold ~6e-8 m under 10 kg (error 0.0, < 1e-4), shape-independent | True L2 kinematic body holds commanded pose exactly, ignoring gravity + contact (one-way) | numbers only |
| B-218-carry (#218) | `exp_l2_carry_speed_limit.py` | `/isaac-sim/python.sh .../exp_l2_carry_speed_limit.py --out .../test/.l2-carry.json` | clean carry <= 0.05 m/tick; 0.2 m/tick launches payload (to 5.19 m); teleport (setGlobalPose) carries nothing | Friction-limited carry has a per-tick speed limit; exceeding it launches (not drops); a true kinematic target is required to impart velocity | numbers only |
| B-220-push (#220) | `exp_l2_push_dynamic.py` | `/isaac-sim/python.sh .../exp_l2_push_dynamic.py --out .../test/.l2-push.json` | cube pushed ~0.9-1.2 m (peak speed > 0, ground height holds); plate tracking 0.000 mm even during contact | ADR-0008 rule 1: kinematic pushes dynamic one-way, nothing pushes it back (infinite mass) | numbers only |
| C-221-seam (#221) | `exp_l2_loop_joint_boundary.py` | `/isaac-sim/python.sh .../exp_l2_loop_joint_boundary.py --out .../test/.l2-loopjoint.json` | dynamic-body ("rigid") seam static give ~0.024 um (24 nm) @ 10 kg on 6.0.1, follow_ratio ~1.0; peak dynamic give ~0.36 um; give ~flat across 1/10/100/1000 kg. (5.1 measured ~10 um -- 6.0.1 is stiffer.) `artic` variant SIGSEGVs (exit 139, #803) | Maximal-coordinate fixed joint transmits force (follow ~1) but is effectively RIGID, not compliant (give ~24 nm, ~load-independent on 6.0.1) -- refutes the PhysX-#308 soft-fixed-joint expectation; use a D6/spring joint for real compliance | numbers only (`rigid` default; `--variants artic` reproduces the crash) |
| C-229-basecarry (#229) | `exp_l2_base_carries_arm.py` | `/isaac-sim/python.sh .../exp_l2_base_carries_arm.py --out .../test/.l2-base-carry.json` | negative result: base moves 1.500 m exact, USD-hierarchy parent does NOT carry the floating articulation (arm diverges to 2.369 m, err 0.869 m, tracked=False); a joint is required | A floating multibody lives in the world inertial frame; a moving kinematic USD parent does not drag it -- connection must be a joint | numbers only |
| D1-l25-push | `exp_l25_dynamic_interaction.py --mode push` | `/isaac-sim/python.sh .../exp_l25_dynamic_interaction.py --mode push --out .../test/.l25-dynamic-push.json` | cube pushed at every k (~1.20 m); pusher back-off ~1/k: 6.823 mm @ 1e4, 0.355 mm @ 1e5, 0.035 mm @ 1e6, 0.0082 mm @ 1e7 | L2.5 finite-spring reaction (back-off ~ contact-force/k); k >= 1e6 approximates L2 zero back-off | via `--mode viz` (section 3) |
| D2-l25-carry | `exp_l25_dynamic_interaction.py --mode carry` | `/isaac-sim/python.sh .../exp_l25_dynamic_interaction.py --mode carry --out .../test/.l25-dynamic-carry.json` | payload rides at every k (final z=0.800, no slip/launch); carrier lag ~1/k: 23.36 mm @ 1e4, 1.633 mm @ 1e5, 0.036 mm @ 1e6, 0.0059 mm @ 1e7 | L2.5 carrier tracking degrades as 1/k; k >= 1e6 lag < 0.05 mm ~ true L2 kinematic | via `--mode viz` (section 3) |

### D-region conclusion

L2.5 (dynamic body + high-stiffness drive) meets the requirement: L2's
qualitative behavior (pushes the cube, carries the payload) holds at every
tested stiffness, with only precision degrading as 1/k. ~1e5 N/m reaches
centimetre-level alignment; ~1e6 N/m is nearly indistinguishable from true L2
kinematic (back-off / lag both < 0.05 mm).

### Two extra on-main drivers

| Acceptance | Driver (`src/script/`) | One-shot command | What it proves | Live-view |
|---|---|---|---|---|
| #209 visual+metric | `exp_visual_metric_acceptance.py` | `/isaac-sim/python.sh .../exp_visual_metric_acceptance.py --out .../test/.visual-metric.json --png .../test/visual_metric_frame.png` | RTX renders real geometry headless (non-black, non-flat frame captured to PNG); prim counts / poses / bbox match authored contract; model projects inside the acceptance camera frustum | yes (RTX frame; PNG on host) |
| #94 USD stability | `exp_modela_usd_stability.py` | `/isaac-sim/python.sh .../exp_modela_usd_stability.py --out .../test/.modela-stability.json` | committed Model A forklift USD (6 kinematic cubes) stays stable in a richer scene: per-cube tracking ~0, z/roll/pitch locked through bumps, no NaN, coords bounded, dynamic neighbours settle | yes (visible chassis SE(2) motion) |

---

## 3. How to visually confirm D1

`exp_l25_dynamic_interaction.py --mode viz` renders the push at two stiffnesses
side by side -- k=1e4 (soft, back-off ~6.8 mm visible to the eye) vs k=1e6
(stiff, nearly flush) -- with a green command-reference marker and a per-frame
HUD overlaying the live numbers (cmd_x / actual_x / back-off / cube_x). The
visible gap between the pusher plate and the command-reference line IS the
back-off, so the picture and the numbers agree frame by frame.

One-shot (headless RTX render, writes a PNG sequence + GIF under `--viz-dir`,
default `<out-parent>/viz`, plus a per-frame trace JSON at `--out`):

```bash
docker compose --env-file .env.generated --profile test run --rm test \
  /isaac-sim/python.sh /home/<user>/work/src/script/exp_l25_dynamic_interaction.py \
  --mode viz --out /home/<user>/work/test/.l25-viz-trace.json
```

Read the PNGs / GIF back on the host and cross-check each overlay against the
per-frame JSON. Re-running the same driver reproduces the frames.

The same scene can be watched live over WebRTC via the stream path of section
1.4:

```bash
just docker run -t stream -d
just docker exec -t stream /isaac-sim/python.sh /home/<user>/work/src/script/exp_l25_dynamic_interaction.py --mode viz --out /home/<user>/work/test/.l25-viz-trace.json
```

Connect the desktop client or browser viewer (section 1.4) to watch the push
render at k=1e4 vs k=1e6 in real time.
