"""PyInstaller entry."""

import sys


def main() -> None:
    if sys.platform != "win32":
        print("This tool requires Windows.")
        sys.exit(1)
    from seedesktop_system_repair.gui import main as gui_main

    gui_main()


if __name__ == "__main__":
    main()
