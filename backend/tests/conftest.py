"""Make `agent` importable when pytest runs from backend/ (same layout main.py uses)."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
