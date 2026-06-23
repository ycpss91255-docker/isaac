# URDF -> USD Ingestion Fidelity and Pipeline Policy

ADR-0018 decision 6 re-based `model_import` onto Isaac Lab `UrdfConverterCfg`. That settled the
*engine*; it did not settle the *ingestion policy* for a real, CAD-originated robot. The base
repo's `v1.0.0` promise is that a user can take their own robot through the full
**SolidWorks -> URDF -> USD** pipeline and drive the `new-workspace` template, so the
conversion-fidelity gaps that bite a real robot must be pinned down as decisions rather than
re-discovered per robot.

This ADR records what survives, what is lost, and what must be configured (not inferred) when a
CAD-exported URDF is ingested, for the reference exporter
`ycpss91255-research/solidworks_urdf_exporter` and the pinned importer stack
(Isaac Sim 5.1.0 + Isaac Lab `v2.3.0` -> bundled URDF importer `2.4.30`). It amends ADR-0018
decision 6. The running example stays the camera-bot; this ADR is the contract a real forklift
ingestion is checked against.

## Context

URDF is a *robot* description (XML, kinematic tree). USD is a *scene* superset. The conversion is
mostly faithful for geometry + basic physics (links, joints, inertia, collision); the gaps are
in the ROS / control / Gazebo periphery (no USD equivalent) and in a handful of importer choices
that default to something a CAD robot does not want. Investigated against the pinned stack and
the reference exporter; sources cited inline.

## Decision

### 1. Mesh meshes are DAE, not STL (color preservation)

The reference SW exporter emits **3DXML** and provides a convert step to **DAE (COLLADA)** that
carries the SolidWorks appearance color (its stated purpose: colored meshes in RViz). DAE color
flows through: `SW -> 3DXML -> DAE` (color in mesh) `-> URDF references DAE -> Isaac URDF
importer reads the DAE material -> USD prim gets a colored material`. **STL carries no color.**

- The URDF cleanup/preprocess step resolves `package://` paths but **keeps DAE references**; it
  does not down-convert to STL.
- If a model ships STL only, color is not a conversion loss to chase -- it is re-applied on the
  USD side (the `materials` spawn-cfg color path, ADR-0018 decision 7).

### 2. Collision approximation is a choice; the default convex hull is wrong for concave parts

`UrdfConverterCfg.collider_type` defaults to **`"convex_hull"`** -- the whole part's convex hull,
which fills in every concavity. The only other built-in is `"convex_decomposition"` (multiple
convex pieces). Neither is a full-resolution triangle-mesh collider. For a concave part (e.g. a
forklift's forks) the convex hull is a wrong collider (the gap between the forks is filled
solid).

- The ingestion config exposes `collider_type` to the consumer; concave parts use
  `convex_decomposition` or a hand-authored simplified collision mesh.
- "Import the mesh and you get full-resolution collision" is **false**; treat collision geometry
  as an explicit decision per part.

### 3. Joint drive (Kp/Kd/target) is configured in code, not carried by URDF

URDF carries joint type / axis / origin / limit (lower/upper/effort/velocity) / dynamics
(damping/friction) -- the kinematics and limits transfer and are sufficient. URDF has **no
position-control stiffness (Kp) field** -- that is a controller concept. Drives are set in code,
not inferred from URDF, and **not** via OmniGraph/action-graph and **not** GUI-only (confirmed on
both Isaac Sim 5.1 and 6.0):

- USD schema: `UsdPhysics.DriveAPI.Apply(joint, "angular"|"linear")` +
  `CreateStiffnessAttr` / `CreateDampingAttr` / `CreateTargetPositionAttr|TargetVelocity`.
- Isaac Lab: `isaaclab.actuators` (e.g. `ImplicitActuatorCfg`, grouped config) or
  `isaaclab.sim.schemas.modify_joint_drive_properties()`.
- At import: `UrdfConverterCfg.joint_drive = JointDriveCfg(target_type, gains=PDGainsCfg(...) |
  NaturalFrequencyGainsCfg(...))`.

There is no "plugin tag inside the URDF" equivalent to Gazebo plugins; robot control logic lives
in Python (the `IsaacDriver` / a standalone app / an extension), keeping model and control
decoupled.

### 4. Importer `merge_fixed_joints` behavior is version-sensitive; mount sensors on a surviving link + offset

`UrdfConverterCfg.merge_fixed_joints` defaults to `True` (it would consolidate fixed-jointed
links). **But the URDF importer bundled in Isaac Sim 5.1.0 (`2.4.30`, the one the pinned Isaac
Lab `v2.3.0` actually drives) removed merge-joints support** (IsaacLab PR #4000:
"Latest URDF importer in Isaac Sim 5.1 removed the support for merge-joints"; issue #3943), so on
the current pin **nothing is merged and every fixed-joint frame survives** (the committed
`camera_bot.usd` keeps `base_link` + `camera_link` + `camera_mount`). A merge-capable importer
(`2.4.31`+) would merge by default, and even then inertia-bearing fixed links are not merged.

- Do not rely on a massless fixed-joint frame surviving a future importer bump. The robust
  pattern (already used by the example): declare sensor placements on a **surviving link
  (`base_link`) + an `xyz`/`rpy` offset** in the scene YAML, not on a fixed-joint frame.

### 5. Inertia is the CAD's responsibility, not a conversion loss

A full 3x3 inertia tensor from CAD transfers faithfully (diagonalized to
`physics:diagonalInertia` + `physics:principalAxes`). Missing/garbage inertia is a CAD-export
quality problem, not a URDF->USD gap; `UrdfConverterCfg.link_density` (default `0.0`) is only a
stop-gap for missing inertials. Garbage in CAD -> garbage downstream is expected and out of scope
for the conversion.

### 6. The cleanup/preprocess step owns xacro, `package://`, and units

The URDF preprocess (extending `model_import._preprocess_urdf`, which today only resolves
`package://`) owns the deterministic, scriptable cleanup of a CAD-exported URDF:

- **xacro**: expand any `.xacro` to plain URDF before import (the importer does not read xacro).
- **`package://`**: resolve to absolute/relative paths while **keeping DAE** (decision 1).
- **units**: assert/normalize to meters (REP-103). The SW exporter emits meters; a check is
  cheap and prevents silent mm/scale surprises.

### 7. Joint types from the SW exporter: no floating/planar

The SW exporter derives joints from SolidWorks mates and only emits
`fixed` / `revolute` / `prismatic` / `continuous`, all of which convert cleanly. It does not emit
`floating` / `planar` (the awkward types). A free-floating base is the `fix_base=False` import
option, not a URDF joint. No script handling is required for floating/planar in this pipeline.

## Consequences

- `model_import` / the scene adapter expose `collider_type` and `joint_drive` (decisions 2, 3) and
  the preprocess gains xacro + units handling (decision 6); these land as the pre-`v1.0.0`
  ingestion issues (milestone "Ingestion - SW->URDF->USD pipeline + template").
- The `v1.0.0` acceptance (`doc/v1.0.0-rc1-acceptance.md`) gains an ingestion-pipeline section
  checked against this ADR: a representative non-camera-bot robot goes SW -> URDF -> USD -> YAML
  -> run through the template with color, a correct concave collider, and a driven joint.
- Decisions 4, 5, 7 are recorded as policy, not work: they need no code change on the current
  pin (merge off, inertia upstream, no floating/planar from the exporter), only awareness.
- Supersedes nothing; amends ADR-0018 decision 6 with the ingestion-fidelity detail it deferred.
