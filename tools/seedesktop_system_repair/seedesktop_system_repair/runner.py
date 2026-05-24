"""
Run sfc /scannow and optionally DISM restorehealth; detect SFC failure heuristically.
"""

from __future__ import annotations

import subprocess
import sys
from collections.abc import Callable


def is_windows_admin() -> bool:
    if sys.platform != "win32":
        return False
    try:
        import ctypes

        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def _creation_flags() -> int:
    if sys.platform != "win32":
        return 0
    return subprocess.CREATE_NO_WINDOW  # type: ignore[attr-defined]


LogFn = Callable[[str], None]


def _sys_exe(name: str) -> str:
    import os

    w = os.environ.get("WINDIR", r"C:\Windows")
    return os.path.join(w, "System32", name)


def run_process_logged(
    args: list[str],
    log: LogFn,
    *,
    shell: bool = False,
    hide_window: bool = True,
) -> int:
    """Run a process; stream combined stdout/stderr to log line by line."""
    log(f"$ {' '.join(args)}\n")
    cflags = _creation_flags() if hide_window else 0
    proc = subprocess.Popen(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
        shell=shell,
        creationflags=cflags,
        bufsize=1,
    )
    assert proc.stdout is not None
    for line in iter(proc.stdout.readline, ""):
        log(line)
    proc.wait()
    log(f"\n--- exit code: {proc.returncode} ---\n")
    return proc.returncode


def run_sfc_scannow(log: LogFn) -> int:
    return run_process_logged(
        [_sys_exe("sfc.exe"), "/scannow"],
        log,
        shell=False,
    )


def run_dism_restorehealth(log: LogFn) -> int:
    return run_process_logged(
        [
            _sys_exe("dism.exe"),
            "/Online",
            "/Cleanup-Image",
            "/RestoreHealth",
            "/NoRestart",
        ],
        log,
        shell=False,
    )


def sfc_suggests_run_dism(log_text: str, returncode: int) -> bool:
    """
    Run DISM if SFC failed (non-zero) or log contains known failure cues.
    If exit code is 0 and no failure cues, skip DISM.
    """
    if returncode != 0:
        return True
    low = log_text.lower()
    # Typical failure / partial-repair cues (EN; localized OS may miss these)
    needles = (
        "unable to fix",
        "could not fix",
        "could not repair",
        "could not perform the requested operation",
        "windows resource protection could not",
        "some files could not be repaired",
    )
    if any(n in low for n in needles):
        return True
    # Hebrew messages sometimes seen in CBS
    if "לא ניתן לתקן" in log_text or "לא ניתן להשלים" in log_text:
        return True
    return False


def build_report_header() -> str:
    from datetime import datetime

    return (
        f"SeeDesktop System Repair report\n"
        f"Time (local): {datetime.now().isoformat(timespec='seconds')}\n"
        f"{'=' * 60}\n\n"
    )
