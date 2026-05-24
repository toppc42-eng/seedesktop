"""Persist UI preferences (font size)."""

from __future__ import annotations

import json
import os
from pathlib import Path

_DEFAULT_FONT_SIZE = 12
_MIN = 8
_MAX = 24


def config_path() -> Path:
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    d = Path(base) / "SeeDesktopDiskCheck"
    return d / "settings.json"


def load_font_size() -> int:
    try:
        p = config_path()
        if not p.is_file():
            return _DEFAULT_FONT_SIZE
        data = json.loads(p.read_text(encoding="utf-8"))
        v = int(data.get("font_size", _DEFAULT_FONT_SIZE))
        return max(_MIN, min(_MAX, v))
    except Exception:
        return _DEFAULT_FONT_SIZE


def save_font_size(size: int) -> None:
    v = max(_MIN, min(_MAX, int(size)))
    d = config_path().parent
    d.mkdir(parents=True, exist_ok=True)
    path = config_path()
    payload = {"font_size": v}
    if path.is_file():
        try:
            cur = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(cur, dict):
                cur["font_size"] = v
                payload = cur
        except Exception:
            pass
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
