#!/usr/bin/env python3
"""List articulations and their DOFs in a USD file.

Run inside the Isaac Sim 5.1 container:

    /isaac-sim/python.sh inspect_usd.py /path/to/scene.usd

Prints one ``[ART]`` line per articulation root, followed by the DOF index and
name for each degree of freedom. If the USD has no articulation (pure visual
mesh), prints a single notice and exits 0.
"""

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("usd", help="Path to USD file (inside container).")
    args = parser.parse_args()

    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    import omni.timeline
    import omni.usd
    from omni.isaac.dynamic_control import _dynamic_control as dc_mod

    ctx = omni.usd.get_context()
    if not ctx.open_stage(args.usd):
        print(f"Failed to open stage: {args.usd}", file=sys.stderr)
        app.close()
        return 1

    omni.timeline.get_timeline_interface().play()
    app.update()
    app.update()

    dc = dc_mod.acquire_dynamic_control_interface()
    stage = ctx.get_stage()

    found = 0
    for prim in stage.Traverse():
        path = str(prim.GetPath())
        art = dc.get_articulation(path)
        if art == dc_mod.INVALID_HANDLE:
            continue
        found += 1
        n = dc.get_articulation_dof_count(art)
        print(f"[ART] {path}  DOFs={n}")
        for i in range(n):
            handle = dc.get_articulation_dof(art, i)
            if handle == dc_mod.INVALID_HANDLE:
                continue
            print(f"      DOF{i}: {dc.get_dof_name(handle)}")

    if found == 0:
        print(f"No articulations found in {args.usd}")

    app.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
