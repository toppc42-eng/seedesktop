/// Mirrors `tools/seedesktop_cleanup` — category ids and Hebrew labels for Flutter UI.
/// Settings file: `%LOCALAPPDATA%\\SeeDesktopCleanup\\settings.json` (shared with Python EXE).

const List<(String titleHe, List<(String id, String labelHe)>)> kLocalCleanupGroups = [
  (
    'קבצים זמניים ומטמון כללי',
    [
      ('temp_user', 'קבצי Temp של המשתמש'),
      ('temp_windows', 'Temp של Windows (חלק דורש מנהל)'),
      ('temp_inet', 'מטמון אינטרנט (INetCache)'),
      ('thumbnails', 'מטמון תמונות ממוזערות (Explorer)'),
      ('recycle_bin', 'ריקון סל המחזור'),
    ],
  ),
  (
    'Windows, עדכונים ושירותים (מתקדם / מנהל)',
    [
      ('dns_cache', 'ניקוי מטמון DNS'),
      ('wer_local', 'תור דוחות שגיאות (WER)'),
      ('delivery_opt', 'מטמון עדכונים (Delivery Optimization)'),
      ('directx_shader', 'מטמון DirectX Shader'),
      ('windows_logs', 'יומני Windows (תיקיית Logs)'),
      ('dism_winsxs', 'WinSxS — DISM /StartComponentCleanup (איטי; לעיתים מנהל)'),
      ('store_cache', 'מטמון Microsoft Store (Packages)'),
      ('windows_bt', '⚠ \$Windows.~BT — סיכון גבוה'),
      ('event_logs_wevt', '⚠ יומני אירועים — wevtutil (לרוב מנהל)'),
      ('prefetch', '⚠ Prefetch — טעינה ראשונה עלולה להאט'),
    ],
  ),
  (
    'דפדפנים, מטמון ופרטיות',
    [
      ('chrome_cache', 'מטמון Google Chrome'),
      ('edge_cache', 'מטמון Microsoft Edge'),
      ('firefox_cache', 'מטמון Mozilla Firefox'),
      ('privacy_chromium', 'פרטיות: Cookie + Local Storage (Chrome/Edge)'),
      ('privacy_firefox', 'פרטיות: עוגיות Firefox בלבד'),
      ('browser_history_chromium', '⚠ היסטוריית גלישה Chrome/Edge'),
    ],
  ),
  (
    'אפליקציות (Spotify, Teams, OneDrive, Discord)',
    [
      ('spotify_cache', 'מטמון Spotify'),
      ('teams_cache', 'מטמון Microsoft Teams'),
      ('onedrive_logs', 'יומני OneDrive (לא תיקיית סנכרון)'),
      ('discord_cache', 'מטמון Discord'),
    ],
  ),
];

Map<String, bool> defaultCategoriesBool() {
  final m = <String, bool>{};
  for (final g in kLocalCleanupGroups) {
    for (final e in g.$2) {
      m[e.$1] = _defaultOn(e.$1);
    }
  }
  return m;
}

bool _defaultOn(String id) {
  switch (id) {
    case 'temp_user':
    case 'temp_windows':
    case 'temp_inet':
    case 'thumbnails':
    case 'dns_cache':
    case 'wer_local':
    case 'directx_shader':
    case 'store_cache':
      return true;
    default:
      return false;
  }
}

Map<String, dynamic> defaultSchedule() => {
      'enabled': false,
      'mode': 'daily',
      'hour': 2,
      'minute': 0,
      'weekday': 0,
      'monthday': 1,
    };

Map<String, dynamic> defaultOptions() => {
      'backup_manifest_before_run': false,
    };
