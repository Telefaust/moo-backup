#!/usr/bin/env python3
"""Build Moodle-compatible install ZIPs (forward slashes only)."""

from __future__ import annotations

import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"

PLUGINS = (
    {
        "name": "local_backupnotice",
        "src": ROOT / "local" / "backupnotice",
        "parent": ROOT / "local",
        "zip_prefix": "local_backupnotice_moodle40",
    },
    {
        "name": "quizaccess_backupnotice",
        "src": ROOT / "quizaccess" / "backupnotice",
        "parent": ROOT / "quizaccess",
        "zip_prefix": "quizaccess_backupnotice_moodle40",
    },
)


def read_version(src: Path) -> str:
    version_php = src / "version.php"
    text = version_php.read_text(encoding="utf-8")
    match = re.search(r"\$plugin->version\s*=\s*(\d+)", text)
    if not match:
        raise SystemExit(f"Cannot read $plugin->version from {version_php}")
    return match.group(1)


def build_plugin_zip(plugin: dict) -> Path:
    src: Path = plugin["src"]
    parent: Path = plugin["parent"]
    prefix: str = plugin["zip_prefix"]

    if not src.is_dir():
        raise SystemExit(f"Plugin source not found: {src}")

    version = read_version(src)
    zip_path = DIST / f"{prefix}-{version}.zip"

    DIST.mkdir(parents=True, exist_ok=True)
    for old in DIST.glob(f"{prefix}-*.zip"):
        old.unlink()

    with zipfile.ZipFile(
        zip_path,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as zf:
        for path in sorted(src.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(parent).as_posix()
            zf.write(path, rel)

    return zip_path


def main() -> int:
    created = []
    for plugin in PLUGINS:
        created.append(build_plugin_zip(plugin))
    for path in created:
        print(f"Created: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
