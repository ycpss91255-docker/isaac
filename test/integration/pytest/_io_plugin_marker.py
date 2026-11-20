"""Fake ISAAC_IO_PLUGIN for the isaac#423 GPU test: defines a marker prim."""


def make_marker(stage, robot_prim, config):
    stage.DefinePrim(f"{robot_prim}/io_plugin_marker", "Xform")
