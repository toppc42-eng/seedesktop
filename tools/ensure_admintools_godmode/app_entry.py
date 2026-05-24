"""PyInstaller entry: create God Mode / All Tasks folder for Admin Cpanel."""

from __future__ import annotations

import sys
from pathlib import Path

GODMODE_PATH = Path(r"C:\admintools\admintools.{ED7BA470-8E54-465E-825C-99712043E01C}")


def main() -> int:
    if sys.platform != "win32":
        print("SeeDesktopEnsureGodmode: Windows only.", file=sys.stderr)
        return 1
    try:
        GODMODE_PATH.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        print(f"SeeDesktopEnsureGodmode: failed: {e}", file=sys.stderr)
        return 1
    print(f"SeeDesktopEnsureGodmode: OK {GODMODE_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
