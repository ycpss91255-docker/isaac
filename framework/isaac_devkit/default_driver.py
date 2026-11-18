"""Default driver for a scene launched without a user driver (isaac#336).

When a scene config names no ``IsaacDriver`` subclass, the launcher runs
``DefaultSceneDriver``: it builds the stage from the scene, plays the
timeline and ticks ``app.update()`` until quit. It adds no custom logic,
so ``setup`` / ``main`` / ``shutdown`` are the base-class defaults.

This module is import-safe without Isaac Sim: the Kit-side import lives
inside ``_new_stage``.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Optional

from isaac_devkit.driver import IsaacDriver
from isaac_devkit.scene import build_scene, load_scene


class DefaultSceneDriver(IsaacDriver):
    """Open the stage from a scene config, play, and tick."""

    def __init__(
        self, scene_path: Any, repo_root: Optional[Path] = None
    ) -> None:
        """Initializes the driver.

        Args:
            scene_path: Path of the scene config to launch.
            repo_root: Fallback model root passed to ``build_scene``;
                defaults to ``<repo>/src``, the same anchor as
                ``resolve_repo_relative_usd``.

        Raises:
            ValueError: ``scene_path`` is empty.
        """
        super().__init__()
        if not scene_path:
            raise ValueError("scene_path is required")
        self.scene_path = Path(scene_path)
        self.repo_root = (
            Path(repo_root)
            if repo_root is not None
            else Path(__file__).resolve().parents[2] / "src"
        )

    def _open_stage(self) -> Any:
        """Loads the scene, creates a fresh stage and spawns the scene."""
        scene = load_scene(self.scene_path, self.repo_root)
        stage = self._new_stage()
        build_scene(scene, stage, self.repo_root)
        return stage

    def _new_stage(self) -> Any:
        import omni.usd

        ctx = omni.usd.get_context()
        ctx.new_stage()
        return ctx.get_stage()
