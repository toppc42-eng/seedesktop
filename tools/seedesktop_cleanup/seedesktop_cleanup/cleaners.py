"""
Safe file-based cleaners for Windows. Returns (bytes_freed, human message).
Does not touch system-critical binaries.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

CleanerFn = Callable[[], Tuple[int, str]]

_WIN_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _run_no_window(
    args: List[str],
    *,
    timeout: int = 3600,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
        creationflags=_WIN_NO_WINDOW if os.name == "nt" else 0,
    )


def _dir_size(path: Path) -> int:
    n = 0
    if not path.exists():
        return 0
    try:
        for root, _dirs, files in os.walk(path):
            for f in files:
                fp = Path(root) / f
                try:
                    n += fp.stat().st_size
                except OSError:
                    pass
    except OSError:
        pass
    return n


def _delete_tree_contents(root: Path, max_files: int = 500_000) -> int:
    """Delete files under root (not root itself). Returns bytes freed."""
    freed = 0
    count = 0
    if not root.is_dir():
        return 0
    try:
        for child in list(root.iterdir()):
            if count >= max_files:
                break
            try:
                if child.is_file() or child.is_symlink():
                    sz = child.stat().st_size if child.is_file() else 0
                    child.unlink(missing_ok=True)
                    freed += sz
                    count += 1
                elif child.is_dir():
                    sz = _dir_size(child)
                    shutil.rmtree(child, ignore_errors=True)
                    freed += sz
                    count += max(1, sz // 4096)
            except OSError:
                pass
    except OSError:
        pass
    return freed


def _delete_files_in_dir(
    folder: Path,
    patterns: Tuple[str, ...] = ("*",),
    recursive: bool = False,
) -> int:
    freed = 0
    if not folder.is_dir():
        return 0
    try:
        if recursive:
            for p in folder.rglob("*"):
                if p.is_file():
                    try:
                        sz = p.stat().st_size
                        p.unlink(missing_ok=True)
                        freed += sz
                    except OSError:
                        pass
        else:
            for p in folder.iterdir():
                if p.is_file():
                    for pat in patterns:
                        if pat == "*" or p.match(pat):
                            try:
                                sz = p.stat().st_size
                                p.unlink(missing_ok=True)
                                freed += sz
                            except OSError:
                                pass
                            break
    except OSError:
        pass
    return freed


def clean_temp_user() -> Tuple[int, str]:
    freed = 0
    for env in ("TEMP", "TMP", "LOCALAPPDATA"):
        v = os.environ.get(env)
        if not v:
            continue
        base = Path(v)
        if env == "LOCALAPPDATA":
            base = base / "Temp"
        if base.is_dir():
            freed += _delete_tree_contents(base)
    return freed, "תיקיות Temp של המשתמש"


def clean_temp_windows() -> Tuple[int, str]:
    windir = os.environ.get("WINDIR", r"C:\Windows")
    t = Path(windir) / "Temp"
    if not t.is_dir():
        return 0, "Temp של Windows"
    freed = _delete_tree_contents(t)
    return freed, "Temp של Windows"


def clean_internet_temp() -> Tuple[int, str]:
    freed = 0
    la = os.environ.get("LOCALAPPDATA")
    if la:
        inet = Path(la) / "Microsoft" / "Windows" / "INetCache"
        if inet.is_dir():
            freed += _delete_tree_contents(inet)
    return freed, "מטמון אינטרנט (INetCache)"


def clean_thumbnails() -> Tuple[int, str]:
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "מטמון תמונות ממוזערות"
    thumb = Path(la) / "Microsoft" / "Windows" / "Explorer"
    freed = 0
    for name in ("thumbcache_*.db", "iconcache_*.db"):
        for p in thumb.glob(name):
            try:
                if p.is_file():
                    sz = p.stat().st_size
                    p.unlink(missing_ok=True)
                    freed += sz
            except OSError:
                pass
    return freed, "מטמון תמונות ממוזערות"


def clean_recycle_bin() -> Tuple[int, str]:
    try:
        import ctypes

        # SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND
        flags = 0x1 | 0x2 | 0x4
        hr = ctypes.windll.shell32.SHEmptyRecycleBinW(None, None, flags)
        if hr != 0:
            pass
    except Exception:
        pass
    return 0, "סל המחזור (ריקון)"


def clean_dns_cache() -> Tuple[int, str]:
    try:
        _run_no_window(["ipconfig", "/flushdns"], timeout=30)
    except (subprocess.TimeoutExpired, OSError):
        pass
    return 0, "מטמון DNS (ipconfig)"


def clean_wer_local() -> Tuple[int, str]:
    freed = 0
    pd = os.environ.get("PROGRAMDATA", r"C:\ProgramData")
    for sub in (
        Path(pd) / "Microsoft" / "Windows" / "WER" / "ReportQueue",
        Path(pd) / "Microsoft" / "Windows" / "WER" / "ReportArchive",
    ):
        if sub.is_dir():
            freed += _delete_tree_contents(sub)
    return freed, "דוחות שגיאות מקומיים (WER)"


def clean_delivery_opt() -> Tuple[int, str]:
    freed = 0
    windir = os.environ.get("WINDIR", r"C:\Windows")
    d = Path(windir) / "ServiceProfiles" / "NetworkService" / "AppData" / "Local" / "Microsoft" / "Windows" / "DeliveryOptimization" / "Cache"
    if d.is_dir():
        freed += _delete_tree_contents(d)
    return freed, "מטמון Delivery Optimization"


def _browser_cache_chrome() -> Tuple[int, str]:
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "מטמון Chrome"
    base = Path(la) / "Google" / "Chrome" / "User Data"
    freed = 0
    if base.is_dir():
        for prof in base.iterdir():
            if prof.is_dir() and (prof.name == "Default" or prof.name.startswith("Profile")):
                for sub in ("Cache", "Code Cache", "GPUCache"):
                    p = prof / sub
                    if p.is_dir():
                        freed += _delete_tree_contents(p)
    return freed, "מטמון Chrome"


def _browser_cache_edge() -> Tuple[int, str]:
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "מטמון Edge"
    base = Path(la) / "Microsoft" / "Edge" / "User Data"
    freed = 0
    if base.is_dir():
        for prof in base.iterdir():
            if prof.is_dir() and (prof.name == "Default" or prof.name.startswith("Profile")):
                for sub in ("Cache", "Code Cache", "GPUCache"):
                    p = prof / sub
                    if p.is_dir():
                        freed += _delete_tree_contents(p)
    return freed, "מטמון Edge"


def _browser_cache_firefox() -> Tuple[int, str]:
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "מטמון Firefox"
    moz = Path(la) / "Mozilla" / "Firefox" / "Profiles"
    freed = 0
    if moz.is_dir():
        for prof in moz.iterdir():
            if prof.is_dir():
                for sub in ("cache2", "startupCache"):
                    p = prof / sub
                    if p.is_dir():
                        freed += _delete_tree_contents(p)
    return freed, "מטמון Firefox"


def clean_directx_shader() -> Tuple[int, str]:
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "מטמון Shader DirectX"
    d = Path(la) / "D3DSCache"
    freed = _delete_tree_contents(d) if d.is_dir() else 0
    return freed, "מטמון Shader DirectX"


def clean_windows_logs() -> Tuple[int, str]:
    windir = os.environ.get("WINDIR", r"C:\Windows")
    logs = Path(windir) / "Logs"
    freed = _delete_files_in_dir(logs, recursive=True) if logs.is_dir() else 0
    return freed, "יומני Windows (תיקיית Logs)"


def clean_dism_component_store() -> Tuple[int, str]:
    """WinSxS / component store via DISM (often needs admin; may take long)."""
    windir = os.environ.get("WINDIR", r"C:\Windows")
    dism = Path(windir) / "System32" / "DISM.exe"
    if not dism.is_file():
        return 0, "DISM — לא נמצא"
    r = _run_no_window(
        [
            str(dism),
            "/Online",
            "/Cleanup-Image",
            "/StartComponentCleanup",
            "/NoRestart",
        ],
        timeout=7200,
    )
    msg = "ניקוי רכיבים (DISM /StartComponentCleanup)"
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "").strip()[-400:]
        extra = f" — קוד {r.returncode}"
        if tail:
            extra += f": {tail}"
        msg += extra + " (ייתכן שדרוש מנהל או עדכון פתוח)"
    return 0, msg


def clean_microsoft_store_cache() -> Tuple[int, str]:
    """UWP Packages: LocalState cache/temp — not entire LocalState."""
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "מטמון Microsoft Store (Packages)"
    pk = Path(la) / "Packages"
    freed = 0
    if not pk.is_dir():
        return 0, "מטמון Microsoft Store (Packages)"
    for pkg in pk.iterdir():
        if not pkg.is_dir():
            continue
        for rel in (
            ("LocalState", "cache"),
            ("LocalState", "temp"),
            ("LocalState", "AC", "INetCache"),
            ("TempState",),
        ):
            p = pkg.joinpath(*rel)
            if p.is_dir():
                freed += _delete_tree_contents(p)
    return freed, "מטמון Microsoft Store (תחת Packages)"


def clean_windows_bt() -> Tuple[int, str]:
    """
    HIGH RISK: Windows upgrade staging. Only enable if you understand
    no in-place upgrade is pending.
    """
    root = Path(os.environ.get("SystemDrive", "C:")) / "$Windows.~BT"
    if not root.is_dir():
        return 0, "$Windows.~BT (לא נמצא)"
    freed = _delete_tree_contents(root)
    return freed, "$Windows.~BT (שטח שדרוג — סיכון גבוה)"


def clean_event_logs_wevtutil() -> Tuple[int, str]:
    """Clear classic logs via wevtutil (typically needs admin)."""
    windir = os.environ.get("WINDIR", r"C:\Windows")
    w = Path(windir) / "System32" / "wevtutil.exe"
    if not w.is_file():
        return 0, "יומני אירועים (wevtutil)"
    names = ("Application", "System", "Setup")
    errors: List[str] = []
    for name in names:
        r = _run_no_window([str(w), "cl", name], timeout=120)
        if r.returncode != 0:
            errors.append(name)
    msg = "יומני אירועים (wevtutil cl)"
    if errors:
        msg += f" — נכשל/חלקי: {', '.join(errors)} (דרוש מנהל?)"
    return 0, msg


def clean_prefetch() -> Tuple[int, str]:
    """Clears Prefetch; first launches after reboot may be slower."""
    windir = os.environ.get("WINDIR", r"C:\Windows")
    pf = Path(windir) / "Prefetch"
    if not pf.is_dir():
        return 0, "Prefetch"
    freed = _delete_tree_contents(pf)
    return freed, "Prefetch (טעינה ראשונה עלולה להאט)"


def clean_spotify_cache() -> Tuple[int, str]:
    freed = 0
    la = os.environ.get("LOCALAPPDATA")
    app = os.environ.get("APPDATA")
    if la:
        st = Path(la) / "Spotify" / "Storage"
        if st.is_dir():
            freed += _delete_tree_contents(st)
    if app:
        sp = Path(app) / "Spotify" / "Spotify"
        for sub in ("Browser", "Cache", "GPUCache"):
            p = sp / sub
            if p.is_dir():
                freed += _delete_tree_contents(p)
    if la:
        for pkg in (Path(la) / "Packages").glob("SpotifyAB.SpotifyMusic_*"):
            if pkg.is_dir():
                for rel in (("LocalState", "cache"), ("TempState",)):
                    sub = pkg.joinpath(*rel)
                    if sub.is_dir():
                        freed += _delete_tree_contents(sub)
    return freed, "מטמון Spotify"


def clean_teams_cache() -> Tuple[int, str]:
    freed = 0
    app = os.environ.get("APPDATA")
    if not app:
        return 0, "מטמון Microsoft Teams"
    base = Path(app) / "Microsoft" / "Teams"
    for sub in ("Cache", "blob_storage", "GPUCache", "Code Cache"):
        p = base / sub
        if p.is_dir():
            freed += _delete_tree_contents(p)
    sw = base / "Service Worker" / "CacheStorage"
    if sw.is_dir():
        freed += _delete_tree_contents(sw)
    return freed, "מטמון Microsoft Teams (סגור את Teams לפני)"


def clean_onedrive_logs() -> Tuple[int, str]:
    """Logs and setup logs only — not sync folder."""
    freed = 0
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "יומני OneDrive"
    for p in (
        Path(la) / "Microsoft" / "OneDrive" / "logs",
        Path(la) / "Microsoft" / "OneDrive" / "setup" / "logs",
    ):
        if p.is_dir():
            freed += _delete_tree_contents(p)
    return freed, "יומני OneDrive (לא תיקיית סנכרון)"


def clean_discord_cache() -> Tuple[int, str]:
    freed = 0
    app = os.environ.get("APPDATA")
    la = os.environ.get("LOCALAPPDATA")
    if app:
        d = Path(app) / "discord"
        for sub in ("Cache", "Code Cache", "GPUCache", "Service Worker"):
            p = d / sub
            if p.is_dir():
                freed += _delete_tree_contents(p)
    if la:
        p = Path(la) / "Discord" / "Cache"
        if p.is_dir():
            freed += _delete_tree_contents(p)
    return freed, "מטמון Discord (סגור לפני)"


def _privacy_chromium_profiles(base: Path) -> int:
    freed = 0
    if not base.is_dir():
        return 0
    for prof in base.iterdir():
        if not prof.is_dir():
            continue
        if prof.name not in ("Default",) and not prof.name.startswith("Profile"):
            continue
        for name in ("Cookies", "Cookies-journal"):
            f = prof / name
            if f.is_file():
                try:
                    sz = f.stat().st_size
                    f.unlink(missing_ok=True)
                    freed += sz
                except OSError:
                    pass
        ls = prof / "Local Storage" / "leveldb"
        if ls.is_dir():
            freed += _delete_tree_contents(ls)
        # Session storage is separate; optional small
        ss = prof / "Session Storage"
        if ss.is_dir():
            freed += _delete_tree_contents(ss)
    return freed


def clean_privacy_chromium_cookies_localstorage() -> Tuple[int, str]:
    """Cookies + Local Storage / Session Storage — not Login Data / passwords DB."""
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "פרטיות Chrome/Edge"
    freed = 0
    freed += _privacy_chromium_profiles(Path(la) / "Google" / "Chrome" / "User Data")
    freed += _privacy_chromium_profiles(Path(la) / "Microsoft" / "Edge" / "User Data")
    return freed, "פרטיות: Cookie ו־Local Storage (Chrome/Edge; לא סיסמאות שמורות)"


def clean_privacy_firefox_cookies() -> Tuple[int, str]:
    """Removes cookies.sqlite per profile — logins.json kept."""
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "פרטיות Firefox (עוגיות)"
    moz = Path(la) / "Mozilla" / "Firefox" / "Profiles"
    freed = 0
    if not moz.is_dir():
        return 0, "פרטיות Firefox (עוגיות)"
    for prof in moz.iterdir():
        if not prof.is_dir():
            continue
        for name in ("cookies.sqlite", "cookies.sqlite-shm", "cookies.sqlite-wal"):
            f = prof / name
            if f.is_file():
                try:
                    sz = f.stat().st_size
                    f.unlink(missing_ok=True)
                    freed += sz
                except OSError:
                    pass
    return freed, "פרטיות Firefox: עוגיות בלבד (לא logins.json)"


def clean_browser_history_chromium() -> Tuple[int, str]:
    """Destructive: browsing history DB for Chrome/Edge."""
    la = os.environ.get("LOCALAPPDATA")
    if not la:
        return 0, "היסטוריית Chrome/Edge"
    freed = 0
    for base in (
        Path(la) / "Google" / "Chrome" / "User Data",
        Path(la) / "Microsoft" / "Edge" / "User Data",
    ):
        if not base.is_dir():
            continue
        for prof in base.iterdir():
            if not prof.is_dir():
                continue
            if prof.name not in ("Default",) and not prof.name.startswith("Profile"):
                continue
            for name in ("History", "History-journal"):
                f = prof / name
                if f.is_file():
                    try:
                        sz = f.stat().st_size
                        f.unlink(missing_ok=True)
                        freed += sz
                    except OSError:
                        pass
            hpc = prof / "History Provider Cache"
            if hpc.is_dir():
                freed += _delete_tree_contents(hpc)
            elif hpc.is_file():
                try:
                    sz = hpc.stat().st_size
                    hpc.unlink(missing_ok=True)
                    freed += sz
                except OSError:
                    pass
    return freed, "היסטוריית גלישה Chrome/Edge (מסוכן — סגור דפדפן)"


# קבוצות לתצוגה, ל-manifest ולסדר הרצה (כל מפתח מופיע פעם אחת)
CATEGORY_GROUPS_HE: Tuple[Tuple[str, Tuple[str, ...]], ...] = (
    (
        "קבצים זמניים ומטמון כללי",
        (
            "temp_user",
            "temp_windows",
            "temp_inet",
            "thumbnails",
            "recycle_bin",
        ),
    ),
    (
        "Windows, עדכונים ושירותים (חלק מתקדם / מנהל)",
        (
            "dns_cache",
            "wer_local",
            "delivery_opt",
            "directx_shader",
            "windows_logs",
            "dism_winsxs",
            "store_cache",
            "windows_bt",
            "event_logs_wevt",
            "prefetch",
        ),
    ),
    (
        "דפדפנים, מטמון ופרטיות",
        (
            "chrome_cache",
            "edge_cache",
            "firefox_cache",
            "privacy_chromium",
            "privacy_firefox",
            "browser_history_chromium",
        ),
    ),
    (
        "אפליקציות (Spotify, Teams, OneDrive, Discord)",
        (
            "spotify_cache",
            "teams_cache",
            "onedrive_logs",
            "discord_cache",
        ),
    ),
)


def _ordered_category_keys() -> Tuple[str, ...]:
    out: List[str] = []
    for _title, keys in CATEGORY_GROUPS_HE:
        out.extend(keys)
    return tuple(out)


ORDERED_CATEGORY_KEYS: Tuple[str, ...] = _ordered_category_keys()


CLEANER_REGISTRY: Dict[str, CleanerFn] = {
    "temp_user": clean_temp_user,
    "temp_windows": clean_temp_windows,
    "temp_inet": clean_internet_temp,
    "thumbnails": clean_thumbnails,
    "recycle_bin": clean_recycle_bin,
    "dns_cache": clean_dns_cache,
    "wer_local": clean_wer_local,
    "delivery_opt": clean_delivery_opt,
    "chrome_cache": _browser_cache_chrome,
    "edge_cache": _browser_cache_edge,
    "firefox_cache": _browser_cache_firefox,
    "directx_shader": clean_directx_shader,
    "windows_logs": clean_windows_logs,
    "dism_winsxs": clean_dism_component_store,
    "store_cache": clean_microsoft_store_cache,
    "windows_bt": clean_windows_bt,
    "event_logs_wevt": clean_event_logs_wevtutil,
    "prefetch": clean_prefetch,
    "spotify_cache": clean_spotify_cache,
    "teams_cache": clean_teams_cache,
    "onedrive_logs": clean_onedrive_logs,
    "discord_cache": clean_discord_cache,
    "privacy_chromium": clean_privacy_chromium_cookies_localstorage,
    "privacy_firefox": clean_privacy_firefox_cookies,
    "browser_history_chromium": clean_browser_history_chromium,
}

CATEGORY_LABELS_HE: Dict[str, str] = {
    "temp_user": "קבצי Temp של המשתמש",
    "temp_windows": "Temp של Windows (דורש הרשאות מנהל לחלק מהקבצים)",
    "temp_inet": "מטמון אינטרנט (INetCache)",
    "thumbnails": "מטמון תמונות ממוזערות (Explorer)",
    "recycle_bin": "ריקון סל המחזור",
    "dns_cache": "ניקוי מטמון DNS",
    "wer_local": "תור דוחות שגיאות (WER)",
    "delivery_opt": "מטמון עדכונים (Delivery Optimization)",
    "chrome_cache": "מטמון Google Chrome (סגור דפדפן לפני)",
    "edge_cache": "מטמון Microsoft Edge (סגור דפדפן לפני)",
    "firefox_cache": "מטמון Mozilla Firefox (סגור דפדפן לפני)",
    "directx_shader": "מטמון DirectX Shader",
    "windows_logs": "יומני Windows (מתקדם — דורש הרשאות מנהל)",
    "dism_winsxs": "WinSxS / רכיבים — DISM /StartComponentCleanup (איטי; לעיתים דורש מנהל)",
    "store_cache": "מטמון Microsoft Store (Packages / LocalState cache)",
    "windows_bt": "⚠ $Windows.~BT — שטח שדרוג Windows (סיכון גבוה; לא במהלך שדרוג)",
    "event_logs_wevt": "⚠ יומני אירועים — wevtutil cl (לרוב דורש מנהל)",
    "prefetch": "⚠ Prefetch — מחיקת תחזיות טעינה (טעינה ראשונה עלולה להאט)",
    "spotify_cache": "מטמון Spotify",
    "teams_cache": "מטמון Microsoft Teams (מומלץ לסגור את Teams)",
    "onedrive_logs": "יומני OneDrive בלבד (לא תיקיית סנכרון)",
    "discord_cache": "מטמון Discord (מומלץ לסגור לפני)",
    "privacy_chromium": "פרטיות: Cookie + Local Storage ב‑Chrome/Edge (לא קבצי סיסמאות)",
    "privacy_firefox": "פרטיות: עוגיות Firefox בלבד (לא logins.json)",
    "browser_history_chromium": "⚠ היסטוריית גלישה Chrome/Edge (מחק History DB — סגור דפדפן)",
}

assert set(ORDERED_CATEGORY_KEYS) == set(CLEANER_REGISTRY.keys()), (
    "CATEGORY_GROUPS_HE חייב לכסות בדיוק את מפתחות CLEANER_REGISTRY"
)
assert len(ORDERED_CATEGORY_KEYS) == len(CLEANER_REGISTRY)


def export_predelete_manifest(enabled: Dict[str, bool]) -> Optional[Path]:
    """
    Writes a text summary: env + one line per enabled category (labels from CATEGORY_LABELS_HE).
    """
    from .config_store import config_dir

    lines: List[str] = [
        "# SeeDesktop Cleanup — manifest לפני ניקוי\n",
        f"# WINDIR={os.environ.get('WINDIR', r'C:\\Windows')}\n",
    ]
    la = os.environ.get("LOCALAPPDATA")
    if la:
        lines.append(f"# LOCALAPPDATA={la}\n")
    lines.append("\n# קטגוריות מופעלות (לפי קבוצות)\n")
    for title, keys in CATEGORY_GROUPS_HE:
        section_lines: List[str] = []
        for key in keys:
            if enabled.get(key):
                section_lines.append(f"[x] {key}\n    {CATEGORY_LABELS_HE[key]}\n")
        if section_lines:
            lines.append(f"\n## {title}\n")
            lines.extend(section_lines)
    lines.append("\n# סיום\n")
    dest = config_dir() / "manifests"
    try:
        dest.mkdir(parents=True, exist_ok=True)
        out = dest / f"predelete_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
        out.write_text("".join(lines), encoding="utf-8")
        return out
    except OSError:
        return None


def run_selected(enabled: Dict[str, bool]) -> List[Tuple[str, int, str]]:
    """Run cleaners where enabled[key] is True. Returns list of (id, bytes, label)."""
    results: List[Tuple[str, int, str]] = []
    for key in ORDERED_CATEGORY_KEYS:
        if not enabled.get(key, False):
            continue
        fn = CLEANER_REGISTRY[key]
        try:
            freed, label = fn()
            results.append((key, freed, label))
        except Exception as e:
            results.append((key, 0, f"{CATEGORY_LABELS_HE.get(key, key)} — שגיאה: {e}"))
    return results


def format_bytes(n: int) -> str:
    if n < 1024:
        return f"{n} בתים"
    if n < 1024**2:
        return f"{n / 1024:.1f} KB"
    if n < 1024**3:
        return f"{n / 1024**2:.1f} MB"
    return f"{n / 1024**3:.2f} GB"
