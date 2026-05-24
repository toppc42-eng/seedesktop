from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path


def reports_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    d = Path(base) / "SeeDesktopSystemRepair" / "reports"
    d.mkdir(parents=True, exist_ok=True)
    return d


def new_report_path() -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return reports_dir() / f"sfc_dism_run_{stamp}.log"


def last_report_link() -> Path:
    return reports_dir().parent / "last_report.txt"
