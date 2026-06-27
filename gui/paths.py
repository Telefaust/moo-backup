"""Application paths for dev (venv) and PyInstaller frozen builds."""

from __future__ import annotations

import sys
from pathlib import Path


def is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


def app_root() -> Path:
    """Repository root (dev) or portable package root (exe directory)."""
    if is_frozen():
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def gui_dir() -> Path:
    return app_root() / "gui"


def bundle_dir() -> Path | None:
    """PyInstaller extraction dir (_internal); None in dev."""
    meipass = getattr(sys, "_MEIPASS", None)
    return Path(meipass) if meipass else None


def moodle_plugin_dir() -> Path:
    return app_root() / "moodle-plugin"
