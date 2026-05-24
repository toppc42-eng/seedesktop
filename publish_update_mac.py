"""Upload macOS DMG to GCS and merge mac_download_url into version.json."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import seedesktop_release_manifest as manifest


def main() -> None:
    parser = argparse.ArgumentParser(description="Publish SeeDesktop macOS DMG to GCS")
    parser.add_argument(
        "--dmg",
        type=Path,
        default=None,
        help="Path to SeeDesktop-{version}-macOS.dmg (default: repo root by version)",
    )
    parser.add_argument(
        "--notes",
        default="",
        help="Release notes (default: auto from version)",
    )
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent
    version = manifest.read_version(repo / "src" / "version.rs")
    dmg_path = args.dmg or (repo / manifest.mac_dmg_filename(version))
    if not dmg_path.is_file():
        raise RuntimeError(f"Missing DMG: {dmg_path}")

    notes = args.notes.strip() or f"SeeDesktop {version} for macOS."
    remote_name = manifest.mac_dmg_filename(version)

    client = manifest.gcs_client()
    bucket = client.bucket(manifest.cfg.GCS_BUCKET_NAME)
    existing = manifest.fetch_existing_manifest(bucket)

    blob = bucket.blob(f"{manifest.cfg.REMOTE_DIR}/{remote_name}")
    blob.upload_from_filename(str(dmg_path), content_type="application/octet-stream")

    merged = manifest.merge_manifest(
        version=version,
        release_notes=notes,
        existing=existing,
        mac_dmg_uploaded=True,
    )
    manifest.upload_manifest(bucket, merged)

    print(f"UPLOAD_OK version={version} mac_file={remote_name}")
    print(json.dumps(merged, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
