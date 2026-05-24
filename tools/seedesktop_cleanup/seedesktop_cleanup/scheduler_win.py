"""Register / remove Windows Task Scheduler jobs for unattended cleanup."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

TASK_NAME = "SeeDesktopCleanupScheduled"


def _exe_path() -> str:
    """Path to this executable (frozen) or python -m launcher."""
    if getattr(sys, "frozen", False):
        return str(Path(sys.executable).resolve())
    return str(Path(sys.executable).resolve())


def _quote_tr(s: str) -> str:
    return '"' + s.replace('"', '\\"') + '"'


def install_schedule(sched: Dict[str, Any]) -> Tuple[bool, str]:
    """
    mode: daily | weekly | monthly
    hour, minute, weekday (0=Sun), monthday (1-31)
    """
    if not sched.get("enabled"):
        return remove_schedule()

    exe = _exe_path()
    tr = f'{_quote_tr(exe)} --auto-run'
    mode = sched.get("mode", "daily")
    h = int(sched.get("hour", 2))
    m = int(sched.get("minute", 0))
    st = f"{h:02d}:{m:02d}"

    # schtasks /Create /TN ... /TR ... /SC ... /F
    args = [
        "schtasks",
        "/Create",
        "/TN",
        TASK_NAME,
        "/TR",
        tr,
        "/F",
    ]

    if mode == "daily":
        args += ["/SC", "DAILY", "/ST", st]
    elif mode == "weekly":
        wd = int(sched.get("weekday", 0))  # 0=Sunday in schtasks /D SUN
        days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        d = days[wd % 7]
        args += ["/SC", "WEEKLY", "/D", d, "/ST", st]
    elif mode == "monthly":
        md = max(1, min(31, int(sched.get("monthday", 1))))
        args += ["/SC", "MONTHLY", "/D", str(md), "/ST", st]
    else:
        args += ["/SC", "DAILY", "/ST", st]

    try:
        r = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=60,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        if r.returncode != 0:
            return False, (r.stderr or r.stdout or "schtasks failed").strip()
        return True, "המשימה נרשמה במתזמן המשימות."
    except OSError as e:
        return False, str(e)


def remove_schedule() -> Tuple[bool, str]:
    try:
        r = subprocess.run(
            ["schtasks", "/Delete", "/TN", TASK_NAME, "/F"],
            capture_output=True,
            text=True,
            timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        if r.returncode != 0 and "cannot find" not in (r.stderr or "").lower():
            if "not found" not in (r.stderr or "").lower() and "לא נמצא" not in (
                r.stderr or ""
            ):
                pass
        return True, "המשימה הוסרה (אם הייתה קיימת)."
    except OSError as e:
        return False, str(e)


def query_task_exists() -> bool:
    try:
        r = subprocess.run(
            ["schtasks", "/Query", "/TN", TASK_NAME],
            capture_output=True,
            text=True,
            timeout=15,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        return r.returncode == 0
    except OSError:
        return False
