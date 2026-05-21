# Installing the Stereolabs ZED Isaac Sim Extension

`config/camera/zed.yaml` targets the **Stereolabs ZED X** sim model via the official Stereolabs Isaac Sim extension. The extension is **third-party** (community tab in the Isaac Sim extension manager) and **not bundled** with `ycpss91255-docker/isaac`, so you have to install it once before the zed dispatch path in `script/camera_setup.py` can boot.

If you do not need the zed path, ignore this doc and stick with `config/camera/realsense.yaml` (D455, NVIDIA-bundled asset) or `config/camera/custom.yaml` (ZED-M baseline via generic camera prims, no Stereolabs extension needed).

## Status of this guide

**2026-05-21 — currently blocked upstream.** The Isaac Sim 5.1 extension registry already lists Stereolabs's `sl.sensor.camera` extension at multiple versions (4.2.1, 4.2.0, 3.1.0, ...), so in principle the install collapses to a one-line enable. **But** every registered version targets the **CPython 3.10 ABI** (`cp310`), while Isaac Sim 5.1 ships with **Python 3.11** (`cp311`). The kit extension manager refuses to enable the cp310 builds against a cp311 host — the error reads:

```
Can't find extension with name: sl.sensor.camera
 - [sl.sensor.camera-4.2.1+107.3.wx64.lx64.r.cp310] (registry)
 ...
```

(The trailing `r.cp310` is the blocker.)

Until Stereolabs releases a cp311 build, the `zed` dispatch in `script/camera_setup.py` raises a clear `RuntimeError` that points at this doc. **Until then, use `config/camera/realsense.yaml` (D455) or `config/camera/custom.yaml` (ZED-M baseline via generic Camera prims) instead.** The custom path was designed precisely for this case — your physical ZED-M can still be modelled.

Once Stereolabs ships a cp311 / Isaac Sim 5.1 compatible build, the install drops to the one-line enable in §1 below and the `_setup_zed()` graph build step in `camera_setup.py` can be filled in (currently a tracked `NotImplementedError`).

## Steps

### 1. Enable from registry (once cp311 build is released)

```python
import omni.kit.app
ext_mgr = omni.kit.app.get_app().get_extension_manager()
ext_mgr.set_extension_enabled_immediate("sl.sensor.camera", True)
```

If `True` is returned, Isaac Sim has fetched, cached, and loaded the extension. Skip to verification in §6.

If the return is `False` and the error mentions `cp310`, the cp311 build has not been released yet — fall back to `config/camera/custom.yaml` and revisit this doc when Stereolabs updates.

### 2. Fallback — manual build from upstream

## Steps

### Manual fallback steps (only if registry path in §1 fails)

#### a. Clone the Stereolabs extension repo on the host

```bash
cd ~/workspace   # or wherever you keep third-party repos
git clone https://github.com/stereolabs/zed-isaac-sim.git
cd zed-isaac-sim
git checkout main   # or a known-good tag if the head is broken
```

#### b. Build the extension (Linux)

```bash
./build.sh
```

This produces a built extension under `./exts/`. On Windows, use `./build.bat` instead.

#### c. Mount the extension into the Isaac container

`ycpss91255-docker/isaac` runs Isaac Sim 5.1 inside a container. The Stereolabs extension lives outside it, so we mount the built `exts/` directory in. Edit the docker compose / `.env` for the headless stage to add a bind:

```
host:  <your-clone-path>/zed-isaac-sim/exts
in container:  /isaac-sim/extra_exts/zed
```

Then restart the headless container:

```bash
cd isaac_ws/src/docker
./stop.sh -t headless
./run.sh -t headless -d
```

Verify the bind landed:

```bash
./exec.sh -t headless ls /isaac-sim/extra_exts/zed
# Expected: sl.sensor.camera (or similar Stereolabs extension dir)
```

#### d. Add the mounted path to Isaac Sim's extension search

Inside the driver (or any Isaac Sim Python entrypoint), add the extra extension path before enabling the extension:

```python
import omni.kit.app
ext_mgr = omni.kit.app.get_app().get_extension_manager()
ext_mgr.add_path("/isaac-sim/extra_exts/zed")
ext_mgr.set_extension_enabled_immediate("sl.sensor.camera", True)
```

`script/camera_setup.py` does this for you when `sensor.type == "zed"`; the dispatch falls back to a clear error if the path or extension name does not resolve.

### 5. (Optional) ZED ROS 2 wrapper on the consumer side
(Applies to both the registry path and the manual-build path above.)

The Stereolabs ROS 2 wrapper (`zed_ros2_wrapper`) bridges the in-Kit ZED publisher topics into a standard ROS 2 node tree on a separate container. Without it the topics published by the Kit-side ZED OmniGraph node are still usable, just without the conventional `zed_*` node namespace. Install on a sibling `ros:humble` container only if you want the wrapper-side tree:

```bash
docker run -d --rm --name zed-ros2 --network host ros:humble bash -c \
  'apt-get update && apt-get install -y ros-humble-zed-ros2-wrapper && \
   source /opt/ros/humble/setup.bash && \
   ros2 launch zed_wrapper zed_camera.launch.py camera_model:=zedm sim_mode:=true'
```

The wrapper auto-detects sim topics if `sim_mode:=true`.

### 6. Verifying the install

After the four steps above, the dispatch in `script/camera_setup.py` should boot without raising the install-missing error:

```bash
cd isaac_ws/src/docker
./exec.sh -t headless /isaac-sim/python.sh \
    /home/yunchien/work/src/script/forklift_blocky_driver_wip.py \
    --config /home/yunchien/work/src/config/camera/zed.yaml
```

The driver log should show `camera graph created at /World/CameraGraphs/forklift_camera_zed`. Topics on a sibling ros:humble container should include `<topic_prefix>/left/image_rect_color`, `<topic_prefix>/depth/depth_registered`, etc.

## Troubleshooting

- **`set_extension_enabled_immediate("sl.sensor.camera", True)` returns false** — extension dir not on Isaac's path. Re-check step 3 + step 4. The exact extension name may differ between Stereolabs versions; inspect `<mount-dir>/sl.*/extension.toml` and use whatever the `[package] name` field says.
- **ZED OmniGraph node not registered** — ext loaded but kit needs an `update()` cycle to register its nodes. The dispatch in `camera_setup.py` already calls `sim_app.update()` before building the graph; if you're using a custom entrypoint, do the same.
- **No topics on consumer side** — Stereolabs publishes through its own SDG pipeline, which may need a different DDS profile than the standard `isaacsim.ros2.bridge`. Check `FASTRTPS_DEFAULT_PROFILES_FILE` is the same on both sides.

## References

- Stereolabs ZED Isaac Sim repo: <https://github.com/stereolabs/zed-isaac-sim>
- Stereolabs ZED Sim extension overview: <https://www.stereolabs.com/docs/isaac-sim>
- ZED ROS 2 wrapper: <https://github.com/stereolabs/zed-ros2-wrapper>
- ADR-0006 — per-sensor-type YAML config (zed schema lives there)
