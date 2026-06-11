"""isaac_devkit: mounted Isaac Sim robot-simulation framework.

Placeholder package surface for the ADR-0017 framework extraction
(isaac#130). The curated re-export surface (``load_scene`` /
``build_scene`` / ``setup_sensors`` / ``setup_ros2_io`` /
``import_urdf`` / ``PrimSummary`` / ``IsaacDriver`` / the exception
hierarchy) is filled in the integrate step once the six modules
(``model_import`` / ``materials`` / ``sensors`` / ``ros_io`` /
``scene`` / ``driver``) land.

Import-safety invariant (ADR-0017 section 8 / PRD A1): importing this
package, or any of its modules, on a host without Isaac Sim must leave
``sys.modules`` free of ``omni`` / ``pxr`` / ``isaacsim``. Every Isaac
import inside the package is function-local; ``pxr`` type annotations
use ``TYPE_CHECKING`` string annotations only.
"""

# Tracks the repo git tag (ADR-0017 section 3); pre-release placeholder
# until the first release (v1.0.0 at the MVP gate, PRD A6). Keep in
# sync with framework/pyproject.toml [project] version.
__version__ = "0.1.0"
