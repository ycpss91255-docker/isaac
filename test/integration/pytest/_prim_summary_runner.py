"""Kit-side PrimSummary dumper for the L1 URDF->USD diff test (isaac#132).

Not a pytest test (leading underscore so pytest skips collection). Opens
one or more committed/produced USD files with ``pxr.Usd`` inside a single
headless Kit boot and prints each file's ``PrimSummary`` (folded by the
pure ``isaac_devkit.model_import._summarize_prim_records``) as a parseable
marker line, so the test layer can assert the URDF->USD pipeline produces
the same structure as the committed example artifact (diff == 0).

Opening a USD with ``pxr`` needs the Isaac-Sim-bundled Python and a live
Kit (USD plugins), but does NOT need a second URDF import -- so several
already-produced USD files can be summarized in one process (unlike
``import_urdf``, which is one SimulationApp per call).

Marker line per ``--usd`` (in argument order)::

    [PRIM SUMMARY] tag=<tag> prim=<n> joint=<n> links=<n> root=<path>

CLI::

    /isaac-sim/python.sh _prim_summary_runner.py \\
        --framework <repo>/framework \\
        --usd committed=<path> --usd fresh=<path>
"""

import argparse
import sys


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--framework", required=True)
    parser.add_argument(
        "--usd", action="append", default=[],
        help="tag=<path> pairs; summarized in order",
    )
    args = parser.parse_args()

    sys.path.insert(0, args.framework)

    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})
    try:
        from pxr import Usd

        from isaac_devkit.model_import import _summarize_prim_records

        for spec in args.usd:
            tag, _, path = spec.partition("=")
            stage = Usd.Stage.Open(path)
            records = [
                (str(prim.GetPath()), str(prim.GetTypeName()))
                for prim in stage.Traverse()
            ]
            summary = _summarize_prim_records(records, path)
            print(
                f"[PRIM SUMMARY] tag={tag} prim={summary.prim_count} "
                f"joint={summary.joint_count} "
                f"links={len(summary.link_paths)} root={summary.root_prim}",
                flush=True,
            )
    finally:
        app.close()


if __name__ == "__main__":
    _main()
