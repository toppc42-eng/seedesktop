"""Entry: GUI or --auto-run."""

from __future__ import annotations

import sys


def main() -> None:
    if "--auto-run" in sys.argv:
        from .runner import run_auto

        raise SystemExit(run_auto())
    from .gui import run_gui

    run_gui()


if __name__ == "__main__":
    main()
