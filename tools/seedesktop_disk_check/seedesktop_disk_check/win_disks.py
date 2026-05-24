"""
Windows: enumerate fixed drives, health/SMART-like counters, run disk tests.
Uses PowerShell (Storage module) and chkdsk/fsutil where appropriate.
"""

from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


def _creation_flags() -> int:
    if sys.platform != "win32":
        return 0
    # DETACHED_PROCESS could hide console; CREATE_NO_WINDOW = 0x08000000
    return subprocess.CREATE_NO_WINDOW  # type: ignore[attr-defined]


def run_powershell_json(script: str) -> Any:
    """Run PowerShell, expect JSON on stdout."""
    proc = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_creation_flags(),
    )
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    if proc.returncode != 0 and not out:
        raise RuntimeError(err or f"PowerShell exit {proc.returncode}")
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"JSON parse error: {e}\n---\n{out}\n---\n{err}") from e


PS_ENUMERATE = r"""
$ErrorActionPreference = 'SilentlyContinue'
$rows = @()
foreach ($v in Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }) {
  $L = $v.DriveLetter
  $size = [int64]$v.Size
  $free = [int64]$v.SizeRemaining
  $part = Get-Partition -DriveLetter $L -ErrorAction SilentlyContinue | Select-Object -First 1
  $diskNum = $null
  $health = ''
  $op = ''
  $model = ''
  $media = ''
  $serial = ''
  $unique = ''
  $smartPreview = ''
  if ($part) {
    $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
    if ($disk) {
      $diskNum = [int]$disk.Number
      $health = [string]$disk.HealthStatus
      $op = [string]$disk.OperationalStatus
      $model = [string]$disk.FriendlyName
      $serial = [string]$disk.SerialNumber
      $unique = [string]$disk.UniqueId
      $pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $disk.UniqueId } | Select-Object -First 1
      if (-not $pd) {
        $pd = Get-PhysicalDisk | Where-Object { $_.FriendlyName -eq $disk.FriendlyName } | Select-Object -First 1
      }
      if ($pd) {
        $media = [string]$pd.MediaType
        $c = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction SilentlyContinue
        if ($c) {
          $smartPreview = @(
            "Temperature: $($c.Temperature)",
            "ReadErrorsTotal: $($c.ReadErrorsTotal)",
            "WriteErrorsTotal: $($c.WriteErrorsTotal)",
            "FlushLatencyMax: $($c.FlushLatencyMax)",
            "LoadUnloadCycleCount: $($c.LoadUnloadCycleCount)"
          ) -join "`n"
        } else {
          $smartPreview = '(Get-StorageReliabilityCounter not available for this disk type)'
        }
      }
    }
  }
  $rows += [PSCustomObject]@{
    Letter = [string]$L
    Label = [string]$v.FileSystemLabel
    FileSystem = [string]$v.FileSystem
    SizeBytes = $size
    FreeBytes = $free
    DiskNumber = $diskNum
    HealthStatus = $health
    OperationalStatus = $op
    Model = $model
    SerialNumber = $serial
    UniqueId = $unique
    MediaType = $media
    SmartPreview = $smartPreview
  }
}
$rows | ConvertTo-Json -Depth 6 -Compress
"""


@dataclass
class DriveInfo:
    letter: str
    label: str
    filesystem: str
    size_bytes: int
    free_bytes: int
    disk_number: int | None
    health_status: str
    operational_status: str
    model: str
    serial_number: str
    unique_id: str
    media_type: str
    smart_preview: str

    def display_name(self) -> str:
        return f"{self.letter}: ({self.label or 'ללא שם'})"


def enumerate_fixed_drives() -> list[DriveInfo]:
    raw = run_powershell_json(PS_ENUMERATE)
    if isinstance(raw, dict):
        raw = [raw]
    if not raw:
        return []
    out: list[DriveInfo] = []
    for row in raw:
        dn = row.get("DiskNumber")
        out.append(
            DriveInfo(
                letter=str(row.get("Letter", "")).strip(),
                label=str(row.get("Label", "") or ""),
                filesystem=str(row.get("FileSystem", "") or ""),
                size_bytes=int(row.get("SizeBytes") or 0),
                free_bytes=int(row.get("FreeBytes") or 0),
                disk_number=int(dn) if dn is not None else None,
                health_status=str(row.get("HealthStatus", "") or ""),
                operational_status=str(row.get("OperationalStatus", "") or ""),
                model=str(row.get("Model", "") or ""),
                serial_number=str(row.get("SerialNumber", "") or ""),
                unique_id=str(row.get("UniqueId", "") or ""),
                media_type=str(row.get("MediaType", "") or ""),
                smart_preview=str(row.get("SmartPreview", "") or ""),
            )
        )
    return out


def run_storage_reliability_full(letter: str) -> str:
    """Detailed reliability counters for the physical disk behind this letter."""
    drive = letter.rstrip(":").strip().upper()
    script = rf"""
$ErrorActionPreference = 'Stop'
$part = Get-Partition -DriveLetter '{drive}' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $part) {{ throw "No partition for drive {drive}" }}
$disk = Get-Disk -Number $part.DiskNumber
$pd = Get-PhysicalDisk | Where-Object {{ $_.DeviceId -eq $disk.UniqueId }} | Select-Object -First 1
if (-not $pd) {{ $pd = Get-PhysicalDisk | Where-Object {{ $_.FriendlyName -eq $disk.FriendlyName }} | Select-Object -First 1 }}
if (-not $pd) {{ throw "Physical disk not found" }}
$c = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction SilentlyContinue
if (-not $c) {{ "(No reliability counters for this disk type)" }}
else {{ ($c | Format-List | Out-String).Trim() }}
"""
    proc = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_creation_flags(),
    )
    combined = (proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")
    if proc.returncode != 0 and not (proc.stdout or "").strip():
        raise RuntimeError(combined.strip() or f"exit {proc.returncode}")
    return combined.strip()


def run_chkdsk_scan(letter: str) -> str:
    """Online NTFS scan (Windows 8+)."""
    dl = _normalize_letter(letter)
    # /scan = online scan on Win10+
    return _run_cmd_output(["cmd.exe", "/c", f"chkdsk {dl} /scan"])


def run_chkdsk_readonly_verify(letter: str) -> str:
    """Classic read-only chkdsk (may dismount briefly on some systems)."""
    dl = _normalize_letter(letter)
    return _run_cmd_output(["cmd.exe", "/c", f"chkdsk {dl}"])


def run_fsutil_volume_diskfree(letter: str) -> str:
    dl = _normalize_letter(letter)
    return _run_cmd_output(["cmd.exe", "/c", f"fsutil volume diskfree {dl}"])


def run_chkdsk_surface_r(letter: str) -> str:
    """
    CHKDSK /r — בדיקת מגזרים פגומים (מתאים בעיקר ל-HDD).
    ארוך מאוד; על כונן מערכת עשוי לדרוש אתחול / דחייה.
    """
    dl = _normalize_letter(letter)
    return _run_cmd_output(["cmd.exe", "/c", f"chkdsk {dl} /r"])


def run_optimize_volume_retrim(letter: str) -> str:
    """
    SSD: Optimize-Volume -ReTrim — מפעיל TRIM על הכרך.
    """
    d = letter.strip().upper().rstrip(":")
    if len(d) != 1:
        raise ValueError("Invalid drive letter")
    script = rf"""
$ErrorActionPreference = 'Stop'
$r = Optimize-Volume -DriveLetter '{d}' -ReTrim -ErrorAction Stop
$r | Format-List *
"""
    proc = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_creation_flags(),
    )
    combined = ((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")).strip()
    if proc.returncode != 0 and not combined:
        raise RuntimeError(f"PowerShell exit {proc.returncode}")
    if proc.returncode != 0:
        combined += f"\n--- exit code: {proc.returncode} ---"
    return combined or "(no output)"


def _normalize_letter(letter: str) -> str:
    s = letter.strip().upper().rstrip(":")
    if len(s) != 1:
        raise ValueError("Invalid drive letter")
    return s + ":"


def _run_cmd_output(args: list[str]) -> str:
    proc = subprocess.run(
        args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        shell=False,
        creationflags=_creation_flags(),
    )
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    body = out
    if err:
        body = (body + "\n--- stderr ---\n" + err).strip()
    if proc.returncode != 0:
        body += f"\n--- exit code: {proc.returncode} ---"
    return body or "(no output)"


@dataclass
class DiskTestDef:
    id: str
    title: str
    explain: str
    before_you_run: str
    runner: Any  # callable[[str], str]


def tests_for_drive(d: DriveInfo) -> list[DiskTestDef]:
    """Same tools for all fixed volumes; CHKDSK behaviour differs by FS — UI warns."""
    return all_test_definitions()


def all_test_definitions() -> list[DiskTestDef]:
    return [
        DiskTestDef(
            id="smart_rel",
            title="דוח אמינות אחסון (מונים פיזיים)",
            explain=(
                "מציג מוני אמינות מהדיסק הפיזי (דומה ל-SMART): טמפרטורה, "
                "ספירת שגיאות קריאה/כתיבה ועוד. קריאה בלבד — לא כותב לדיסק."
            ),
            before_you_run=(
                "הפעולה קוראת נתונים דרך Windows Storage API. "
                "בחלק מהכוננים (למשל מסוימים ב-RAID או וירטואליים) המונים עלולים להיות חלקיים או לא זמינים."
            ),
            runner=lambda letter: run_storage_reliability_full(letter),
        ),
        DiskTestDef(
            id="chkdsk_scan",
            title="CHKDSK — סריקת מערכת קבצים מקוונת (/scan)",
            explain=(
                "בודק את מערכת הקבצים על הכונן תוך כדי עבודה (ב-Windows 10/11). "
                "מחפש שגיאות לוגיות; לא מתקן אוטומטית."
            ),
            before_you_run=(
                "דורש הרשאות מתאימות; על כונן מערכת עשויה להופיע הודעה אם לא ניתן להריץ מקוון. "
                "אם תתבקש הרצה כמנהל — הפעל את הכלי מחדש כמנהל."
            ),
            runner=lambda letter: run_chkdsk_scan(letter),
        ),
        DiskTestDef(
            id="chkdsk_ro",
            title="CHKDSK — בדיקה בסיסית (קריאה בלבד)",
            explain=(
                "מריץ את פקודת chkdsk הקלאסית במצב קריאה: בודק את תקינות מטא-דאטה "
                "ומציג דוח. לא מתקן שגיאות."
            ),
            before_you_run=(
                "עלול לקחת זמן בכוננים גדולים. אם הכונן בשימוש, Windows עשוי לבקש ניתוק או דחייה."
            ),
            runner=lambda letter: run_chkdsk_readonly_verify(letter),
        ),
        DiskTestDef(
            id="fsutil_free",
            title="fsutil — נפח פנוי ומטא-דאטה",
            explain=(
                "מציג מידע מהיר על נפח פנוי ומבנה הכרך (fsutil volume diskfree). "
                "בדיקה קלה ללא שינוי נתונים."
            ),
            before_you_run="קריאה בלבד; מתאים כבדיקת זמינות מהירה.",
            runner=lambda letter: run_fsutil_volume_diskfree(letter),
        ),
        DiskTestDef(
            id="chkdsk_r",
            title="CHKDSK — בדיקת משטח / מגזרים פגומים (/r, HDD)",
            explain=(
                "בודק את כל שטח הכרך לאיתור מגזרים פגומים ומנסה לשחזר מידע קריא. "
                "מיועד בעיקר לדיסקים מסתובבים (HDD). על SSD הפעולה איטית מאוד ולא מומלצת "
                "(בלאי מיותר); השתמש רק אם אתה מודע לכך."
            ),
            before_you_run=(
                "עלול להימשך שעות. דורש הרשאות מנהל. על כונן המערכת Windows עשוי לתזמן "
                "את הבדיקה לאתחול הבא. אל תכבה את המחשב בזמן הרצה."
            ),
            runner=lambda letter: run_chkdsk_surface_r(letter),
        ),
        DiskTestDef(
            id="ssd_retrim",
            title="TRIM — Optimize-Volume -ReTrim (SSD)",
            explain=(
                "מפעיל פקודת TRIM על הכרך דרך Windows (Optimize-Volume -ReTrim), "
                "מסמן לכונן SSD בלוקים לא בשימוש אחרי מחיקות. מומלץ ל-SSD/NVMe. "
                "על HDD הפקודה לרוב אינה רלוונטית או ללא השפעה משמעותית."
            ),
            before_you_run=(
                "דורש הרשאות מנהל. אל תפעיל במקביל להעברות קבצים כבדות אם המערכת עמוסה."
            ),
            runner=lambda letter: run_optimize_volume_retrim(letter),
        ),
    ]
