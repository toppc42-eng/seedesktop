"""Shared GCS update manifest helpers for Windows ZIP and macOS DMG releases."""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

try:
    from google.cloud import storage
except ImportError as e:  # pragma: no cover
    raise RuntimeError(
        "Missing dependency 'google-cloud-storage'. Run: pip install google-cloud-storage"
    ) from e

import SeeDesktop_Uploader as cfg


def read_version(version_rs: Path) -> str:
    content = version_rs.read_text(encoding="utf-8")
    match = re.search(r'pub const VERSION: &str = "([^"]+)"', content)
    if not match:
        raise RuntimeError("Could not read version from src/version.rs")
    return match.group(1)


def mac_dmg_filename(version: str) -> str:
    return f"SeeDesktop-{version}-macOS.dmg"


def fetch_existing_manifest(bucket: storage.Bucket) -> dict[str, Any]:
    blob = bucket.blob(f"{cfg.REMOTE_DIR}/version.json")
    if not blob.exists():
        return {}
    try:
        return json.loads(blob.download_as_text(encoding="utf-8"))
    except (json.JSONDecodeError, ValueError):
        return {}


def merge_manifest(
    *,
    version: str,
    release_notes: str,
    existing: dict[str, Any],
    windows_zip_uploaded: bool = False,
    mac_dmg_uploaded: bool = False,
) -> dict[str, Any]:
    merged: dict[str, Any] = dict(existing)
    merged["latest_version"] = version
    merged["release_notes"] = release_notes
    merged["release_date"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    if windows_zip_uploaded:
        merged["download_url"] = (
            f"{cfg.DOWNLOAD_BASE_URL}/{cfg.UPDATE_PACKAGE_NAME}"
        )
    elif "download_url" not in merged:
        merged["download_url"] = (
            f"{cfg.DOWNLOAD_BASE_URL}/{cfg.UPDATE_PACKAGE_NAME}"
        )

    if mac_dmg_uploaded:
        merged["mac_download_url"] = (
            f"{cfg.DOWNLOAD_BASE_URL}/{mac_dmg_filename(version)}"
        )
    elif "mac_download_url" not in merged and existing.get("mac_download_url"):
        merged["mac_download_url"] = existing["mac_download_url"]

    return merged


def upload_manifest(bucket: storage.Bucket, manifest: dict[str, Any]) -> None:
    version_blob = bucket.blob(f"{cfg.REMOTE_DIR}/version.json")
    version_blob.cache_control = "no-store, max-age=0"
    version_blob.upload_from_string(
        json.dumps(manifest, indent=4),
        content_type="application/json",
    )


def gcs_client():
    return storage.Client.from_service_account_json(cfg.GCS_CREDENTIALS_FILE)
