import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/utils/local_maintenance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kLocalMaintenanceCleanPrefsKeyV2 =
    'local_maintenance_clean_options_v2';

/// Copper / bronze accent for maintenance UI (works on dark surfaces).
/// מיתוג ירוק־טורקיז (עקבי עם [MyTheme.accent]).
const Color kLocalMaintenanceCopper = Color(0xFF36BA9B);
const Color kLocalMaintenanceCopperDim = Color(0xFF2A8F7A);

Future<void> showLocalMaintenanceSystemCleanDialog(BuildContext context) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('זמין רק ב-Windows')),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => const _LocalMaintenanceCleanDialogBody(),
  );
}

class _LocalMaintenanceCleanDialogBody extends StatefulWidget {
  const _LocalMaintenanceCleanDialogBody();

  @override
  State<_LocalMaintenanceCleanDialogBody> createState() =>
      _LocalMaintenanceCleanDialogBodyState();
}

class _LocalMaintenanceCleanDialogBodyState
    extends State<_LocalMaintenanceCleanDialogBody> {
  CleanupScheduleMode _schedule = CleanupScheduleMode.runNow;

  bool _userTemp = true;
  bool _windowsTemp = true;
  bool _inetCache = true;
  bool _explorerCache = true;
  bool _recycleBin = false;

  bool _dnsCache = true;
  bool _wer = true;
  bool _deliveryOptimization = false;
  bool _directXShader = true;
  bool _windowsLogs = false;
  bool _winSxS = false;
  bool _microsoftStoreCache = false;
  bool _windowsBt = false;
  bool _prefetch = false;

  bool _chromeCache = false;
  bool _edgeCache = false;
  bool _firefoxCache = false;
  bool _cookiesLocalStorage = false;
  bool _historyDb = false;

  bool _spotifyCache = false;
  bool _teamsCache = false;
  bool _oneDriveCache = false;
  bool _discordCache = false;

  bool _running = false;

  LocalMaintenanceCleanOptions get _options => LocalMaintenanceCleanOptions(
        userTemp: _userTemp,
        windowsTemp: _windowsTemp,
        inetCache: _inetCache,
        explorerCache: _explorerCache,
        recycleBin: _recycleBin,
        dnsCache: _dnsCache,
        wer: _wer,
        deliveryOptimization: _deliveryOptimization,
        directXShader: _directXShader,
        windowsLogs: _windowsLogs,
        winSxS: _winSxS,
        microsoftStoreCache: _microsoftStoreCache,
        windowsBt: _windowsBt,
        prefetch: _prefetch,
        chromeCache: _chromeCache,
        edgeCache: _edgeCache,
        firefoxCache: _firefoxCache,
        cookiesLocalStorage: _cookiesLocalStorage,
        historyDb: _historyDb,
        spotifyCache: _spotifyCache,
        teamsCache: _teamsCache,
        oneDriveCache: _oneDriveCache,
        discordCache: _discordCache,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      var raw = p.getString(kLocalMaintenanceCleanPrefsKeyV2);
      if (raw == null || raw.isEmpty) {
        raw = p.getString('local_maintenance_clean_options_v1');
      }
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw) as Map<String, dynamic>?;
      if (m == null) return;
      if (!mounted) return;
      setState(() {
        final o = LocalMaintenanceCleanOptions.fromJson(m);
        _userTemp = o.userTemp;
        _windowsTemp = o.windowsTemp;
        _inetCache = o.inetCache;
        _explorerCache = o.explorerCache;
        _recycleBin = o.recycleBin;
        _dnsCache = o.dnsCache;
        _wer = o.wer;
        _deliveryOptimization = o.deliveryOptimization;
        _directXShader = o.directXShader;
        _windowsLogs = o.windowsLogs;
        _winSxS = o.winSxS;
        _microsoftStoreCache = o.microsoftStoreCache;
        _windowsBt = o.windowsBt;
        _prefetch = o.prefetch;
        _chromeCache = o.chromeCache;
        _edgeCache = o.edgeCache;
        _firefoxCache = o.firefoxCache;
        _cookiesLocalStorage = o.cookiesLocalStorage;
        _historyDb = o.historyDb;
        _spotifyCache = o.spotifyCache;
        _teamsCache = o.teamsCache;
        _oneDriveCache = o.oneDriveCache;
        _discordCache = o.discordCache;
        final sch = m['schedule'] as String?;
        if (sch != null) {
          _schedule = CleanupScheduleMode.values.firstWhere(
            (e) => e.name == sch,
            orElse: () => CleanupScheduleMode.runNow,
          );
        }
      });
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final map = _options.toJson();
      map['schedule'] = _schedule.name;
      await p.setString(kLocalMaintenanceCleanPrefsKeyV2, jsonEncode(map));
    } catch (_) {}
  }

  String get _primaryLabel => _schedule == CleanupScheduleMode.runNow
      ? 'הרץ ניקוי עכשיו'
      : 'שמור בחירה ותזמן';

  Future<void> _submit() async {
    if (!_options.hasAnySelected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('בחר לפחות פריט אחד לניקוי')),
      );
      return;
    }
    await _savePrefs();
    setState(() => _running = true);
    try {
      if (_schedule == CleanupScheduleMode.runNow) {
        await LocalMaintenanceService.runSystemCleaner(_options);
        if (!mounted) return;
        final uac = LocalMaintenanceService.takePendingUacFallbackCompletionHint();
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              uac
                  ? 'הניקוי הסתיים לאחר אישור מנהל (שירות IPC לא זמין).'
                  : 'הניקוי הסתיים',
            ),
          ),
        );
      } else {
        await LocalMaintenanceService.scheduleCleanup(_options, _schedule);
        if (!mounted) return;
        final uac = LocalMaintenanceService.takePendingUacFallbackCompletionHint();
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              uac
                  ? 'התזמון נשמר לאחר אישור מנהל (שירות IPC לא זמין).'
                  : 'התזמון נשמר — המשימה תופעל לפי לוח הזמנים',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('שגיאה: $e')),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Row(
          children: [
            Icon(Icons.cleaning_services_outlined, color: kLocalMaintenanceCopper),
            const SizedBox(width: 8),
            const Expanded(child: Text('ניקוי מערכת מתקדם')),
          ],
        ),
        content: SizedBox(
          width: 460,
          height: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'תזמון',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              SegmentedButton<CleanupScheduleMode>(
                segments: const [
                  ButtonSegment(
                    value: CleanupScheduleMode.runNow,
                    label: Text('הרץ עכשיו'),
                  ),
                  ButtonSegment(
                    value: CleanupScheduleMode.daily,
                    label: Text('יומי'),
                  ),
                  ButtonSegment(
                    value: CleanupScheduleMode.weekly,
                    label: Text('שבועי'),
                  ),
                  ButtonSegment(
                    value: CleanupScheduleMode.monthly,
                    label: Text('חודשי'),
                  ),
                ],
                selected: {_schedule},
                onSelectionChanged: _running
                    ? null
                    : (s) {
                        if (s.isEmpty) return;
                        setState(() => _schedule = s.first);
                      },
                multiSelectionEnabled: false,
                emptySelectionAllowed: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: WidgetStateProperty.resolveWith((st) {
                    if (st.contains(WidgetState.selected)) {
                      return cs.onPrimary;
                    }
                    return cs.onSurface;
                  }),
                  backgroundColor: WidgetStateProperty.resolveWith((st) {
                    if (st.contains(WidgetState.selected)) {
                      return kLocalMaintenanceCopper;
                    }
                    return cs.surfaceContainerHighest;
                  }),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _groupTitle(cs, 'קבצים זמניים ומטמון כללי'),
                      _cb('Temp משתמש', _userTemp, (v) => _userTemp = v),
                      _cb('Temp Windows', _windowsTemp, (v) => _windowsTemp = v),
                      _cb('INetCache', _inetCache, (v) => _inetCache = v),
                      _cb('מטמון Explorer', _explorerCache, (v) => _explorerCache = v),
                      _cb('סל המיחזור', _recycleBin, (v) => _recycleBin = v),
                      _groupTitle(cs, 'עדכונים ושירותים'),
                      _cb('מטמון DNS', _dnsCache, (v) => _dnsCache = v),
                      _cb('WER (דיווח שגיאות Windows)', _wer, (v) => _wer = v),
                      _cb('Delivery Optimization', _deliveryOptimization,
                          (v) => _deliveryOptimization = v),
                      _cb('מטמון DirectX Shader', _directXShader,
                          (v) => _directXShader = v),
                      _cb('יומני Windows (Event Viewer)', _windowsLogs,
                          (v) => _windowsLogs = v),
                      _cb('WinSxS / ניקוי רכיבים (DISM)', _winSxS,
                          (v) => _winSxS = v),
                      _cb('מטמון Microsoft Store', _microsoftStoreCache,
                          (v) => _microsoftStoreCache = v),
                      _cb(r'$Windows.~BT (שדרוג Windows)', _windowsBt,
                          (v) => _windowsBt = v),
                      _cb('Prefetch', _prefetch, (v) => _prefetch = v),
                      _groupTitle(cs, 'דפדפנים, מטמון ופרטיות'),
                      _cb('Google Chrome — מטמון', _chromeCache,
                          (v) => _chromeCache = v),
                      _cb('Microsoft Edge — מטמון', _edgeCache,
                          (v) => _edgeCache = v),
                      _cb('Mozilla Firefox — מטמון', _firefoxCache,
                          (v) => _firefoxCache = v),
                      _cb('Cookies + Local Storage (Chrome/Edge)',
                          _cookiesLocalStorage, (v) => _cookiesLocalStorage = v),
                      _cb('מסד History (Chrome/Edge)', _historyDb,
                          (v) => _historyDb = v),
                      _groupTitle(cs, 'אפליקציות'),
                      _cb('מטמון Spotify', _spotifyCache,
                          (v) => _spotifyCache = v),
                      _cb('מטמון Microsoft Teams', _teamsCache,
                          (v) => _teamsCache = v),
                      _cb('OneDrive — לוגים/זמני', _oneDriveCache,
                          (v) => _oneDriveCache = v),
                      _cb('מטמון Discord', _discordCache,
                          (v) => _discordCache = v),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _running ? null : () => Navigator.of(context).pop(),
            child: const Text('ביטול'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: kLocalMaintenanceCopper,
              foregroundColor: cs.onPrimary,
            ),
            onPressed: _running ? null : _submit,
            child: _running
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_primaryLabel),
          ),
        ],
      ),
    );
  }

  Widget _groupTitle(ColorScheme cs, String t) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        t,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: cs.primary,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _cb(String title, bool value, void Function(bool) set) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 13)),
      value: value,
      onChanged: _running
          ? null
          : (v) => setState(() => set(v ?? false)),
    );
  }
}
