# Python as sole external interface; ROS 2 as replaceable downstream consumer

## Status

Accepted (2026-09-07).

Adds constraints on top of ADR-0017 (sections 3, 6, 8). Does **not** supersede
ADR-0017.

## Context

ADR-0017 defined the `isaac_devkit` module set (section 3) and its ROS 2
bidirectional bridge default (section 6), but left the dependency direction
between the Python framework and the ROS 2 wiring implicit. In practice,
`ros_io.py` (ROS 2 inbound Subscribe wiring) and the ROS 2 publish chain
inside `sensors.py` both live in `framework/isaac_devkit/` alongside
ROS-agnostic modules (`model_import`, `materials`, `scene`, `driver`).

During the 2026-09-06 architecture re-grill (#271), item-by-item verification
showed that every simulation capability (state, control, image, annotation,
sensors, sync stepping) is fully accessible through the Python API alone. The
ROS 2 bridge is implemented as OmniGraph ROS 2 nodes that internally call the
same Python API -- it adds no exclusive feature. Performance is identical: the
bottleneck is the GPU-to-CPU memory copy, not the language or middleware layer.

The question was whether the framework's external interface should be Python or
ROS 2. The evidence showed no technical basis for treating ROS 2 as the primary
interface.

## Decision

**Python is the sole external interface. ROS 2 is one of potentially several
downstream consumer layers and is replaceable.**

The framework is organized into two modules with a strict dependency direction:

| Module | Name | ROS dependency | Responsibility |
|---|---|---|---|
| Module 1 | `isaac_devkit` | **none** | Python API: model import, materials, scene, sensors (catalog/placement resolution), driver lifecycle |
| Module 2 | `isaac_ros2` (future) | depends on Module 1 | ROS 2 consumer layer: OmniGraph ROS 2 publish wiring, ROS 2 Subscribe inbound I/O, `rclpy` init helper |

**Dependency direction**: Module 2 imports Module 1. The reverse is prohibited
-- `isaac_devkit` must never import from `isaac_ros2`.

**Import-safety invariant extension**: ADR-0017 section 8 prohibits module-top
`import omni|isaacsim|pxr` in `isaac_devkit`. This ADR extends the prohibition
to ROS packages: module-top `import rclpy`, `import rosidl_*`, or any
`isaacsim.ros2.*` import is also prohibited in Module 1 source files.
Function-local `isaacsim.ros2.*` imports are acceptable only in files that
belong to Module 2.

**Relationship to ADR-0017**:

- ADR-0017 section 6 describes the technical *implementation* of the I/O bridge
  (OmniGraph ROS 2 nodes, not rclpy executors) and the example's default
  topology. That decision stands.
- This ADR constrains the *module dependency direction*: the files implementing
  that bridge must reside in Module 2, not Module 1.
- The two are at different levels of abstraction and are compatible. ADR-0017
  describes "how"; this ADR constrains "where."

**Impact on ADR-0017 section 3 (module set)**:

- `ros_io`: moves entirely to Module 2 (its sole purpose is ROS 2 inbound I/O).
- `sensors`: the catalog/placement resolution (pure) and Isaac-side sensor
  creation stay in Module 1; the OmniGraph -> ROS 2 publish wiring
  (`setup_camera`, `setup_lidar`, `setup_imu` and `_ensure_ros2_bridge_enabled`)
  moves to Module 2.
- `driver`: the `init_rclpy()` helper is a convenience that Module 2 provides.
  Module 1's driver lifecycle (`setup` / `main` / `shutdown` / `run`) remains
  ROS-agnostic.

## Consequences

- **`ros_io.py` currently lives in Module 1.** As of this writing,
  `framework/isaac_devkit/ros_io.py` is inside the `isaac_devkit` package. The
  physical file move and the creation of an `isaac_ros2` package are tracked as
  implementation work in a follow-up issue. This ADR records the decision; the
  PR carrying it does not move code.
- **`sensors.py` requires a split.** The ROS 2 publish wiring portion of
  `sensors.py` must be extracted to Module 2. The pure catalog/placement
  resolution and the Isaac-side sensor creation (which do not depend on
  `isaacsim.ros2.bridge`) remain in Module 1.
- **Testing simplification.** Module 1 can run its full test suite (hosted unit
  + import-safety) without any ROS 2 dependency, making CI faster and the
  framework easier to validate in isolation.
- **Middleware replaceability.** Switching from ROS 2 to gRPC, ZeroMQ, or
  direct DDS requires changing only Module 2; Module 1 is untouched.
- **Import-safety enforcement scope widens.** The existing hosted import test
  (ADR-0017 section 8) must be extended to assert that importing any
  `isaac_devkit` module also leaves `rclpy` and `isaacsim.ros2` out of
  `sys.modules`.

## References

- #271 -- owner decision record (evidence, measurements, PRD impact).
- ADR-0017 sections 3, 6, 8 -- amended by annotations pointing here.
- ADR-0018 -- Isaac Lab spawn backend (sensors/ros_io unchanged by spawn
  re-base; this ADR's module split is orthogonal).
