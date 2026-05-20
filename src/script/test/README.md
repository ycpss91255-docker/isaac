# Standalone scripts smoke

Integration smoke for `isaac_ws/src/script/*_standalone.py`. Each script
must reach its "ready marker" within a timeout when run through
`./exec.sh -t standalone /isaac-sim/python.sh <script>`. The runner
launches the script, polls its stdout for the marker, kills the run
once seen, and reports PASS / FAIL per case.

**[English](README.md)** | **[繁體中文](../../doc/readme/script-test/README.zh-TW.md)** | **[简体中文](../../doc/readme/script-test/README.zh-CN.md)** | **[日本語](../../doc/readme/script-test/README.ja.md)**

## Usage

```bash
# Full matrix (~6-10 min)
./isaac_ws/src/script/test/standalone_smoke.sh

# Single case (fast iteration during script edit)
./isaac_ws/src/script/test/standalone_smoke.sh --only cmd_vel

# CI / strict mode: SKIP becomes FAIL
./isaac_ws/src/script/test/standalone_smoke.sh --strict
```

Pre-requisites:

- `./run.sh -t standalone -d` succeeds (smoke auto-runs it if container is down)
- The curated `isaac_ws/src/model/usd/openbase/openbase.usda` is tracked in
  the repo; the USD-dependent cases use it directly. If the file is
  missing (incomplete checkout / accidental delete), regenerate from the
  in-repo URDF source:

  ```bash
  cd isaac_ws/src/docker
  ./exec.sh -t standalone /isaac-sim/python.sh \
      /home/yunchien/work/src/script/import_urdf.py \
      /home/yunchien/work/src/model/urdf/openbase/openbase_minimal.urdf \
      /tmp/openbase_generated.usda
  ```

  Then move `openbase_generated.usda` to
  `model/usd/openbase/openbase.usda` if you really need to overwrite the
  tracked file. Without the tracked USD the dependent cases SKIP (or
  FAIL under `--strict`).

## Cases

| Script | Marker phrase | Timeout | USD? |
|--------|---------------|--------:|:----:|
| `ros2_test_pub_standalone.py` | `standalone publishing` | 150s | no |
| `ros2_test_sub_standalone.py` | `standalone subscribed to` | 150s | no |
| `cmd_vel_planar_standalone.py` | `standalone subscribed` | 180s | yes |
| `move_openbase_planar_standalone.py` | `[tick` | 180s | yes |

The marker is grepped as a regex against captured stdout+stderr. Each
standalone script prints exactly one of these tagged lines once its
core setup completes (rclpy subscriber active, or first `[tick]`).

## Exit codes

| Code | Meaning |
|-----:|---------|
| 0 | All cases PASS (SKIPped cases tolerated unless `--strict`) |
| 1 | At least one FAIL |
| 2 | Pre-flight failure (docker dir missing / standalone container won't start) |

## Failure debugging

When a case FAILs the runner prints the last 20 lines of the script's
combined stdout+stderr to stderr. Common patterns:

- `ModuleNotFoundError: No module named 'rclpy'` — the `enable_extension("isaacsim.ros2.bridge")` call is missing or runs after `import rclpy`
- `AttributeError: 'NoneType' object has no attribute 'GetPrimAtPath'` — `ctx.open_stage()` returned, but the OPENED-spin loop didn't wait for the stage to populate
- `Failed to open: <USD path>` — USD missing or not readable; check the host-side path
- Hangs to timeout with no marker — kit booted but the script's main loop never reached the print; check for an exception above the marker line in the captured tail

## Why integration not unit

The standalone scripts boot kit + livestream + rclpy subscriber. Pure
Python unit tests cannot substitute for "does the script actually reach
the ROS subscriber loop with USD loaded and bridge alive". The marker
phrase is the contract — once the script can print it, all of
SimulationApp init, the ROS 2 bridge extension load, rclpy import,
node creation, and (if applicable) USD load + OPENED transition have
succeeded.

## Why this dir, not isaac_ws/src/docker/test/

`isaac_ws/src/docker/test/` belongs to the docker repo
(`ycpss91255-docker/isaac`) and tests the container image / wrappers,
not the scripts that run inside it. The standalone scripts live in
`isaac_ws/src/script/` (this repo, `ycpss91255/isaac`); their smoke
lives alongside them so it travels with them.
