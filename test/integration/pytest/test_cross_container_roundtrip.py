"""Isaac<->ament cross-container ROS 2 round-trip (isaac#132, M2 gate).

PRD Pre-Publish item 1: prove a real ROS 2 message crosses the container
boundary in BOTH directions between the Isaac example (``example/sim/``)
and the ament example package (``example/ros2/``):

* sim -> ament (camera): the framework camera OmniGraph chain in the
  Isaac container publishes ``/camera_bot/camera/color/image_raw``; the
  ament ``example_app_py camera_subscriber`` node, running in a SIBLING
  ``ros:humble`` container on the host network, receives a real sim frame
  and logs ``[FRAME OK] ... frame_id=camera_bot_camera_color_optical_frame``.
* ament -> sim (cmd_vel): the ament ``example_app_py cmd_vel_publisher``
  node in the sibling container publishes ``/cmd_vel``; the Isaac side's
  ``RosIo.latest('/cmd_vel')`` (an OmniGraph Subscribe attribute, no
  in-process rclpy publisher) picks it up and the Isaac runner logs
  ``[XC CMD_VEL RX] ...`` -- a Twist that originated in the other
  container.

This is HOST-orchestrated (it spawns two sibling containers on the host
DDS network -- the proven #127/#131 ``docker run --rm ros:humble`` +
``ROS_DOMAIN_ID`` / fastdds-profile pattern), so it runs as the host leg
of ``assert_pytest_baseline.sh --gpu`` rather than inside the Isaac
container. It is skipped (not failed) when its prerequisites -- a docker
daemon, the built Isaac ``test`` image, and a real GPU -- are absent, so a
non-GPU host collects it without a false red. A skipped GPU job does not
count as green (PRD Testing & Acceptance), enforced by the baseline
script's ``passed > 0`` rule.

Marker-line acceptance (the Isaac side's Kit ``_exit(0)`` swallows the
return code, same convention as the other GPU runners). Headless (no
livestream, bypasses IsaacSim#228). Generous timeout (Isaac boot 60-120 s
warm; budget x 1.5).

Resilience to transient cross-container DDS discovery misses (isaac#224):
the CAMERA direction (the slow, discovery-bound one) is retried in two
nested layers, both logged. Inner: within a single round-trip the camera
sibling is relaunched against the still-live Isaac publisher up to
``CAMERA_MAX_ATTEMPTS`` times (cheap -- no Isaac reboot), each attempt
preceded by a brief discovery warm-up. Outer: the whole round-trip is
re-run up to ``MAX_RETRIES`` extra times. PASS stays honest -- a real
no-frame-ever fails every attempt and so fails the test.
"""

import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
ISAAC_RUNNER = Path(__file__).parent / "_cross_container_runner.py"
ROS2_WS = REPO_ROOT / "example" / "ros2"

# Container-side mount point for the repo (the test service maps the
# workspace to ~/work; this test mounts the repo there explicitly so the
# runner's --repo-root resolves regardless of nested-worktree layout).
CONTAINER_WORK = "/home/yunchien/work"

PYTHON_SH = "/isaac-sim/python.sh"
ROS_IMAGE = "ros:humble"

# DDS env every participant must share for host-network discovery
# (compose test service + config/ros2/fastdds.xml). The sibling
# containers inherit these so they find the Isaac participant.
ROS_DOMAIN_ID = "0"
RMW = "rmw_fastrtps_cpp"
FASTDDS_PROFILE = REPO_ROOT / "config" / "ros2" / "fastdds.xml"

EXPECTED_CAMERA_TOPIC = "/camera_bot/camera/color/image_raw"
EXPECTED_CAMERA_FRAME_ID = "camera_bot_camera_color_optical_frame"

# Sibling cmd_vel content; asserted echoed on the Isaac side.
SENT_VX = 0.37
SENT_WZ = 0.19

# Isaac boot budget (warm Kit boot + camera graph + first frame + the
# sibling discovery / message exchange window). GPU CI policy timeout =
# boot budget x 1.5.
BOOT_BUDGET_SEC = 420
SUBPROC_TIMEOUT_SEC = int(BOOT_BUDGET_SEC * 1.5)
READY_WAIT_SEC = 300
# Per-attempt frame window for the sibling camera_subscriber to colcon-build
# + discover the Isaac participant across the container boundary + receive the
# first sim frame. A modest margin over the original 120 s -- under GPU-host
# load the discovery + first frame occasionally raced past the narrower
# window (isaac#224); the primary robustness comes from the bounded relaunch
# retry below, this is only headroom.
SIBLING_TIMEOUT_SEC = 150
# Cross-container DDS discovery warm-up. A brief settle after (re)launching
# the camera sibling so the fastdds host-network discovery handshake has a
# slice of its own before the frame window is counted, rather than the whole
# budget being spent on discovery and then racing the first frame. The first
# (concurrently-spawned) attempt is warmed for free by overlapping the
# colcon-build + discovery with the Isaac-side cmd_vel wait; this explicit
# settle warms each RELAUNCHED attempt.
DISCOVERY_WARMUP_SEC = 5
# Bounded in-test retry of the CAMERA direction only. If the first sibling
# misses its frame window (a transient discovery race, isaac#224), the
# sibling is torn down and a FRESH one is relaunched against the still-live
# Isaac publisher (the runner lingers, so this is far cheaper than the
# fixture-level whole-roundtrip reboot below). A genuine no-frame-ever still
# fails: every attempt must miss for the test to fail.
CAMERA_MAX_ATTEMPTS = 2
MAX_RETRIES = 1

COMPOSE_PROJECT = os.environ.get("XC_COMPOSE_PROJECT", "yunchien-isaac")


def _docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    try:
        subprocess.run(
            ["docker", "info"],
            capture_output=True,
            timeout=30,
            check=True,
        )
    except (subprocess.SubprocessError, OSError):
        return False
    return True


def _test_image_built() -> bool:
    """The devel-test GPU image must exist (built by ./script/build.sh -t test)."""
    user = os.environ.get("DOCKER_HUB_USER", "")
    if not user:
        env_gen = REPO_ROOT / ".env.generated"
        if env_gen.is_file():
            for line in env_gen.read_text().splitlines():
                if line.startswith("DOCKER_HUB_USER="):
                    user = line.split("=", 1)[1].strip()
                    break
    if not user:
        return False
    image = f"{user}/isaac:test"
    try:
        out = subprocess.run(
            ["docker", "image", "inspect", image],
            capture_output=True,
            timeout=30,
        )
    except (subprocess.SubprocessError, OSError):
        return False
    return out.returncode == 0


requires_xc = pytest.mark.skipif(
    not (_docker_available() and _test_image_built()),
    reason=(
        "cross-container round-trip: needs a docker daemon, the built "
        "GPU `isaac:test` image, and a real GPU -- skipped on a host "
        "without them (a skipped GPU job is not green, PRD Testing & "
        "Acceptance)"
    ),
)


def _ros_env_args() -> list[str]:
    return [
        "-e", f"ROS_DOMAIN_ID={ROS_DOMAIN_ID}",
        "-e", f"RMW_IMPLEMENTATION={RMW}",
        "-e", "FASTRTPS_DEFAULT_PROFILES_FILE=/cfg/fastdds.xml",
    ]


# Named so the orchestrator can `docker stop` it deterministically once
# both directions are harvested (compose run otherwise picks a random
# one-off name that is awkward to target).
ISAAC_CONTAINER_NAME = "xc-isaac-roundtrip"
# Deterministic sibling names so a crashed/cancelled run's orphans can be swept
# by the `xc-` prefix. `docker run --rm` does NOT fire when the client process
# is killed (teardown terminate()) but the detached container keeps running --
# the root cause of a 147-container ros:humble leak that polluted host-network
# DDS discovery and broke the cross-container round-trip (isaac#224).
CAMERA_SIBLING_NAME = "xc-camera-sibling"
CMDVEL_SIBLING_NAME = "xc-cmdvel-sibling"


def _compose_run_isaac_cmd() -> list[str]:
    """docker compose one-off (``--rm``) that boots the Isaac runner.

    Mounts this repo at the container work dir so the runner's
    --repo-root resolves the framework + example self-sufficiently
    (nested-worktree-robust), and overlays the fastdds profile.
    """
    work = CONTAINER_WORK
    runner = f"{work}/test/integration/pytest/_cross_container_runner.py"
    return [
        "docker", "compose",
        "-p", COMPOSE_PROJECT,
        "--env-file", str(REPO_ROOT / ".env.generated"),
        "--env-file", str(REPO_ROOT / ".env"),
        "run", "--rm", "--name", ISAAC_CONTAINER_NAME,
        "-v", f"{REPO_ROOT}:{work}",
        "test",
        PYTHON_SH, runner, "--repo-root", work,
    ]


def _ament_node_script(node: str = "", custom_run: str = "") -> str:
    """Build the ament ws in a container-local tree and ``ros2 run`` a node.

    The repo's ``example/ros2/`` is mounted READ-ONLY at ``/src``; colcon
    is run against a ``/tmp/ws`` copy so no root-owned ``build/`` /
    ``install/`` / ``log/`` artifacts land in the bind-mounted repo tree
    (the workspace-poison class the GPU CI fix guards against). ``node``
    runs ``ros2 run example_app_py <node>``; ``custom_run`` overrides the
    final command (e.g. a node with ``--ros-args`` parameters).
    """
    run_cmd = custom_run or f"ros2 run example_app_py {node}"
    return (
        "set -e; "
        "source /opt/ros/humble/setup.bash; "
        "cp -r /src /tmp/ws; cd /tmp/ws; "
        "colcon build --packages-select example_app_py "
        ">/tmp/build.log 2>&1; "
        "source install/setup.bash; "
        f"{run_cmd}"
    )


def _force_remove(name: str) -> None:
    """Best-effort ``docker rm -f`` a container by exact name (idempotent)."""
    try:
        subprocess.run(
            ["docker", "rm", "-f", name],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30,
        )
    except (subprocess.SubprocessError, OSError):
        pass


def _sweep_xc_siblings() -> None:
    """Force-remove every leftover ``xc-*`` container (siblings + Isaac runner).

    A crashed or CANCELLED run leaks them: teardown ``terminate()``s the
    docker-run CLIENT, but the detached container keeps running, so ``--rm``
    never fires. Sweeping by the deterministic ``xc-`` name prefix before AND
    after the run bounds the leak so stale DDS participants never accumulate to
    pollute host-network discovery (isaac#224 -- a 147-container leak broke it).
    """
    try:
        out = subprocess.run(
            ["docker", "ps", "-aq", "--filter", "name=xc-"],
            capture_output=True, text=True, timeout=30,
        )
        ids = out.stdout.split()
        if ids:
            subprocess.run(
                ["docker", "rm", "-f", *ids],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60,
            )
    except (subprocess.SubprocessError, OSError):
        pass


def _spawn_camera_subscriber():
    """Sibling ros:humble running the ament camera_subscriber node.

    Builds the ament workspace with colcon, then ``ros2 run`` the real
    ``example_app_py camera_subscriber`` node so the receipt is a genuine
    ament-node receipt (not a bare rclpy probe). Returns the Popen.
    """
    _force_remove(CAMERA_SIBLING_NAME)
    return subprocess.Popen(
        [
            "docker", "run", "--rm", "--net=host",
            "--name", CAMERA_SIBLING_NAME,
            *_ros_env_args(),
            "-v", f"{ROS2_WS}:/src:ro",
            "-v", f"{FASTDDS_PROFILE}:/cfg/fastdds.xml:ro",
            ROS_IMAGE, "bash", "-c",
            _ament_node_script("camera_subscriber"),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def _spawn_cmd_vel_publisher():
    """Sibling ros:humble running the ament cmd_vel_publisher node."""
    run_node = (
        "ros2 run example_app_py cmd_vel_publisher --ros-args "
        f"-p linear_x:={SENT_VX} -p angular_z:={SENT_WZ}"
    )
    _force_remove(CMDVEL_SIBLING_NAME)
    return subprocess.Popen(
        [
            "docker", "run", "--rm", "--net=host",
            "--name", CMDVEL_SIBLING_NAME,
            *_ros_env_args(),
            "-v", f"{ROS2_WS}:/src:ro",
            "-v", f"{FASTDDS_PROFILE}:/cfg/fastdds.xml:ro",
            ROS_IMAGE, "bash", "-c", _ament_node_script(custom_run=run_node),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def _stop_camera_proc(proc) -> None:
    """Stop a camera sibling whose stdout is owned by a drain thread.

    Uses ``terminate()`` + ``wait()`` rather than ``communicate()``: the
    drain thread already iterates ``proc.stdout``, so a second reader would
    double-read it. Stopping the container closes its stdout, which ends the
    drain thread's ``for ... in proc.stdout`` loop.
    """
    if proc is None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    except (subprocess.SubprocessError, OSError):
        pass


def _terminate(proc) -> str:
    """Stop a sibling Popen and return whatever stdout it produced."""
    if proc is None:
        return ""
    try:
        proc.terminate()
        out, _ = proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
    except (subprocess.SubprocessError, OSError):
        out = ""
    return out or ""


def _run_roundtrip_once() -> dict:
    """One full cross-container round-trip; return captured evidence.

    Boots the Isaac runner (streamed), waits for ``[XC READY]``, then
    starts both sibling nodes, harvests the sibling camera-subscriber
    output (sim->ament) and the Isaac ``[XC CMD_VEL RX]`` marker
    (ament->sim), and tears everything down.
    """
    # Remove any stale instance from a prior attempt before re-launching.
    try:
        subprocess.run(
            ["docker", "rm", "-f", ISAAC_CONTAINER_NAME],
            capture_output=True,
            timeout=60,
        )
    except (subprocess.SubprocessError, OSError):
        pass

    isaac = subprocess.Popen(
        _compose_run_isaac_cmd(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    isaac_lines: list[str] = []
    cam_proc = None
    pub_proc = None
    cam_out = ""
    # The camera sibling is drained by a background thread so its frames
    # can arrive concurrently with the Isaac side reaching its cmd_vel
    # marker -- the two directions resolve independently and we must wait
    # for BOTH before tearing down (cmd_vel arrives fast; the camera
    # subscriber still has to colcon-build + discover + receive a frame,
    # so breaking on cmd_vel alone races it out, isaac#132).
    cam_lines: list[str] = []
    cam_done = threading.Event()

    def _drain_camera(proc) -> None:
        try:
            for cam_line in proc.stdout:
                cam_lines.append(cam_line)
                if "[FRAME OK]" in cam_line:
                    cam_done.set()
        except (ValueError, OSError):
            pass

    ready = False
    cmd_vel_done = False
    deadline = time.time() + SUBPROC_TIMEOUT_SEC
    ready_deadline = time.time() + READY_WAIT_SEC

    try:
        for line in isaac.stdout:
            isaac_lines.append(line)
            sys.stderr.write(line)
            if not ready and "[XC READY]" in line:
                ready = True
                # The Isaac scene is live and publishing the camera /
                # subscribing /cmd_vel. Start the sibling ament nodes and
                # drain the camera subscriber in the background.
                cam_proc = _spawn_camera_subscriber()
                pub_proc = _spawn_cmd_vel_publisher()
                threading.Thread(
                    target=_drain_camera, args=(cam_proc,), daemon=True
                ).start()
            if "[XC CMD_VEL RX]" in line or "[XC CMD_VEL MISSING]" in line:
                cmd_vel_done = True
            # Break only once BOTH directions have resolved (or the
            # camera deadline lapses), so the camera sibling is not
            # terminated before it receives a frame.
            if cmd_vel_done and cam_done.is_set():
                break
            if not ready and time.time() > ready_deadline:
                break
            if time.time() > deadline:
                break
    finally:
        # Camera-direction resolution + bounded relaunch retry. cmd_vel
        # resolves fast; the camera sibling still has to colcon-build,
        # discover the Isaac participant across the host-network DDS
        # boundary, and receive a frame. Under GPU-host load that
        # occasionally races past one frame window (isaac#224), so on a miss
        # the stale sibling is torn down and a FRESH one relaunched against
        # the still-lingering Isaac publisher -- up to CAMERA_MAX_ATTEMPTS
        # total. A genuine no-frame-ever still fails (every attempt misses).
        if ready:
            attempt = 1
            # First attempt: the sibling spawned concurrently at [XC READY]
            # (warmed for free by overlapping its build/discovery with the
            # cmd_vel wait). Give it the frame window.
            if not cam_done.is_set():
                cam_done.wait(timeout=SIBLING_TIMEOUT_SEC)
            while not cam_done.is_set() and attempt < CAMERA_MAX_ATTEMPTS:
                attempt += 1
                sys.stderr.write(
                    "[cross-container] camera direction missed frame window "
                    f"on attempt {attempt - 1}/{CAMERA_MAX_ATTEMPTS}; "
                    "relaunching a fresh camera sibling against the live "
                    f"Isaac publisher (attempt {attempt}/"
                    f"{CAMERA_MAX_ATTEMPTS})\n"
                )
                # Tear the stale sibling down so the relaunch discovers from
                # a clean participant, then start a fresh drain on the same
                # cam_lines / cam_done (the first one to deliver wins).
                _stop_camera_proc(cam_proc)
                cam_proc = _spawn_camera_subscriber()
                threading.Thread(
                    target=_drain_camera, args=(cam_proc,), daemon=True
                ).start()
                # DDS discovery warm-up before counting this attempt's frame
                # window, so the fastdds handshake settles first.
                time.sleep(DISCOVERY_WARMUP_SEC)
                cam_done.wait(timeout=SIBLING_TIMEOUT_SEC)
        # Stop the (final) camera sibling. The drain thread owns its stdout;
        # closing the container's stdout ends that thread.
        _stop_camera_proc(cam_proc)
        cam_out = "".join(cam_lines)
        _terminate(pub_proc)
        # Echo the ament camera-subscriber output so the sim->ament
        # receipt (the [FRAME OK] line that crossed the boundary) is
        # visible verbatim in the CI log, not only on assertion failure.
        for cam_line in cam_out.splitlines():
            if "[FRAME OK]" in cam_line or "subscribed to" in cam_line:
                sys.stderr.write("[camera-sibling] " + cam_line + "\n")
        # The Isaac runner lingers (keeps publishing the camera) until
        # signalled; stop it now that both directions are harvested.
        # `docker stop` sends SIGTERM to the container PID 1, which
        # reaches the driver's _on_signal -> _should_quit, ending the
        # linger loop for a clean shutdown.
        try:
            subprocess.run(
                ["docker", "stop", "-t", "30", ISAAC_CONTAINER_NAME],
                capture_output=True,
                timeout=60,
            )
        except (subprocess.SubprocessError, OSError):
            pass
        try:
            isaac.terminate()
        except (subprocess.SubprocessError, OSError):
            pass
        # Drain any remaining Isaac output, then stop it.
        try:
            rest, _ = isaac.communicate(timeout=60)
            if rest:
                isaac_lines.append(rest)
                sys.stderr.write(rest)
        except subprocess.TimeoutExpired:
            isaac.kill()
            rest, _ = isaac.communicate()
            if rest:
                isaac_lines.append(rest)

    return {
        "isaac": "".join(isaac_lines),
        "camera_sibling": cam_out,
        "ready": ready,
    }


@pytest.fixture(scope="module")
def roundtrip():
    """Run the cross-container round-trip once (retry <= 1, logged)."""
    # Clear any xc-* orphan a crashed/cancelled prior run leaked, so its stale
    # DDS participants do not pollute this run's host-network discovery (#224).
    _sweep_xc_siblings()
    result = None
    try:
        for attempt in range(MAX_RETRIES + 1):
            sys.stderr.write(
                f"\n[cross-container] attempt {attempt + 1}/{MAX_RETRIES + 1}\n"
            )
            result = _run_roundtrip_once()
            got_camera = "[FRAME OK]" in result["camera_sibling"]
            got_cmd_vel = "[XC CMD_VEL RX]" in result["isaac"]
            if got_camera and got_cmd_vel:
                sys.stderr.write(
                    f"[cross-container] attempt {attempt + 1} crossed both "
                    f"directions\n"
                )
                break
            sys.stderr.write(
                f"[cross-container] attempt {attempt + 1} incomplete "
                f"(camera={got_camera} cmd_vel={got_cmd_vel}); retrying if "
                f"budget remains\n"
            )
        yield result
    finally:
        # Never leak our named siblings, even on test failure/cancel.
        _sweep_xc_siblings()


@requires_xc
def test_sim_to_ament_camera_received(roundtrip):
    """sim -> ament: the ament node receives a real sim camera frame.

    Robust to a transient cross-container DDS discovery race (isaac#224):
    the round-trip relaunches the camera sibling against the live Isaac
    publisher (with a discovery warm-up) up to ``CAMERA_MAX_ATTEMPTS``
    times, under the fixture's ``MAX_RETRIES`` whole-run retry. The PASS
    criterion is unchanged -- a genuine no-frame-ever exhausts every
    attempt and still asserts-False here.
    """
    assert roundtrip is not None, "round-trip produced no result"
    assert roundtrip["ready"], (
        "Isaac runner never reached [XC READY]; scene did not come up.\n"
        + roundtrip["isaac"][-2000:]
    )
    cam = roundtrip["camera_sibling"]
    assert "[FRAME OK]" in cam, (
        "ament camera_subscriber received no frame across the container "
        "boundary.\n" + cam[-2000:]
    )
    m = re.search(r"\[FRAME OK\] #\d+ frame .* frame_id=(\S+)", cam)
    assert m, "ament [FRAME OK] line missing the frame_id field.\n" + cam[-2000:]
    assert m.group(1) == EXPECTED_CAMERA_FRAME_ID, (
        f"frame_id mismatch across containers: got {m.group(1)!r}, "
        f"expected {EXPECTED_CAMERA_FRAME_ID!r}"
    )
    assert EXPECTED_CAMERA_TOPIC in cam, (
        "ament node did not subscribe the expected sim camera topic"
    )


@requires_xc
def test_ament_to_sim_cmd_vel_received(roundtrip):
    """ament -> sim: the Isaac RosIo picks up the sibling's /cmd_vel."""
    assert roundtrip is not None, "round-trip produced no result"
    out = roundtrip["isaac"]
    assert "[RAISED]" not in out, (
        "Isaac runner raised inside the lifecycle.\n" + out[-2000:]
    )
    assert "[XC CMD_VEL MISSING]" not in out, (
        "Isaac RosIo never received the sibling container's /cmd_vel.\n"
        + out[-2000:]
    )
    m = re.search(
        r"\[XC CMD_VEL RX\] seq=(\d+) vx=(\S+) vy=(\S+) wz=(\S+)", out
    )
    assert m, "Isaac [XC CMD_VEL RX] marker missing.\n" + out[-2000:]
    assert int(m.group(1)) >= 1, "cmd_vel freshness counter did not advance."
    assert float(m.group(2)) == pytest.approx(SENT_VX, abs=1e-3), (
        f"vx mismatch: got {m.group(2)}, expected {SENT_VX}"
    )
    assert float(m.group(4)) == pytest.approx(SENT_WZ, abs=1e-3), (
        f"wz mismatch: got {m.group(4)}, expected {SENT_WZ}"
    )
