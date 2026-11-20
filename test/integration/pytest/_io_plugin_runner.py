"""Kit-side runner for the ISAAC_IO_PLUGIN integration test (isaac#423).

Not a pytest test (leading underscore). Boots a minimal ``IsaacDriver``
(no boot extensions) and, from ``main()``, prints ``[MARKER_PRIM] <bool>``
and ``[ROS_MODULES] <sorted list>`` (``rclpy`` / ``isaacsim.ros2*`` entries
of ``sys.modules``).
"""

import argparse
import sys


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--script-dir", required=True)
    parser.add_argument("--usd-path", required=True)
    args = parser.parse_args()

    sys.path.insert(0, args.script_dir)

    from isaac_devkit.driver import IsaacDriver  # noqa: E402

    usd_path = args.usd_path

    class _Driver(IsaacDriver):
        USD = usd_path
        BOOT_EXTENSIONS = ()

        def main(self) -> None:
            import omni.usd

            stage = omni.usd.get_context().get_stage()
            root = stage.GetDefaultPrim().GetPath()
            marker = stage.GetPrimAtPath(f"{root}/io_plugin_marker")
            print(f"[MARKER_PRIM] {bool(marker and marker.IsValid())}",
                  flush=True)
            ros = sorted(
                m for m in sys.modules
                if m == "rclpy" or m.startswith(("rclpy.", "isaacsim.ros2"))
            )
            print(f"[ROS_MODULES] {ros}", flush=True)
            self._should_quit = True

    _Driver().run()


if __name__ == "__main__":
    _main()
