"""Kit-side runner for the scaffold GPU smoke (isaac#134).

Not a pytest test (leading underscore so pytest skips collection). Boots
the SCAFFOLDED ``example_driver.py`` (the one ``new-workspace.sh`` emits
into ``<ws>/src/isaac/sim/``, with its path prologue rewritten for the
consumer layout) headless -- no livestream, bypassing IsaacSim#228 -- to
prove that right after scaffolding the example is runnable and the camera
topic appears (PRD A5 scaffold pre-fill, M1/M5 literal).

This is deliberately the SCAFFOLDED driver, not the base
``example/sim/example_driver.py``: it exercises the scaffold's path
rewrite (framework resolved at ``<ws>/src/docker/framework``, sim assets
relative to the driver's own dir) on a live Kit stage, which the hosted
structure-check (``test/unit/pytest/test_new_workspace_scaffold.py``)
cannot.

It subclasses the scaffolded ``ExampleDriver`` and overrides the subclass
hooks to probe the live camera publish in place, emitting canonical
marker lines so the pytest layer can assert without depending on the
process exit code (Kit's ``app.close`` calls ``_exit(0)``).

Marker lines (the pytest layer asserts on these)::

    [BOOT OK]                       SimulationApp + scene built, hooks reached
    [CAMERA GRAPH OK] graph=...     setup_camera built the OmniGraph chain
    [SCAFFOLD CAMERA OK] topic=... frame_id=... width=... height=... count=N
    [SCAFFOLD CAMERA MISSING] ...   budget exhausted without a frame
    [EXIT CLEAN]                    lifecycle completed without raising
    [RAISED] ...                    exception escaped the lifecycle

CLI::

    /isaac-sim/python.sh _scaffold_smoke_runner.py --driver <path-to-driver>
"""

import argparse
import importlib.util
import sys
from pathlib import Path

# Ticks of app.update() to wait for the first camera frame after the
# graph is built (covers first-run shader-compilation stalls).
_FRAME_BUDGET_TICKS = 1800


def _load_scaffolded_driver(driver_path: Path):
    """Import the scaffolded example_driver.py from its emitted location.

    The scaffolded driver inserts its own consumer framework path
    (``<ws>/src/docker/framework``) into ``sys.path`` at import time, so
    no extra wiring is needed here.
    """
    spec = importlib.util.spec_from_file_location(
        "scaffolded_example_driver", str(driver_path)
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--driver",
        required=True,
        help="path to the scaffolded src/isaac/sim/example_driver.py",
    )
    args = parser.parse_args()

    driver_path = Path(args.driver).resolve()
    if not driver_path.is_file():
        print(f"[RAISED] FileNotFoundError: {driver_path}", flush=True)
        return 1

    ed = _load_scaffolded_driver(driver_path)

    class ScaffoldSmokeDriver(ed.ExampleDriver):
        """Probe the live camera publish on the scaffolded driver."""

        def main(self) -> None:
            """Wait for >= 1 camera frame on the scaffolded camera topic."""
            from isaac_devkit import ros_io

            topic = getattr(self, "_camera_topic", None)
            if topic is None:
                print(
                    "[SCAFFOLD CAMERA MISSING] no camera topic configured",
                    flush=True,
                )
                return

            reader = ros_io.RosIo(
                attr_reader=ros_io._og_attr_reader,
                topic_paths={},
            )
            # The camera publishes via OmniGraph; observe the live topic
            # through a sibling rclpy node spun up just for the probe.
            import rclpy
            from sensor_msgs.msg import Image

            if not rclpy.ok():
                rclpy.init()
            node = rclpy.create_node("scaffold_smoke_probe")
            seen = {"count": 0, "frame_id": "", "w": 0, "h": 0}

            def _on_image(msg: Image) -> None:
                seen["count"] += 1
                seen["frame_id"] = msg.header.frame_id
                seen["w"] = msg.width
                seen["h"] = msg.height

            node.create_subscription(Image, topic, _on_image, 10)

            for _ in range(_FRAME_BUDGET_TICKS):
                self._app.update()
                rclpy.spin_once(node, timeout_sec=0.0)
                if seen["count"] >= 1:
                    break

            node.destroy_node()
            del reader

            if seen["count"] >= 1:
                print(
                    f"[SCAFFOLD CAMERA OK] topic={topic} "
                    f"frame_id={seen['frame_id']} width={seen['w']} "
                    f"height={seen['h']} count={seen['count']}",
                    flush=True,
                )
            else:
                print(
                    f"[SCAFFOLD CAMERA MISSING] topic={topic} "
                    f"budget={_FRAME_BUDGET_TICKS} ticks exhausted",
                    flush=True,
                )

    ScaffoldSmokeDriver().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
