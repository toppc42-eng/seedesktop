"""JSON config: enabled cleaners + schedule preferences."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict


def config_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    d = Path(base) / "SeeDesktopCleanup"
    d.mkdir(parents=True, exist_ok=True)
    return d


def config_path() -> Path:
    return config_dir() / "settings.json"


DEFAULT_CATEGORIES: Dict[str, bool] = {
    "temp_user": True,
    "temp_windows": True,
    "temp_inet": True,
    "thumbnails": True,
    "recycle_bin": False,
    "dns_cache": True,
    "wer_local": True,
    "delivery_opt": False,
    "chrome_cache": False,
    "edge_cache": False,
    "firefox_cache": False,
    "directx_shader": True,
    "windows_logs": False,
    "dism_winsxs": False,
    "store_cache": True,
    "windows_bt": False,
    "event_logs_wevt": False,
    "prefetch": False,
    "spotify_cache": False,
    "teams_cache": False,
    "onedrive_logs": False,
    "discord_cache": False,
    "privacy_chromium": False,
    "privacy_firefox": False,
    "browser_history_chromium": False,
}

DEFAULT_SCHEDULE: Dict[str, Any] = {
    "enabled": False,
    "mode": "daily",  # daily | weekly | monthly
    "hour": 2,
    "minute": 0,
    "weekday": 0,  # 0=Sunday for schtasks
    "monthday": 1,
}

# גיבוי טקסטואלי לפני ניקוי (manifest)
DEFAULT_OPTIONS: Dict[str, Any] = {
    "backup_manifest_before_run": False,
}


def load_config() -> Dict[str, Any]:
    p = config_path()
    if not p.is_file():
        return {
            "categories": dict(DEFAULT_CATEGORIES),
            "schedule": dict(DEFAULT_SCHEDULE),
            "options": dict(DEFAULT_OPTIONS),
        }
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {
            "categories": dict(DEFAULT_CATEGORIES),
            "schedule": dict(DEFAULT_SCHEDULE),
            "options": dict(DEFAULT_OPTIONS),
        }
    cats = {**DEFAULT_CATEGORIES, **data.get("categories", {})}
    sched = {**DEFAULT_SCHEDULE, **data.get("schedule", {})}
    opts = {**DEFAULT_OPTIONS, **data.get("options", {})}
    return {"categories": cats, "schedule": sched, "options": opts}


def save_config(data: Dict[str, Any]) -> None:
    p = config_path()
    p.write_text(
        json.dumps(data, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
