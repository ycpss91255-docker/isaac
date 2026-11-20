"""Load the shared group guard (isaac#434): see test/group_markers.py."""

import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "group_markers", Path(__file__).resolve().parents[2] / "group_markers.py"
)
_markers = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_markers)

pytest_configure = _markers.pytest_configure
pytest_collection_modifyitems = _markers.pytest_collection_modifyitems
