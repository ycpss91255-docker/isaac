# Physics-Level Realization on Articulation Models (L2 / L2.5 / L3)

> Status: Accepted (2026-06-25). Extends [ADR-0008](./0008-l2-l3-physics-level-vocabulary-and-coexistence-rules.md)
> (L2/L3 vocabulary + PhysX kinematic/dynamic coexistence). ADR-0008's vocabulary and
> coexistence rules remain in force; this ADR resolves how those levels are actually
> realized once the model is the reduced-coordinate **articulation** that the real
> SolidWorks -> URDF -> Isaac Lab `UrdfConverter` pipeline produces.

## Context

ADR-0008 named L2 (kinematic) and L3 (dynamic + joint) using `forklift_blocky` as the
running example -- a hand-authored asset of **standalone kinematic rigid bodies** (no
articulation). That asset was an agent-built test fixture and is **not** a reference for
the v1.0.0 direction.

The real ingestion pipeline (SolidWorks URDF exporter -> URDF -> `UrdfConverter`) produces
a **reduced-coordinate articulation** (one mathematical multibody, joints as reduced
coordinates). `omwr` -- the actual exporter output in this repo -- is an articulation
(its USD carries `ArticulationRootAPI` + `RevoluteJoint` + `DriveAPI`). So the v1.0.0
question is not "how do we name physics levels" but "how are L2 / L3 realized on an
articulation, given the user wants L2 and L3 usable within the same model".

A hard PhysX constraint forces the discussion. PhysX 5.4 (Articulations):

- "links cannot be kinematic."
- "it is not possible to set a link's global pose or velocity directly."
- "The pose of a link is determined recursively through the pose of its parent link and
  the position of the joint connecting it to the parent."

So **true kinematic (true-L2) cannot exist on an articulation link** -- not via any flag,
not via a dummy link. Yet the same doc shows the articulation drive is stable at high
gain: drives are implicit and "can handle very large gains without necessarily causing
joint state instability or oscillations." That stability is what makes a third,
intermediate level meaningful.

## Decision

### D1 -- Three levels: L2 / L2.5 / L3

| Level | What it is | Where it can run | Under load |
|---|---|---|---|
| **L2** | true kinematic; command = position, hard guarantee | **standalone rigid body only** (articulation links cannot be kinematic) | zero error, unaffected |
| **L2.5** | articulation joint, high-stiffness position drive | **articulation (the pipeline's native model)** | small droop ~ load / stiffness; NOT a hard guarantee |
| **L3** | articulation joint, compliant / force drive | articulation | realistic droop, feels the load |

L2.5 is a new name (this ADR) for "high-stiffness position drive on an articulation joint".
It is the practical precise mode inside an articulation. It is legitimate, not a hack:
the reduced-coordinate implicit solver is stable at very high gains (unlike the
maximal-coordinate dynamic+velocity-override workaround ADR-0008 warned against, which only
applied to the standalone world). Naming it 2.5 (not 2) is deliberate: under continuous
load it has a predictable steady-state droop `~= load_force / stiffness`, so it is an
approximation of "command = position", not the PhysX hard guarantee.

### D1a -- the levels are one continuum tuned by the drive gain, not three materials

The `stiffness` (and `damping`) that separates L2.5 from L3 is a **controller
parameter** -- the joint drive's PD gain (how hard the position controller pushes toward
the target) -- NOT a material/rigidity property of the link. The link is a perfectly rigid
body whose mass/inertia come from the CAD/URDF export and are never touched by this choice.
URDF carries no drive-gain field (ADR-0020), so the gain is **set by the user** (in the
per-robot `physics.yaml`, D3), not exported by the model. The three levels are therefore one
continuum selected by that gain plus the joint's effort/velocity limits:

```
  L3  ───────────────  L2.5  ───────────────  L2 (true)
real actuator        finite stiff drive       perfect / infinite-force
(gains+effort+vel    (high k approximating     ideal (kinematic, k -> inf)
 from the spec)       the ideal)
error = realistic    error = load/stiffness    error = 0 (command=position)
```

- **L3** = fill the drive gains AND the effort/velocity limits from the **real actuator
  spec**, so the sim reproduces the real motor (its sag under load, its response time, its
  force/torque saturation). The effort limit matters as much as the stiffness -- the real
  "can't lift it / stalls" behavior is the effort limit clamping.
- **True L2** = the **perfect, infinite-force** idealization: the kinematic body is placed at
  the commanded pose regardless of any load (PhysX "moves the actor to its target ...
  regardless of external forces, gravity, collision"). There is no "force" concept and zero
  error. This is the limit of the drive as `k -> infinity`.
- **L2.5** = a **finite** high-stiffness drive that **approximates** that ideal. As `k`
  rises it converges toward true-L2; at any finite `k` the steady-state error is
  `load/stiffness`, small but nonzero.

Raising `k` buys precision **without** buying instability (the implicit articulation drive
absorbs very high gain), but it couples to three things the user must keep in view: damping
must scale with it (critical `2*sqrt(k*m)`, else it oscillates); the joint **effort limit**
must be high enough or the drive saturates and never reaches the target (the A3 limitation);
and a higher-`k` part behaves more kinematic-like in contact -- it pushes/holds other bodies
harder and can squish dynamics (the B3 interaction). It does NOT destabilize the sim or force
a smaller timestep.

Empirically validated (EXP-184, recorded in `doc/experiments/exp-184-l3-drive-precision.md`,
the milestone "L3 control verification" sweep on an RTX 5090, 10 kg payload): the L2.5
steady-state error tracks `m*g/stiffness` as a conservative upper bound and shrinks
monotonically with stiffness -- 19.4 mm at k=5000, 0.79 mm at k=1e5, 18 um at k=1e6 -- with
drift 0 (perfectly settled, no instability) at every point, and at high gain it BEATS the
linear model (18 um measured vs 98 um predicted at 1e6). So Isaac's L2.5 precision is bounded
by the stiffness you choose, not by an intrinsic floor; sub-mm is easy and tens of microns is
reachable, all stable -- but only true-L2 (D2) gives the hard zero-error guarantee.

### D1b -- scope: L2/L2.5/L3 is a JOINT POSITION-control vocabulary only

L2 / L2.5 / L3 describe **position-controlled mechanisms** -- a joint (or kinematic body)
commanded to a *position*: a forklift mast, fork, or chassis told "go to this height / pose".
The vocabulary does NOT cover **force / thrust-driven free bodies**. The canonical
counter-example is a drone: a propeller does not position anything; it spins (a *velocity*),
generates aerodynamic *thrust* (a force), and a free-floating 6-DOF body lifts when total
thrust exceeds weight. Applying L2.5 (a stiff position drive) to a rotor is a category error.

Two facts bound this:

- **No rigid-body engine simulates aerodynamics inline.** PhysX (like MuJoCo / Bullet) does
  rigid-body dynamics + contacts + joints/drives; lift/thrust/drag are an applied-force model
  layered on top. This is separation of concerns, not an Isaac defect, and is orthogonal to
  the forklift (which needs no aero).
- **Thrust IS supported in Isaac -- via a different actuator, not this vocabulary.** A drone
  is modelled as a free dynamic body whose rotors are *thruster* actuators that apply forces
  at body points (rpm -> thrust = c*rpm^2), via either the community **Pegasus Simulator**
  (an Isaac Sim extension: it computes each propeller's forces/torques and drives the body,
  with PX4 / ROS2 integration) or **Isaac Lab's own `Multirotor` + `ThrusterCfg`**
  (`isaaclab_contrib`: thruster actuators + an allocation matrix mapping thruster forces to a
  6-DOF body wrench; `set_thrust_target`, rpm/RPS -> thrust). Same physics engine, a
  thruster actuator layer instead of a joint position drive.

So the boundary: position-controlled joints/bodies -> L2 / L2.5 / L3 (this ADR); thrust /
free-flight (drones, and any propulsive free body) -> a thruster-actuator model (Pegasus /
Isaac Lab Multirotor), out of scope here. Do not stretch the position-control levels onto a
propulsion problem.

### D2 -- true-L2 requires a standalone body outside the articulation

To get a true-L2 part in the same robot, that part must be a **standalone kinematic rigid
body sitting outside the articulation**, joined to the L3 articulation by a rigid-body
(maximal-coordinate) loop joint. PhysX allows rigid-body joints between articulation links
("it is possible to create loops in the articulation by adding rigid-body Joints between
articulation links"), so the hybrid topology is constructible. Two shapes:

- (a) **standalone kinematic base + mounted L3 articulation** (the mobile-manipulator
  pattern): the chassis is true-L2, the arm/fork articulation rides on it.
- (b) **a specific link pulled out of the articulation** as a standalone kinematic body
  with driver forward-kinematics; the rest stays an L3 articulation.

The connecting loop joint is **maximal-coordinate and known to be compliant ("weak")**, so
true-L2 exactness does **not** propagate rigidly across the seam. The articulation's own
joints remain L2.5 / L3 regardless. Whether the seam compliance is acceptable is an
empirical question (see Verification).

### D3 -- L2/L3 is declared in a per-robot sidecar `<robot>.physics.yaml`, baked into the USD at conversion

URDF has no physics-level field, so the converter cannot infer it. A per-robot sidecar
`<robot>.physics.yaml` (next to the URDF + meshes, ROS-package layout) declares the level
**per joint** and the drive gains **per joint**; base motion is a separate key. The
converter reads it and bakes the result into the USD. This is model-intrinsic data (a
forklift's chassis-L2 / fork-L3 split does not change per scene), distinct from the
scene-extrinsic `object.yaml` `mobility: dynamic|static` for passive objects (ADR-0017).

Level is on the **joint** in the articulation world (the drive mode), not on the link --
because in an articulation the controllable thing is the joint drive, and a link cannot be
kinematic anyway. (For the standalone-body case of D2, the level is a property of that
standalone body.)

### D4 -- Isaac Lab value is L3-side only; Action Graph is unrelated to drive

Isaac Lab helps L3: typed config (`JointDrivePropertiesCfg`, `UrdfConverterCfg.joint_drive`)
and actuator models. We use the **stage-only** `modify_joint_drive_properties` (no playing
`SimulationContext`), NOT `ImplicitActuatorCfg` (which needs a playing SimulationContext and
hits the #151 shutdown hang). For L2 Isaac Lab offers **nothing** (`RigidObject` has no
kinematic-target API), so true-L2 must use raw pxr/PhysX `set_kinematic_target`.

Joint drive is a USD physics schema (`UsdPhysics.DriveAPI`), settable in pure Python; it is
**not** an Action Graph / OmniGraph concern. Action Graph in this repo is only for the ROS 2
bridge I/O (camera publish, /cmd_vel subscribe), and even that is driven in code via
`og.Controller.edit`. No GUI node wiring is required for any physics level.

## Verification (gates v1.0.0)

Three milestones of experiments, each split into isolated (single-control) and interactive
(with other models) issues; see milestones "Physics: L3 control verification", "Physics: L2
true-kinematic + hybrid", "Physics: real-model end-to-end". Confirmed-by-doc vs
needs-experiment:

- **Confirmed (doc):** articulation links can never be true-L2; standalone kinematic body is
  true-L2 and coexists with an L3 articulation; rigid-body loop joints connect them but are
  compliant.
- **Needs experiment:** L3 control precision/accuracy + its limitations (gain `*pi/180`
  scaling, force/velocity clamp, joint limits, solver iterations); whether L2.5 droop is
  within the application tolerance (the key requirements question -- decides if the hybrid
  complexity is even needed); per-link L2 substitution generality (esp. internal links that
  split the tree); hybrid-seam compliance and cross-boundary force transfer; kinematic
  push/grasp/squish and teleport-vs-kinematic-target contact bypass.

## Consequences

- `forklift_blocky` (standalone test fixture) is explicitly NOT a v1.0.0 reference; mark it
  test-only or remove it so it does not imply the standalone path is the direction.
- The v1.0.0 gate grows: ingestion milestone + the three physics-verification milestones +
  the human dry-run.
- The `<robot>.physics.yaml` schema (per-joint level + gains, base-motion key) is specified
  by D3 and exercised end-to-end in the real-model milestone (needs the user's CAD model).

## References

- PhysX 5.4 Articulations (links cannot be kinematic / reduced coordinate / high-gain
  stability / loop joints): https://nvidia-omniverse.github.io/PhysX/physx/5.4.0/docs/Articulations.html
- Isaac Sim - Tuning Joint Drive Gains (position control = stiffness*dpos + damping*dvel;
  tuning procedure): https://docs.isaacsim.omniverse.nvidia.com/5.1.0/robot_setup_tutorials/joint_tuning.html
- IsaacLab #2886 (user report: arms sag under gravity unless stiffness ~25000; instability
  at very high stiffness; degrees/radians hypothesis): https://github.com/isaac-sim/IsaacLab/issues/2886
- PhysX #308 (maximal-coordinate chained fixed joint is "very weak"): https://github.com/NVIDIAGameWorks/PhysX/issues/308
- IsaacLab #2395 (arm mounted on mobile base via fixed joint; IK caveats): https://github.com/isaac-sim/IsaacLab/discussions/2395
- Pegasus Simulator (Isaac Sim multirotor framework: per-propeller forces/torques + PX4 / ROS2; the D1b out-of-scope thrust pattern): https://github.com/PegasusSimulator/PegasusSimulator -- paper https://arxiv.org/abs/2307.05263
- Isaac Lab `isaaclab_contrib.assets` Multirotor / ThrusterCfg (thruster actuators + allocation matrix -> 6-DOF body wrench; rpm/RPS -> thrust): https://isaac-sim.github.io/IsaacLab/main/source/api/lab_contrib/isaaclab_contrib.assets.html

## Cross-references

- **ADR-0008** -- L2/L3 vocabulary + PhysX kinematic/dynamic coexistence; this ADR extends it
  with L2.5 and the articulation-realization rules.
- **ADR-0017 / ADR-0018** -- isaac_devkit framework + Isaac Lab sim_utils spawn backend;
  `modify_joint_drive_properties` and the SimulationContext deferral (#151) are referenced in D4.
- **ADR-0020** -- URDF -> USD ingestion fidelity; `joint_drive` (#168) and `collider_type`
  (#167) are the drive/collision inputs the physics.yaml feeds.
- **#168** -- the `*pi/180` revolute gain scaling first hit here.
