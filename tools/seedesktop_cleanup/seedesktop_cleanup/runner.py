"""Headless run for Task Scheduler (--auto-run)."""

from __future__ import annotations

import traceback
from datetime import datetime

from .cleaners import export_predelete_manifest, format_bytes, run_selected
from .config_store import config_dir, load_config


def run_auto() -> int:
    cfg = load_config()
    cats = cfg.get("categories", {})
    log_path = config_dir() / "last_auto_run.log"
    lines = [f"=== SeeDesktop Cleanup — {datetime.now().isoformat()} ===\n"]
    total = 0
    try:
        if cfg.get("options", {}).get("backup_manifest_before_run"):
            mp = export_predelete_manifest(cats)
            if mp is not None:
                lines.append(f"manifest: {mp}\n")
        for key, freed, label in run_selected(cats):
            total += freed
            lines.append(f"[{label}] {format_bytes(freed)}\n")
        lines.append(f"סה\"כ משוחרר: {format_bytes(total)}\n")
        log_path.write_text("".join(lines), encoding="utf-8")
    except Exception:
        log_path.write_text(
            "".join(lines) + "\n" + traceback.format_exc(),
            encoding="utf-8",
        )
        return 1
    return 0
