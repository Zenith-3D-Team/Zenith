"""Modular live-server checks for tools/live_check.py."""
from __future__ import annotations

import pathlib
import sys

_TOOLS = str(pathlib.Path(__file__).resolve().parents[1])
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)

