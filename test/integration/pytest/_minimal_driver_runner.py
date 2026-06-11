"""Kit-side runner for the IsaacDriver integration smoke test.

Not a pytest test (leading underscore so pytest skips collection).
Defines a minimal ``IsaacDriver`` subclass, calls ``run()``, and prints
the canonical ``[OK]`` / ``[RAISED]`` markers so the test layer can
assert without depending on the process exit code (Kit's ``app.close``
calls ``_exit(0)`` on the way out and swallows ``sys.exit``).

CLI:

    /isaac-sim/python.sh _minimal_driver_runner.py \\
        --script-dir <repo>/framework \\
        --usd-path <absolute path to a tiny .usda fixture>
"""

import argparse
import sys


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--script-dir", required=True)
    parser.add_argument("--usd-path", required=True)
    args = parser.parse_args()

    sys.path.insert(0, args.script_dir)

    try:
        from isaac_devkit.driver import IsaacDriver  # noqa: E402

        usd_path = args.usd_path

        class _MinimalDriver(IsaacDriver):
            USD = usd_path

            def main(self) -> None:
                # Bail immediately so the test wall time is dominated by
                # Kit boot (~10 s) instead of an idle loop. The signal
                # handler path is unit-tested separately.
                print("[OK] minimal driver main reached", flush=True)
                self._should_quit = True

        _MinimalDriver().run()
    except Exception as exc:  # noqa: BLE001
        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        raise


if __name__ == "__main__":
    _main()
