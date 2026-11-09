"""Project version (single source of truth: VERSION file in the project root)."""

from __future__ import annotations

from gui.paths import app_root

UNKNOWN_VERSION = "unknown"


def get_version() -> str:
    try:
        text = (app_root() / "VERSION").read_text(encoding="utf-8").strip()
    except OSError:
        return UNKNOWN_VERSION
    return text or UNKNOWN_VERSION
