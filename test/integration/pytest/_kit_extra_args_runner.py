"""Kit-side runner for the ISAAC_KIT_EXTRA_ARGS integration test (isaac#422).

Not a pytest test (leading underscore). Boots a minimal ``IsaacDriver``
and, from ``main()``, reads ``/app/isaac_test/marker`` back through carb
settings and prints ``[MARKER] <value>`` (``None`` when the setting is
absent).
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

        def main(self) -> None:
            import carb.settings

            value = carb.settings.get_settings().get("/app/isaac_test/marker")
            print(f"[MARKER] {value}", flush=True)
            self._should_quit = True

    _Driver().run()


if __name__ == "__main__":
    _main()
