"""Single output entry point, selected by ``ISAAC_OUTPUT_MODE`` (ADR-0025).

``setup_output`` resolves the mode and wires the matching path:

* ``python``: Isaac-side readers (:mod:`isaac_devkit.output_python`) feed
  an :class:`~isaac_devkit.output_hub.OutputHub`; consumers register
  callbacks and the caller invokes :meth:`Output.step` once per
  ``app.update()``.
* ``ros``: not available in this module yet (the native OmniGraph path
  and its placement are tracked in ADR-0025).

Import safety (ADR-0017 section 8 / ADR-0023): no Isaac or ROS import at
module top; the Isaac-side readers are imported inside :func:`setup_output`.
"""

from collections import namedtuple

from isaac_devkit.output_hub import OutputHub
from isaac_devkit.output_mode import resolve_output_mode

CameraOutput = namedtuple(
    "CameraOutput", "name prim width height depth", defaults=(False,)
)
JointOutput = namedtuple("JointOutput", "prim")
ImuOutput = namedtuple("ImuOutput", "name prim")


def make_python_sources(cameras, joint, imu):
    """Create the Isaac-side readers; return ``[(name, kind, reader)]``."""
    from isaac_devkit import output_python

    return output_python.make_sources(cameras, joint, imu)


class Output:
    """Handle returned by :func:`setup_output`."""

    def __init__(self, mode, hub, sources):
        self.mode = mode
        self._hub = hub
        self._sources = sources

    def register(self, callback, kinds=None):
        """Register a callback for *kinds* (default: all)."""
        self._hub.register(callback, kinds)

    def unregister(self, callback):
        """Remove a previously registered callback."""
        self._hub.unregister(callback)

    def step(self, stamp):
        """Deliver one tick; call once per ``app.update()``."""
        self._hub.emit(stamp, self._sources)


def setup_output(environ=None, *, cameras=(), joint=None, imu=None):
    """Wire the output path chosen by ``ISAAC_OUTPUT_MODE``.

    Args:
        environ: Mapping for the mode lookup (default ``os.environ``).
        cameras: Iterable of :class:`CameraOutput`.
        joint: Optional :class:`JointOutput` (articulation root prim).
        imu: Optional :class:`ImuOutput` (existing ``IsaacImuSensor`` prim).

    Raises:
        ValueError: ``ISAAC_OUTPUT_MODE`` holds an invalid value.
        NotImplementedError: mode ``ros`` (not wired in this module yet).
    """
    mode = resolve_output_mode(environ)
    if mode == "ros":
        raise NotImplementedError(
            "ISAAC_OUTPUT_MODE='ros' output is not wired yet (ADR-0025)"
        )
    sources = make_python_sources(tuple(cameras), joint, imu)
    return Output(mode, OutputHub(), sources)
