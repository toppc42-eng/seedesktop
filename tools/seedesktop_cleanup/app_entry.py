"""Entry point for PyInstaller (adds package path)."""

from __future__ import annotations

import sys
from pathlib import Path

_root = Path(__file__).resolve().parent
if str(_root) not in sys.path:
    sys.path.insert(0, str(_root))

from seedesktop_cleanup.__main__ import main  # noqa: E402

if __name__ == "__main__":
    main()
