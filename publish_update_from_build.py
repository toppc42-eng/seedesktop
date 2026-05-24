"""Upload Windows SeeDesktopinst.zip to GCS and update version.json."""

import json
import sys
from pathlib import Path

import seedesktop_release_manifest as manifest


def main() -> None:
    repo = Path(__file__).resolve().parent
    local_zip = repo / "SeeDesktopinst.zip"
    if not local_zip.exists():
        raise RuntimeError(f"Missing zip file: {local_zip}")

    version = manifest.read_version(repo / "src" / "version.rs")
    release_notes = f"Build {version} published automatically."

    client = manifest.gcs_client()
    bucket = client.bucket(manifest.cfg.GCS_BUCKET_NAME)
    existing = manifest.fetch_existing_manifest(bucket)

    zip_blob = bucket.blob(f"{manifest.cfg.REMOTE_DIR}/{manifest.cfg.UPDATE_PACKAGE_NAME}")
    zip_blob.upload_from_filename(str(local_zip), content_type="application/zip")

    merged = manifest.merge_manifest(
        version=version,
        release_notes=release_notes,
        existing=existing,
        windows_zip_uploaded=True,
    )
    manifest.upload_manifest(bucket, merged)

    print(f"UPLOAD_OK version={version} remote_file={manifest.cfg.UPDATE_PACKAGE_NAME}")
    print(json.dumps(merged, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
