"""Entry point for PyInstaller."""

import sys


def main() -> None:
    if sys.platform != "win32":
        print("This tool is for Windows only.")
        sys.exit(1)
    from seedesktop_disk_check.gui import main as gui_main

    gui_main()


if __name__ == "__main__":
    main()
