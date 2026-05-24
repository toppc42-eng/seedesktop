# -*- coding: utf-8 -*-
"""Generate lm-* entries for en.rs / he.rs and apply translate() in local_maintenance_page.dart."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DART = ROOT / "flutter/lib/desktop/pages/local_maintenance_page.dart"
EN_RS = ROOT / "src/lang/en.rs"
HE_RS = ROOT / "src/lang/he.rs"

# Hebrew literal -> (key, English)
PAIRS: list[tuple[str, str, str]] = [
    ("לוח בקרה — מחשב מקומי", "lm-dashboard-title", "Dashboard — local PC"),
    ("פעולות מערכת", "lm-system-actions", "System actions"),
    ("רק זמין למשתמשים בעלי רישיון Pro תקף", "lm-pro-only-hint", "Available only with a valid Pro license"),
    ("כלים מתקדמים — רישיון Pro פעיל.", "lm-pro-active-hint", "Advanced tools — Pro license active."),
    ("ניקוי, בדיקת דיסקים, תיקון מערכת, זיכרון RAM וטרמינל SYSTEM — דורשים רישיון Pro תקף.", "lm-pro-required-hint", "Cleanup, disk check, system repair, RAM test, and SYSTEM terminal require a valid Pro license."),
    ("ניקוי מחשב (SeeDesktop)", "lm-action-cleanup", "PC cleanup (SeeDesktop)"),
    ("SeeDesktopCleanup — ניקוי ותחזוקה", "lm-action-cleanup-tip", "SeeDesktopCleanup — cleanup and maintenance"),
    ("בדיקת כוננים", "lm-action-disk-check", "Drive check"),
    ("SeeDesktopDiskCheck — SMART, CHKDISK ודוחות", "lm-action-disk-check-tip", "SeeDesktopDiskCheck — SMART, CHKDSK, and reports"),
    ("תיקון קבצי מערכת (SFC / DISM)", "lm-action-sfc-dism", "System file repair (SFC / DISM)"),
    ("SeeDesktopSystemRepair — sfc /scannow ו-DISM", "lm-action-sfc-dism-tip", "SeeDesktopSystemRepair — sfc /scannow and DISM"),
    ("בדיקת זיכרון RAM", "lm-action-ram-test", "RAM memory test"),
    ("אבחון זיכרון Windows (mdsched) — בדיקת MemTest בסיסית ב-BOOT; לרוב נדרש אתחול", "lm-action-ram-test-tip", "Windows Memory Diagnostic (mdsched) — basic MemTest at boot; reboot usually required"),
    ("ניתוח עומס בזמן אמת", "lm-action-load-analysis", "Real-time load analysis"),
    ("טרמינל SYSTEM (מקומי)", "lm-action-system-terminal", "SYSTEM terminal (local)"),
    ("פותח טרמינל למחשב זה לפי מזהה Your desk (SeeDesk) — מצב מנהל / SYSTEM כמו ‎--terminal-admin", "lm-action-system-terminal-tip", "Opens a terminal on this PC (Your desk ID) — admin / SYSTEM mode like --terminal-admin"),
    ("מרענן נתונים...", "lm-refresh-busy", "Refreshing data…"),
    ("רענון מיידי של נתוני הדשבורד", "lm-refresh-dashboard-tip", "Refresh dashboard data now"),
    ("גודלי פונט בקוביות", "lm-font-settings-tip", "Cube font sizes"),
    ("גודלי פונט — נדרש רישיון Pro", "lm-font-settings-pro-tip", "Font sizes — Pro license required"),
    ("תחזוקה מקומית זמינה ב-Windows בלבד", "lm-windows-only", "Local maintenance is available on Windows only"),
    ("כרטיס מסך (GPU)", "lm-card-gpu", "Graphics card (GPU)"),
    ("דיסקים קשיחים", "lm-card-disks", "Hard drives"),
    ("זיכרון (RAM)", "lm-card-ram", "Memory (RAM)"),
    ("לוח אם", "lm-card-motherboard", "Motherboard"),
    ("מעבד (CPU)", "lm-card-cpu", "Processor (CPU)"),
    ("ביצועי מחשב", "lm-card-performance", "PC performance"),
    ("יציבות מערכת", "lm-card-stability", "System stability"),
    ("Watchdog — שירותים", "lm-card-watchdog", "Services — Watchdog"),
    ("שימוש רשת", "lm-card-network", "Network usage"),
    ("מולטימדיה", "lm-card-multimedia", "Multimedia"),
    ("רישיון SeeDesktop", "lm-card-license", "SeeDesktop license"),
    ("מדפסות", "lm-card-printers", "Printers"),
    ("אבטחה", "lm-card-security", "Security"),
    ("בריאות אפליקציות", "lm-card-app-health", "Application health"),
    ("מערכת הפעלה", "lm-card-os", "Operating system"),
    ("Microsoft / Office", "lm-card-office", "Microsoft / Office"),
    ("תקין", "lm-status-ok", "OK"),
    ("פועל", "lm-status-running", "Running"),
    ("עצור", "lm-status-stopped", "Stopped"),
    ("לא ידוע", "lm-status-unknown", "Unknown"),
    ("אזהרת נתונים", "lm-status-data-warning", "Data warning"),
    ("עומס קריטי", "lm-status-cpu-critical", "Critical load"),
    ("עומס בינוני", "lm-status-cpu-medium", "Moderate load"),
    ("זיכרון נמוך", "lm-status-ram-low", "Low memory"),
    ("שימוש גבוה", "lm-status-ram-high", "High usage"),
    ("חמים", "lm-status-warm", "Warm"),
    ("חום גבוה", "lm-status-hot", "Hot"),
    ("לא זמין", "lm-status-unavailable", "Unavailable"),
    ("מקום מוגבל", "lm-disk-space-low", "Low space"),
    ("מעט מקום", "lm-disk-space-limited", "Limited space"),
    ("סגירה", "lm-close", "Close"),
    ("סגור", "lm-close-alt", "Close"),
    ("ביטול", "lm-cancel", "Cancel"),
    ("הוסף", "lm-add", "Add"),
    ("רענן", "lm-refresh", "Refresh"),
    ("שגיאה:", "lm-error-prefix", "Error:"),
    ("הפעל עצורים", "lm-start-stopped-services", "Start stopped"),
    ("מפעיל…", "lm-starting", "Starting…"),
    ("הוסף שירות", "lm-add-service", "Add service"),
    ("הוספת שירות לניטור", "lm-add-service-title", "Add service to monitor"),
    ("למשל LanmanServer או W32Time", "lm-add-service-hint", "e.g. LanmanServer or W32Time"),
    ("טוען סטטוס שירותים…", "lm-loading-services", "Loading service status…"),
    ("אין שירותים ברשימה. לחצו «הוסף שירות» (למשל Spooler).", "lm-no-services-hint", "No services in the list. Tap «Add service» (e.g. Spooler)."),
    ("נפח מצטבר", "lm-net-cumulative", "Cumulative volume"),
    ("כתובת פנימית (IPv4)", "lm-net-ipv4-internal", "Internal address (IPv4)"),
    ("כתובת חיצונית (מחוץ לראוטר)", "lm-net-ipv4-external", "External address (outside router)"),
    ("רשימת שכנים (ARP)", "lm-net-arp-tip", "ARP neighbors"),
    ("רשימת שכנים (ARP) — נדרש Pro", "lm-net-arp-pro-tip", "ARP neighbors — Pro required"),
    ("שימוש", "lm-label-usage", "Usage"),
    ("גרסה", "lm-label-version", "Version"),
    ("רישיון Windows", "lm-label-windows-license", "Windows license"),
    ("Office", "lm-label-office", "Office"),
    ("תוכנות Microsoft", "lm-label-ms-apps", "Microsoft apps"),
    ("יצרן ודגם", "lm-label-vendor-model", "Vendor and model"),
    ("כרטיס קול", "lm-label-sound", "Sound card"),
    ("מסנכרן…", "lm-syncing", "Syncing…"),
    ("סנכרון מול שרת", "lm-sync-server", "Sync with server"),
    ("מודולים פיזיים: טוען…", "lm-ram-modules-loading", "Physical modules: loading…"),
    ("ניתוח עומס — קוביץ החלפה ו־10 צורכי זיכרון", "lm-ram-load-tip", "Load analysis — page file and top 10 memory consumers"),
    ("הגדרות שימוש באחסון (Windows)", "lm-disk-storage-tip", "Storage settings (Windows)"),
    ("גודלי פונט — לוח תחזוקה מקומית", "lm-font-dialog-title", "Font sizes — local maintenance dashboard"),
    ("כותרת שורה בראש כל קובייה (ברירת מחדל 15)", "lm-font-cube-title", "Cube row title (default 15)"),
    ("טקסט פנימי ופריטים (ברירת מחדל 14; יחס לפי עיצוב קודם)", "lm-font-cube-inner", "Inner text and items (default 14)"),
    ("כפתורי «פעולות מערכת» (סרגל שמאלי; נפרד מהקוביות; ברירת 12.5)", "lm-font-action-bar", "«System actions» buttons (left bar; default 12.5)"),
    ("נתוני הדשבורד רועננו ונשמרו למטמון היומי.", "lm-dashboard-refreshed", "Dashboard data refreshed and saved to daily cache."),
    ("נדרשות הרשאות (ממתין ל-Service)", "lm-needs-admin-service", "Administrator rights required (waiting for service)"),
    ("עוזר AI - המלצות", "lm-ai-advice-title", "AI assistant — recommendations"),
    ("פירוט הציונים", "lm-winsat-scores", "Score breakdown"),
    ("איך מפרשים את המספרים?", "lm-winsat-howto", "How to read the numbers?"),
    ("שדרוג: להריץ WinSAT", "lm-winsat-run", "Upgrade: run WinSAT"),
    ("שדרוג: אין מספיק נתונים", "lm-winsat-no-data", "Upgrade: not enough data"),
    ("שדרוג: לא דחוף", "lm-winsat-not-urgent", "Upgrade: not urgent"),
    ("שדרוג: לא חובה", "lm-winsat-optional", "Upgrade: optional"),
    ("לא זמין מזהה עמדה (Your desk). ודאו שהלקוח מחובר לשרת.", "lm-terminal-no-desk-id", "No desk ID (Your desk). Ensure the client is connected to the server."),
    ("נפתח טרמינל למחשב זה", "lm-terminal-opened-prefix", "Terminal opened for this PC"),
    ("במצב מנהל/SYSTEM.", "lm-terminal-admin-suffix", "in admin/SYSTEM mode."),
    ("לא ניתן לפתוח טרמינל:", "lm-terminal-open-failed", "Could not open terminal:"),
    ("כרטיסי רשת (לוח בקרה)", "lm-mb-network-cards", "Network adapters (dashboard)"),
    ("שכנים ברשת (ARP)", "lm-arp-dialog-title", "Network neighbors (ARP)"),
    ("אין נתונים זמינים.", "lm-no-data", "No data available."),
    ("משתמשים מקומיים", "lm-local-users-title", "Local users"),
    ("פעיל", "lm-user-enabled", "Enabled"),
    ("מושבת", "lm-user-disabled", "Disabled"),
    ("מדפסות ופורטים", "lm-printers-ports-title", "Printers and ports"),
    ("פורט:", "lm-port-label", "Port:"),
    ("מודול", "lm-module", "Module"),
    ("הרישיון אומת מול השרת.", "lm-license-verified", "License verified with server."),
    ("אימות נכשל", "lm-license-verify-failed", "Verification failed"),
    ("אין מפתח רישיון שמור. הזינו רישיון בהגדרות.", "lm-license-no-key", "No license key saved. Enter a license in Settings."),
    ("הפעולה הושלמה לאחר אישור מנהל (שירות IPC לא זמין).", "lm-done-after-uac", "Completed after administrator approval (service IPC unavailable)."),
    ("הפעלת שירותים הושלמה לאחר אישור מנהל (שירות IPC לא זמין).", "lm-services-started-uac", "Services started after administrator approval (service IPC unavailable)."),
    ("כל השירותים ברשימה כבר בריצה.", "lm-all-services-running", "All listed services are already running."),
    ("נשלחה בקשה להפעלת שירותים עצורים.", "lm-start-stopped-requested", "Request sent to start stopped services."),
    ("שם שירות לא תקין (אותיות, מספרים, מקף, נקודה בלבד).", "lm-invalid-service-name", "Invalid service name (letters, numbers, hyphen, dot only)."),
    ("השירות כבר ברשימה.", "lm-service-already-listed", "Service is already in the list."),
    ("לא ניתן לפתוח הגדרות שימוש בנתונים:", "lm-open-storage-failed", "Could not open storage settings:"),
    ("לא ניתן לפתוח חיבורי רשת:", "lm-open-network-failed", "Could not open network connections:"),
    ("פותח מדפסות זמינות…", "lm-opening-printers", "Opening printers…"),
    ("לא ניתן לפתוח מדפסות:", "lm-open-printers-failed", "Could not open printers:"),
    ("פותח הגדרות אחסון…", "lm-opening-storage", "Opening storage settings…"),
    ("לא ניתן לפתוח הגדרות:", "lm-open-settings-failed", "Could not open settings:"),
    ("בסיסי", "lm-tier-basic", "Basic"),
    ("יומיומי", "lm-tier-daily", "Everyday"),
    ("גבוה", "lm-tier-high", "High"),
    ("תחנת עבודה", "lm-tier-workstation", "Workstation"),
    ("Windows", "lm-windows", "Windows"),
    ("BIOS Version", "lm-bios-version", "BIOS version"),
    ("USB", "lm-usb", "USB"),
    ("בקר אחסון", "lm-storage-controller", "Storage controller"),
    ("Secure Boot", "lm-secure-boot", "Secure Boot"),
    ("צרכני מעבד (CPU) — עד 10", "lm-top-cpu-processes", "Top CPU processes — up to 10"),
    ("צרכני זיכרון (RAM) — עד 10", "lm-top-ram-processes", "Top memory processes — up to 10"),
    ("ניתוח עומס — 10 תהליכים צורכי מעבד", "lm-cpu-load-tip", "Load analysis — top 10 CPU processes"),
    ("מידע והרחבה", "lm-info-expand", "Info and details"),
    ("עוזר AI", "lm-ai-helper", "AI assistant"),
    ("ביצועי מחשב — WinSAT", "lm-winsat-title", "PC performance — WinSAT"),
    ("פירוט ציוני WinSAT וסולם פירוש", "lm-winsat-detail-tip", "WinSAT scores and interpretation"),
    ("שדרוג מומלץ:", "lm-upgrade-recommended-prefix", "Recommended upgrade:"),
    ("זיכרון (Memory)", "lm-memory-en", "Memory"),
    ("דיסק", "lm-disk-short", "Disk"),
    ("גרפיקה", "lm-graphics-short", "Graphics"),
    ("תלת־ממד / D3D", "lm-d3d-short", "3D / D3D"),
    ("לא ניתן לפתוח הגדרות שימוש בנתונים:", "lm-open-storage-failed-prefix", "Could not open storage settings:"),
    ("לא ניתן לפתוח חיבורי רשת:", "lm-open-network-failed-prefix", "Could not open network connections:"),
    ("לא ניתן לפתוח מדפסות:", "lm-open-printers-failed-prefix", "Could not open printers:"),
    ("לא ניתן לפתוח הגדרות:", "lm-open-settings-failed-prefix", "Could not open settings:"),
    ("לא ניתן לפתוח טרמינל:", "lm-open-terminal-failed-prefix", "Could not open terminal:"),
    ("נפתח טרמינל למחשב זה ($id) במצב מנהל/SYSTEM.", "lm-terminal-opened", "Terminal opened for this PC ($id) in admin/SYSTEM mode."),
    ("נפתח אבחון זיכרון של Windows. בחרו אתחול כדי להריץ בדיקה (MemTest של המערכת).", "lm-ram-test-started", "Windows memory diagnostic started. Choose restart to run the test (system MemTest)."),
    ("לא ניתן להפעיל:", "lm-launch-failed-prefix", "Could not launch:"),
    ("רוחב פס משוער:", "lm-bandwidth-est-prefix", "Estimated bandwidth:"),
    ("קצב: —", "lm-rate-none", "Rate: —"),
    ("שימוש היום (משוער)", "lm-usage-today-est", "Today's usage (estimated)"),
    ("סה״כ הורדה+העלאה היום", "lm-total-today", "Total download+upload today"),
    ("הערכת שימוש יומי", "lm-daily-usage-est", "Estimated daily usage"),
    ("מעל 5 GB — בדקו עומס רשת / VPN / גיבוי", "lm-net-over-5gb", "Over 5 GB — check network load / VPN / backup"),
    ("טוען…", "lm-loading", "Loading…"),
    ("התחברות אחרונה:", "lm-last-logon-prefix", "Last logon:"),
    ("— נדרש רישיון Pro תקף", "lm-pro-license-required-suffix", "— valid Pro license required"),
    ("5 קריסות אחרונות", "lm-last-5-crashes-title", "Last 5 application crashes"),
    ("לא נמצאו רשומות שגיאה אחרונות.", "lm-no-recent-error-records", "No recent error records found."),
    ("מקור:", "lm-error-source-prefix", "Source:"),
    ("5 כיבויים בלתי צפויים אחרונים", "lm-last-5-unexpected-shutdowns-title", "Last 5 unexpected shutdowns"),
    ("לא נמצאו אירועי כיבוי בלתי צפוי אחרונים.", "lm-no-recent-unexpected-shutdowns", "No recent unexpected shutdown events found."),
    ("שנה רישיון", "lm-change-license", "Change license"),
    ("טוען...", "lm-loading-ellipsis", "Loading…"),
    ("טוען מנתוני שירות…", "lm-loading-from-service", "Loading from service…"),
    ("ודאו ששירות הניהול המקומי (IPC) פעיל.", "lm-ensure-ipc-service", "Ensure the local management service (IPC) is running."),
    ("טוען ספירת מתאמים דרך שירות…", "lm-loading-neighbors-service", "Loading neighbor count via service…"),
    ("שימוש באפליקציות", "lm-app-usage-settings", "App usage settings"),
    ("פרטי MAC / ARP: טוען…", "lm-mac-arp-loading", "MAC / ARP details: loading…"),
    ("הכל פועל", "lm-all-running", "All running"),
    ("מושהה", "lm-paused", "Paused"),
    ("ניטור", "lm-monitoring", "Monitoring"),
    ("המשך ניטור", "lm-resume-monitoring", "Resume monitoring"),
    ("השהה ניטור", "lm-pause-monitoring", "Pause monitoring"),
    ("נדרש רישיון Pro", "lm-pro-required-short", "Pro license required"),
    ("ניטור מושהה — לא תתבצע בדיקה או הפעלה אוטומטית.", "lm-monitoring-paused-hint", "Monitoring paused — no automatic check or start."),
    ("הסר מהרשימה", "lm-remove-from-list", "Remove from list"),
    ("הסרה — נדרש רישיון Pro", "lm-remove-pro-required", "Remove — Pro license required"),
    ("בדיקה כל דקה · הפעלה אוטומטית של עצורים כשהניטור פעיל.", "lm-watchdog-minute-hint", "Check every minute · auto-start stopped services when monitoring is active."),
    ("לא נמצאו כוננים", "lm-no-drives-found", "No drives found"),
    ("כונן", "lm-drive-generic", "Drive"),
    ("אזהרה", "lm-warning-short", "Warning"),
    ("Office לא זוהה", "lm-office-not-detected", "Office not detected"),
    ("לא זוהה Office מותקן", "lm-office-not-installed", "No Office installation detected"),
    ("לא נמצאו תוכנות Microsoft נוספות", "lm-no-extra-ms-apps", "No additional Microsoft apps found"),
    ("פורט:", "lm-port-colon", "Port:"),
    (" ·  פורט:", "lm-port-inline", " · Port:"),
    (" ·  התחברות אחרונה:", "lm-last-logon-inline", " · Last logon:"),
    ("מחיצות: —", "lm-partitions-none", "Partitions: —"),
    ("מכשירי רשת פעילים:", "lm-active-net-devices-prefix", "Active network devices:"),
    ("כיבוי בלתי צפוי (41):", "lm-unexpected-shutdown-41-prefix", "Unexpected shutdown (41):"),
    ("5 אירועי כיבוי בלתי צפוי אחרונים (Event ID 41)", "lm-stability-shutdown-tip", "Last 5 unexpected shutdown events (Event ID 41)"),
    ("ניתוח עומס — קובץ החלפה ו־10 צורכי זיכרון", "lm-ram-pagefile-tip", "Load analysis — page file and top 10 memory consumers"),
    ("לא נמצאה הערכת WinSAT במחשב זה.", "lm-winsat-not-found", "No WinSAT assessment found on this PC."),
    ("אין עדיין ציונים, לכן אין המלצת חומרה מדויקת.", "lm-winsat-no-scores-yet", "No scores yet — no precise hardware recommendation."),
    ("לא נמצאו ציוני רכיבים תקינים.", "lm-winsat-no-valid-scores", "No valid component scores found."),
    ("המערכת חזקה. שדרוג מומלץ רק לפי צורך עבודה ספציפי.", "lm-winsat-strong-system", "System is strong. Upgrade only if a specific workload requires it."),
    ("הוא החלש יחסית, אך הציון מעל 6 ולכן שדרוג תלוי צורך.", "lm-winsat-weak-but-ok", "is relatively weak, but score is above 6 — upgrade depends on need."),
    ("שדרוג מומלץ:", "lm-winsat-upgrade-title-prefix", "Recommended upgrade:"),
    ("ציון כללי:", "lm-winsat-overall-score-prefix", "Overall score:"),
    ("מתאים למשימות פשוטות, גלישה בסיסית ואימיילים.", "lm-winsat-tier-basic-desc", "Suited for simple tasks, basic browsing, and email."),
    ("מתאים לעבודה משרדית, וידאו ומשחקים בסיסיים.", "lm-winsat-tier-daily-desc", "Suited for office work, video, and light gaming."),
    ("מתאים לריבוי משימות, עבודה אינטנסיבית ועריכת תמונות.", "lm-winsat-tier-high-desc", "Suited for multitasking, intensive work, and photo editing."),
    ("ביצועים מעולים לעריכת וידאו, תלת־ממד וגיימינג כבד.", "lm-winsat-tier-workstation-desc", "Excellent for video editing, 3D, and heavy gaming."),
    ("להחליף ל־SSD/NVMe או לבדוק בריאות דיסק.", "lm-winsat-suggest-disk", "Switch to SSD/NVMe or check disk health."),
    ("להגדיל RAM או לשדרג למהירות/דור תואם לוח אם.", "lm-winsat-suggest-ram", "Add RAM or upgrade to speed/generation compatible with the motherboard."),
    ("לשדרג GPU/דרייבר אם יש עבודה גרפית או מסכים כבדים.", "lm-winsat-suggest-gpu", "Upgrade GPU/driver for heavy graphics or multiple displays."),
    ("לשדרג GPU אם נדרש גיימינג/תלת־ממד/וידאו כבד.", "lm-winsat-suggest-3d", "Upgrade GPU for gaming/3D/heavy video."),
    ("לשדרג CPU/פלטפורמה אם יש עומס חישובי קבוע.", "lm-winsat-suggest-cpu", "Upgrade CPU/platform for sustained compute load."),
    ("כרטיס מסך", "lm-part-gpu", "Graphics card"),
    ("תלת־ממד", "lm-part-3d", "3D"),
    ("מעבד", "lm-part-cpu", "Processor"),
    ("זיכרון", "lm-part-ram", "Memory"),
    ("שימוש ", "lm-usage-cpu-prefix", "Usage "),
    ("הערכה מהיום (מספר מתאמים):", "lm-net-est-today-prefix", "Estimate since today (neighbor count):"),
    ("סכום נפח מצטבר (↓+↑) מעל 5GB — מומלץ לבדוק שימוש לפי אפליקציה.", "lm-net-cumulative-over-5gb", "Cumulative volume (↓+↑) over 5GB — check per-app usage."),
    ("מעל 5GB (יממה או מצטבר) — מומלץ לבדוק שימוש לפי אפליקציה.", "lm-net-daily-over-5gb", "Over 5GB (daily or cumulative) — check per-app usage."),
    ("דיסק פיזי ", "lm-physical-disk-prefix", "Physical disk "),
    ("פורט/Bus:", "lm-port-bus-label", "Port/Bus:"),
    (" GB פנוי", "lm-gb-free-suffix", " GB free"),
    ("פנוי", "lm-free-short", "free"),
    (
        "1.0–3.9 מחשב בסיסי: משימות פשוטות, גלישה בסיסית ואימיילים. עלול להתקשות בריבוי משימות.\n\n"
        "4.0–5.9 שימוש יומיומי ובידור: מערכת הפעלה חלקה, וידאו HD/4K, עבודה משרדית ומשחקים בסיסיים.\n\n"
        "6.0–7.9 ביצועים גבוהים: עבודה אינטנסיבית, הרבה חלונות וכרטיסיות, גיימינג בינוני־גבוה ועריכת תמונות.\n\n"
        "8.0–9.9 תחנת עבודה / גיימינג קיצון: עריכת וידאו כבדה, מודלים בתלת־ממד וגיימינג בהגדרות גבוהות.",
        "lm-winsat-howto-body",
        "1.0–3.9 Basic PC: simple tasks, light browsing, and email. May struggle with heavy multitasking.\n\n"
        "4.0–5.9 Everyday use: smooth OS, HD/4K video, office work, and light gaming.\n\n"
        "6.0–7.9 High performance: intensive work, many windows/tabs, mid–high gaming, and photo editing.\n\n"
        "8.0–9.9 Workstation / extreme gaming: heavy video editing, 3D, and high-settings gaming.",
    ),
]

# Sort longest Hebrew first to avoid partial replacement
PAIRS.sort(key=lambda x: -len(x[0]))


def rust_line(key: str, en: str) -> str:
    esc = en.replace("\\", "\\\\").replace('"', '\\"')
    return f'        ("{key}", "{esc}"),'


def inject_lang(path: Path, entries: list[str]) -> None:
    text = path.read_text(encoding="utf-8")
    marker = '        ("lm-external-tools-section",'
    if marker not in text:
        raise SystemExit(f"marker not found in {path}")
    block = "\n".join(entries) + "\n"
    if entries[0].split('"')[1] in text:
        print(f"skip inject {path.name} (keys exist)")
        return
    text = text.replace(marker, block + marker, 1)
    path.write_text(text, encoding="utf-8")
    print(f"injected {len(entries)} keys into {path.name}")


def apply_dart() -> None:
    text = DART.read_text(encoding="utf-8")
    if "import 'package:flutter_hbb/desktop/pages/lm_i18n.dart'" not in text:
        text = text.replace(
            "import 'package:flutter_hbb/common.dart' show setEnvTerminalAdmin, translate;",
            "import 'package:flutter_hbb/common.dart' show setEnvTerminalAdmin, translate;\n"
            "import 'package:flutter_hbb/consts.dart' show kCommConfKeyLang;\n"
            "import 'package:flutter_hbb/desktop/pages/lm_i18n.dart';",
        )
    count = 0
    for he, key, _en in PAIRS:
        for pattern, repl in [
            (f"'{he}'", f"lm('{key}')"),
            (f'"{he}"', f'lm("{key}")'),
            (f"const Text('{he}')", f"Text(lm('{key}'))"),
            (f'const Text("{he}")', f'Text(lm("{key}"))'),
            (f"label: '{he}'", f"label: lm('{key}')"),
            (f'title: \'{he}\'', f"title: lm('{key}')"),
            (f"tooltip: '{he}'", f"tooltip: lm('{key}')"),
            (f"infoTooltip: '{he}'", f"infoTooltip: lm('{key}')"),
            (f"infoTooltip:\n          '{he}'", f"infoTooltip: lm('{key}')"),
        ]:
            if pattern in text:
                text = text.replace(pattern, repl)
                count += 1
    text = text.replace("textDirection: TextDirection.rtl", "textDirection: lmDir")
    text = text.replace(
        "textDirection: TextDirection.rtl,",
        "textDirection: lmDir,",
    )
    text = text.replace(
        "textDirection: TextDirection.rtl,\n      child: LayoutBuilder",
        "textDirection: lmDir,\n      child: LayoutBuilder",
    )
    text = text.replace(
        "textDirection: TextDirection.rtl,\n          child: Column",
        "textDirection: lmDir,\n          child: Column",
    )
    DART.write_text(text, encoding="utf-8")
    print(f"dart replacements applied ({count} literal swaps)")


def main() -> None:
    import sys

    dart_only = "--dart-only" in sys.argv
    en_entries = [rust_line(k, en) for _he, k, en in reversed(PAIRS)]
    he_entries = [rust_line(k, he) for he, k, _en in reversed(PAIRS)]
    if not dart_only:
        inject_lang(EN_RS, en_entries)
        inject_lang(HE_RS, he_entries)
    apply_dart()


if __name__ == "__main__":
    main()
