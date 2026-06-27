#!/usr/bin/env python3
"""Moo-backup GUI entry point."""

import sys
from pathlib import Path

if not getattr(sys, "frozen", False):
    root = Path(__file__).resolve().parent.parent
    root_str = str(root)
    if root_str not in sys.path:
        sys.path.insert(0, root_str)

from gui.ui.app import run_app

if __name__ == "__main__":
    run_app()
