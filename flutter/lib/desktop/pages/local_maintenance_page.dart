import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart'
    show isWindows, setEnvTerminalAdmin, translate;
import 'package:flutter_hbb/desktop/pages/lm_i18n.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart'
    show DesktopSettingPage, SettingsTabKey;
import 'package:flutter_hbb/desktop/widgets/it_troubleshooting_chat_widget.dart';
import 'package:flutter_hbb/desktop/widgets/local_maintenance_clean_dialog.dart'
    show kLocalMaintenanceCopper, kLocalMaintenanceCopperDim;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart'
    show
        getLicenseStatusDisplayTextLocal,
        hasRmmLicenseLocal,
        licenseStatusWithoutWebsiteSuffix;
import 'package:flutter_hbb/utils/local_maintenance_service.dart';
import 'package:flutter_hbb/utils/license_manager.dart'
    show getSavedLicenseKey, maskLicense, verifyLicenseWithServer;
import 'package:flutter_hbb/utils/multi_window_manager.dart'
    show rustDeskWinManager;
import 'package:flutter_hbb/utils/seedesktop_cleanup_launcher.dart';
import 'package:flutter_hbb/utils/extapps_launcher.dart'
    show ExternalItTool,
        kExternalItTools,
        launchExternalItTool,
        secretFolderItToolsForPlatform;
import 'package:flutter_hbb/common/widgets/rmm_pro_gate_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const double _kSidebarWidth = 236;
const double _kCompactRmmBreakpoint = 760;

const String _kPrefWatchdogServices = 'lm_watchdog_service_names_v1';
const String _kPrefWatchdogPaused = 'lm_watchdog_paused_v1';

/// מטמון לנתונים "סטטיים" (forensic / audit / רשת) — רענון לכל היותר כל 24 שעות.
const String _kPrefStaticBundleMs = 'lm_static_bundle_ms_v1';
const String _kPrefCacheForensic = 'lm_cache_forensic_json_v1';
const String _kPrefCacheAudit = 'lm_cache_audit_json_v4';
const String _kPrefCacheNet = 'lm_cache_net_json_v1';
const String _kPrefCacheWinSat = 'lm_cache_winsat_json_v1';

/// ספירת מתאמים: בסיס ליום מקומי (להערכת שימוש «מהיום» בלוח).
const String _kPrefNetDailyDate = 'lm_net_daily_date_v1';
const String _kPrefNetDailyBaseRx = 'lm_net_daily_base_rx_v1';
const String _kPrefNetDailyBaseTx = 'lm_net_daily_base_tx_v1';

/// אזהרת נתונים כשהערכת שימוש יומית (↓+↑) עוברת סף זה.
const int _kNetDailyWarnBytes = 5 * 1024 * 1024 * 1024;

/// גודל כותרת שורה בראש כל קובייה (ברירת מחדל 15), וגודל בסיס לטקסט פנימי (ברירת 14; יחס לפי עיצוב קודם מול 10).
const String _kPrefLmCubeTitlePx = 'lm_dash_cube_title_px_v1';
const String _kPrefLmCubeInnerPx = 'lm_dash_cube_inner_px_v1';
const String _kPrefLmActionInnerPx = 'lm_dash_action_inner_px_v1';

/// מצב תצוגה לדיאלוג [ניתוח עומס] — מסך מלא / קוביית מעבד / קוביית זיכרון.
enum _LmRtLoadMode { full, cpuOnly, ramOnly }

/// High-density IT dashboard: [Row] with **LTR** so the action strip stays
/// physically on the **left**; main stats use **RTL** for Hebrew.
class LocalMaintenancePage extends StatefulWidget {
  const LocalMaintenancePage({super.key});

  @override
  State<LocalMaintenancePage> createState() => _LocalMaintenancePageState();
}

class _LocalMaintenancePageState extends State<LocalMaintenancePage> {
  /// רק מדדי CPU/RAM/דיסקים (קלים) — לא forensic/audit/רשת.
  Timer? _poll;

  double? _cpu;
  double? _ramUsedPct;
  double? _ramUsedGb;
  double? _ramTotalGb;
  String _osLine = '—';
  String _cpuModelLine = '—';
  Map<String, dynamic>? _hw;

  int? _netRx;
  int? _netTx;
  int? _prevNetRx;
  int? _prevNetTx;
  DateTime? _prevNetAt;
  double? _netMbps;
  String? _netLocalIpv4;
  String? _netPublicIp;

  bool _busyWatchdogManualStart = false;

  /// שירותים לניטור (שם קצר של Windows); ברירת מחדל Spooler.
  List<String> _watchdogServiceNames = <String>['Spooler'];

  /// כשמופעל — לא רצים בדיקה/הפעלה אוטומטית (טיימר דקה).
  bool _watchdogPaused = false;

  Timer? _watchdogTimer;

  /// מפת שם שירות → `Running` / `Stopped` / `Unknown`.
  Map<String, String> _serviceStates = {};

  LocalMaintenanceForensicSnapshot? _forensic;

  /// Forensic triplet: [LocalMaintenanceService.fetchForensicSnapshot] (IPC or silent local PS).
  bool _forensicLoading = true;
  String? _forensicError;

  /// Watchdog: [LocalMaintenanceService.fetchPrintSpoolerStatus] (no UAC on poll).
  bool _watchdogLoading = true;
  String? _watchdogError;

  /// Network: [LocalMaintenanceService.getNetworkAdapterByteCounters] (no UAC on poll).
  bool _netLoading = true;
  String? _netError;

  /// סכום ↓+↑ מאז תחילת היום המקומי (לפי דגימה ראשונה ביום ב-SeeDesktop; לא זהה ל-Windows Settings).
  int? _netDailyBytes;

  /// Extended audit (RAM slots, MAC, ARP, AV, SMB, printers, USB).
  LocalMaintenanceAuditSnapshot? _audit;
  bool _auditLoading = true;
  String? _auditError;

  /// Windows Experience Index / WinSAT performance scores.
  LocalMaintenanceWinSatSnapshot? _winSat;
  bool _winSatLoading = true;
  String? _winSatError;
  bool _staticRefreshBusy = false;

  String _licenseMaskedDisplay = '—';
  String _licenseStatusLine = '';
  bool _licenseBusy = false;

  /// `null` עד לטעינה ראשונה — כלי Pro בסרגל «פעולות מערכת» (כולל טרמינל SYSTEM) רק עם Pro.
  bool? _sidebarProOk;

  /// רישיון Pro פעיל — קוביות וכלי סרגל (חוץ מכרטיס רישיון).
  bool get _lmProOk => _sidebarProOk == true;

  /// כותרת שורה בראש כל קוביית מדד בגריד.
  double _lmCubeTitlePx = 15;

  /// בסיס לטקסט פנימי בקוביות; גדלים היסטוריים (8.5, 9.5, 17…) מוכפלים ב־[inner/10].
  double _lmCubeInnerPx = 14;

  /// בסיס לטקסט בכפתורי סרגל «פעולות מערכת» (מוכפל ב־[/10] כמו הקוביות).
  double _lmActionInnerPx = 12.5;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _tick();
      _poll = Timer.periodic(const Duration(seconds: 4), (_) => _tick());
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) _maybeUacFallbackSnack();
        await _refreshSidebarProGate();
        await _loadLmCubeFontPrefs();
        await _loadWatchdogPrefs();
        if (!mounted) return;
        setState(() {});
        await _maybeLoadStaticCacheOrRefresh();
        if (!mounted) return;
        await _refreshWatchdogServices();
        if (!mounted) return;
        unawaited(_loadLicenseCardData());
        _watchdogTimer = Timer.periodic(
          const Duration(minutes: 1),
          (_) => unawaited(_watchdogTick()),
        );
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _watchdogTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadWatchdogPrefs() async {
    if (kIsWeb) return;
    try {
      final p = await SharedPreferences.getInstance();
      _watchdogPaused = p.getBool(_kPrefWatchdogPaused) ?? false;
      final raw = p.getString(_kPrefWatchdogServices);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        final names = list
            .map((e) => e.toString().trim())
            .where(LocalMaintenanceService.isValidWatchdogServiceName)
            .toList();
        if (names.isNotEmpty) {
          final seen = <String>{};
          final out = <String>[];
          for (final n in names) {
            final low = n.toLowerCase();
            if (seen.add(low)) {
              out.add(n);
            }
          }
          _watchdogServiceNames = out;
        }
      }
    } catch (_) {}
  }

  Future<void> _saveWatchdogPrefs() async {
    if (kIsWeb) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kPrefWatchdogServices, jsonEncode(_watchdogServiceNames));
      await p.setBool(_kPrefWatchdogPaused, _watchdogPaused);
    } catch (_) {}
  }

  Future<void> _watchdogTick() async {
    if (!mounted || kIsWeb || _watchdogServiceNames.isEmpty) {
      return;
    }
    await _refreshWatchdogServices();
    if (!mounted || _watchdogPaused) {
      return;
    }
    final stopped = _watchdogServiceNames.where((n) {
      final st = (_serviceStates[n] ?? '').toLowerCase();
      return st != 'running';
    }).toList();
    if (stopped.isEmpty) return;
    try {
      await LocalMaintenanceService.startWindowsServicesIfStopped(stopped);
      final uac =
          LocalMaintenanceService.takePendingUacFallbackCompletionHint();
      if (uac && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lm('lm-services-started-uac'),
              textDirection: lmDir,
            ),
          ),
        );
      }
    } catch (_) {}
    if (mounted) {
      await _refreshWatchdogServices();
    }
  }

  Future<void> _maybeLoadStaticCacheOrRefresh() async {
    if (kIsWeb) return;
    try {
      final p = await SharedPreferences.getInstance();
      final ms = p.getInt(_kPrefStaticBundleMs) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final forensicStr = p.getString(_kPrefCacheForensic);
      final auditStr = p.getString(_kPrefCacheAudit);
      final netStr = p.getString(_kPrefCacheNet);
      final winSatStr = p.getString(_kPrefCacheWinSat);
      if (ms > 0 &&
          now - ms < const Duration(hours: 24).inMilliseconds &&
          forensicStr != null &&
          auditStr != null &&
          winSatStr != null) {
        final f = LocalMaintenanceForensicSnapshot.fromJson(
          jsonDecode(forensicStr) as Map<String, dynamic>,
        );
        final a = LocalMaintenanceAuditSnapshot.fromJson(
          jsonDecode(auditStr) as Map<String, dynamic>,
        );
        final ws = LocalMaintenanceWinSatSnapshot.fromJson(
          jsonDecode(winSatStr) as Map<String, dynamic>,
        );
        int? nrx;
        int? ntx;
        double? nmbps;
        String? lip;
        String? pip;
        if (netStr != null) {
          final nm = jsonDecode(netStr) as Map<String, dynamic>;
          nrx = (nm['rx'] as num?)?.toInt();
          ntx = (nm['tx'] as num?)?.toInt();
          nmbps = (nm['mbps'] as num?)?.toDouble();
          final ls = nm['local_ipv4']?.toString().trim();
          final ps = nm['public_ip']?.toString().trim();
          if (ls != null && ls.isNotEmpty) lip = ls;
          if (ps != null && ps.isNotEmpty) pip = ps;
        }
        if (!mounted) return;
        setState(() {
          _forensic = f;
          _audit = a;
          _winSat = ws;
          _forensicLoading = false;
          _forensicError = null;
          _auditLoading = false;
          _auditError = null;
          _winSatLoading = false;
          _winSatError = null;
          _netRx = nrx;
          _netTx = ntx;
          _netMbps = nmbps;
          _netLocalIpv4 = lip;
          _netPublicIp = pip;
          _netLoading = false;
          _netError = null;
        });
        if (nrx != null && ntx != null) {
          unawaited(_updateNetDailyTracking(nrx, ntx));
        }
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _forensicLoading = true;
        _forensicError = null;
        _auditLoading = true;
        _auditError = null;
        _winSatLoading = true;
        _winSatError = null;
        _netLoading = true;
        _netError = null;
      });
    }
    await _refreshForensics();
    if (!mounted) return;
    await _refreshAudit();
    if (!mounted) return;
    await _refreshWinSat();
    if (!mounted) return;
    await _loadNetworkOnce();
    if (!mounted) return;
    await _persistStaticCache();
  }

  Future<void> _refreshStaticDashboardNow() async {
    if (kIsWeb || _staticRefreshBusy) return;
    if (mounted) {
      setState(() {
        _staticRefreshBusy = true;
        _forensicLoading = true;
        _forensicError = null;
        _auditLoading = true;
        _auditError = null;
        _winSatLoading = true;
        _winSatError = null;
        _netLoading = true;
        _netError = null;
      });
    }
    try {
      await _refreshForensics();
      if (!mounted) return;
      await _refreshAudit();
      if (!mounted) return;
      await _refreshWinSat();
      if (!mounted) return;
      await _loadNetworkOnce();
      if (!mounted) return;
      await _persistStaticCache();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            lm('lm-dashboard-refreshed'),
            textDirection: lmDir,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _staticRefreshBusy = false);
      }
    }
  }

  Future<void> _persistStaticCache() async {
    if (_forensicError != null || _auditError != null) return;
    if (_forensic == null || _audit == null) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kPrefCacheForensic, jsonEncode(_forensic!.toJson()));
      await p.setString(_kPrefCacheAudit, jsonEncode(_audit!.toJson()));
      if (_winSat != null && _winSatError == null) {
        await p.setString(_kPrefCacheWinSat, jsonEncode(_winSat!.toJson()));
      }
      await p.setString(
        _kPrefCacheNet,
        jsonEncode(<String, dynamic>{
          'rx': _netRx,
          'tx': _netTx,
          'mbps': _netMbps,
          'local_ipv4': _netLocalIpv4,
          'public_ip': _netPublicIp,
        }),
      );
      await p.setInt(
          _kPrefStaticBundleMs, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  Future<void> _refreshSidebarProGate() async {
    if (kIsWeb) {
      if (mounted) setState(() => _sidebarProOk = false);
      return;
    }
    try {
      final ok = await hasRmmLicenseLocal();
      if (mounted) setState(() => _sidebarProOk = ok);
    } catch (_) {
      if (mounted) setState(() => _sidebarProOk = false);
    }
  }

  Future<void> _loadLmCubeFontPrefs() async {
    if (kIsWeb) return;
    try {
      final p = await SharedPreferences.getInstance();
      final t = p.getDouble(_kPrefLmCubeTitlePx);
      final u = p.getDouble(_kPrefLmCubeInnerPx);
      final a = p.getDouble(_kPrefLmActionInnerPx);
      if (!mounted) return;
      setState(() {
        if (t != null && t >= 10 && t <= 28) _lmCubeTitlePx = t;
        if (u != null && u >= 9 && u <= 28) _lmCubeInnerPx = u;
        if (a != null && a >= 9 && a <= 28) _lmActionInnerPx = a;
      });
    } catch (_) {}
  }

  Future<void> _saveLmCubeFontPrefs() async {
    if (kIsWeb) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_kPrefLmCubeTitlePx, _lmCubeTitlePx);
      await p.setDouble(_kPrefLmCubeInnerPx, _lmCubeInnerPx);
      await p.setDouble(_kPrefLmActionInnerPx, _lmActionInnerPx);
    } catch (_) {}
  }

  TextStyle _lmCubeTitleStyle(ColorScheme cs) => TextStyle(
        fontSize: _lmCubeTitlePx,
        fontWeight: FontWeight.w800,
        color: cs.onSurfaceVariant,
      );

  /// גודל פנימי מחושב מיחס לעיצוב המקורי (בסיס 10 → ברירת 14 כש־designPx=10).
  double _lmInnerSize(double designPx) =>
      (designPx * _lmCubeInnerPx / 10.0).clamp(7.0, 32.0);

  double _lmActionInnerSize(double designPx) =>
      (designPx * _lmActionInnerPx / 10.0).clamp(7.0, 32.0);

  TextStyle _lmInnerTextStyle(
    ColorScheme cs,
    double designPx, {
    FontWeight fontWeight = FontWeight.w600,
    Color? color,
    double? height,
  }) =>
      TextStyle(
        fontSize: _lmInnerSize(designPx),
        fontWeight: fontWeight,
        color: color ?? cs.onSurface,
        height: height,
      );

  Future<void> _showLmCubeFontSettingsDialog(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return AlertDialog(
              title: Text(
                lm('lm-font-dialog-title'),
                textDirection: lmDir,
              ),
              content: SingleChildScrollView(
                child: Directionality(
                  textDirection: lmDir,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        lm('lm-font-cube-title'),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Slider(
                        value: _lmCubeTitlePx,
                        min: 11,
                        max: 24,
                        divisions: 26,
                        label: _lmCubeTitlePx.toStringAsFixed(0),
                        onChanged: (v) {
                          setLocal(() => _lmCubeTitlePx = v);
                          setState(() => _lmCubeTitlePx = v);
                          unawaited(_saveLmCubeFontPrefs());
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        lm('lm-font-cube-inner'),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Slider(
                        value: _lmCubeInnerPx,
                        min: 10,
                        max: 22,
                        divisions: 24,
                        label: _lmCubeInnerPx.toStringAsFixed(0),
                        onChanged: (v) {
                          setLocal(() => _lmCubeInnerPx = v);
                          setState(() => _lmCubeInnerPx = v);
                          unawaited(_saveLmCubeFontPrefs());
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        lm('lm-font-action-bar'),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Slider(
                        value: _lmActionInnerPx,
                        min: 10,
                        max: 22,
                        divisions: 24,
                        label: _lmActionInnerPx.toStringAsFixed(0),
                        onChanged: (v) {
                          setLocal(() => _lmActionInnerPx = v);
                          setState(() => _lmActionInnerPx = v);
                          unawaited(_saveLmCubeFontPrefs());
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(lm('lm-close'), style: TextStyle(color: cs.primary)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// כל כפתורי לוח הבקרה (סרגל «פעולות מערכת» + קוביות) — דורשים רישיון PRO-RMM.
  Future<bool> _ensureProForLocalDashboard(BuildContext context) async {
    if (kIsWeb) return false;
    try {
      final ok = await hasRmmLicenseLocal();
      if (mounted) setState(() => _sidebarProOk = ok);
      if (!ok && context.mounted) {
        await showRmmProGateDialog(context);
      }
      return ok;
    } catch (_) {
      if (mounted) setState(() => _sidebarProOk = false);
      if (context.mounted) await showRmmProGateDialog(context);
      return false;
    }
  }

  Future<void> _loadLicenseCardData() async {
    if (kIsWeb) return;
    try {
      final key = await getSavedLicenseKey();
      final masked =
          (key == null || key.trim().isEmpty) ? '—' : maskLicense(key.trim());
      final status = await getLicenseStatusDisplayTextLocal();
      final line = licenseStatusWithoutWebsiteSuffix(status);
      if (!mounted) return;
      setState(() {
        _licenseMaskedDisplay = masked;
        _licenseStatusLine = line;
      });
    } catch (_) {}
  }

  Future<void> _syncLicenseWithServer() async {
    if (_licenseBusy) return;
    setState(() => _licenseBusy = true);
    try {
      final key = (await getSavedLicenseKey())?.trim() ?? '';
      if (key.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                lm('lm-license-no-key'),
                textDirection: lmDir,
              ),
            ),
          );
        }
        return;
      }
      final r = await verifyLicenseWithServer(key);
      if (!mounted) return;
      await _loadLicenseCardData();
      await _refreshSidebarProGate();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            r.approved
                ? lm('lm-license-verified')
                : (r.message.isNotEmpty ? r.message : lm('lm-license-verify-failed')),
            textDirection: lmDir,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${lm('lm-error-prefix')} $e', textDirection: lmDir),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _licenseBusy = false);
    }
  }

  void _openLicenseSettings() {
    DesktopSettingPage.switch2page(SettingsTabKey.license);
  }

  /// After explicit actions ([LocalMaintenanceService] UAC fallback), show once.
  void _maybeUacFallbackSnack() {
    if (!mounted) return;
    if (!LocalMaintenanceService.takePendingUacFallbackCompletionHint()) return;
    ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
        content: Text(
          lm('lm-done-after-uac'),
          textDirection: lmDir,
        ),
      ),
    );
  }

  Future<void> _refreshAudit() async {
    if (kIsWeb) return;
    if (mounted) {
      setState(() {
        _auditLoading = true;
        _auditError = null;
      });
    }
    try {
      final a = await LocalMaintenanceService.fetchAuditSnapshot();
      if (!mounted) return;
      setState(() {
        _audit = a;
        _auditLoading = false;
        _auditError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _auditLoading = false;
        _auditError = LocalMaintenanceService.isRequiresAdminDataError(e)
            ? lm('lm-needs-admin-service')
            : e.toString();
        _audit = LocalMaintenanceAuditSnapshot.empty();
      });
    }
  }

  Future<void> _refreshForensics() async {
    if (kIsWeb) return;
    if (mounted) {
      setState(() {
        _forensicLoading = true;
        _forensicError = null;
      });
    }
    try {
      final s = await LocalMaintenanceService.fetchForensicSnapshot();
      if (!mounted) return;
      setState(() {
        _forensic = s;
        _forensicLoading = false;
        _forensicError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _forensicLoading = false;
        _forensicError = LocalMaintenanceService.isRequiresAdminDataError(e)
            ? lm('lm-needs-admin-service')
            : e.toString();
      });
    }
  }

  Future<void> _refreshWinSat() async {
    if (kIsWeb) return;
    if (mounted) {
      setState(() {
        _winSatLoading = true;
        _winSatError = null;
      });
    }
    try {
      final s = await LocalMaintenanceService.fetchWinSatSnapshot();
      if (!mounted) return;
      setState(() {
        _winSat = s;
        _winSatLoading = false;
        _winSatError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _winSatLoading = false;
        _winSatError = LocalMaintenanceService.isRequiresAdminDataError(e)
            ? lm('lm-needs-admin-service')
            : e.toString();
      });
    }
  }

  Future<void> _openAiAdviceDialog(List<String> lines) async {
    if (!mounted) return;
    if (!await _ensureProForLocalDashboard(context)) return;
    if (lines.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(
            lm('lm-ai-advice-title'),
            textDirection: lmDir,
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: lines
                  .map(
                    (s) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        s,
                        textDirection: lmDir,
                        style: const TextStyle(height: 1.35),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(lm('lm-close-alt'), style: TextStyle(color: cs.primary)),
            ),
          ],
        );
      },
    );
  }

  void _tick() {
    if (kIsWeb) return;
    try {
      final map = jsonDecode(bind.mainGetSysMetrics()) as Map<String, dynamic>;
      final cpu = (map['cpu'] as num?)?.toDouble();
      final ru = (map['ram_used_gb'] as num?)?.toDouble();
      final rt = (map['ram_total_gb'] as num?)?.toDouble();
      final hw = map['hw_health'] as Map<String, dynamic>?;

      double? ramPct;
      if (ru != null && rt != null && rt > 0) {
        ramPct = (ru / rt * 100).clamp(0.0, 100.0);
      }

      String os = '—';
      try {
        os = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
      } catch (_) {}

      String cpuLine = '—';
      if (hw != null) {
        final cm = hw['cpu_model']?.toString().trim();
        final cn = hw['cpu_name']?.toString().trim();
        if (cm != null && cm.isNotEmpty && cm.toLowerCase() != 'unknown') {
          cpuLine = cm;
        } else if (cn != null && cn.isNotEmpty) {
          cpuLine = cn;
        }
      }

      if (!mounted) return;
      setState(() {
        _cpu = cpu;
        _ramUsedPct = ramPct;
        _ramUsedGb = ru;
        _ramTotalGb = rt;
        _osLine = os;
        _cpuModelLine = cpuLine;
        _hw = hw;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _cpu = null;
          _ramUsedPct = null;
          _ramUsedGb = null;
          _ramTotalGb = null;
          _hw = null;
        });
      }
    }
  }

  Future<void> _refreshWatchdogServices() async {
    if (kIsWeb) return;
    if (mounted) {
      setState(() {
        _watchdogError = null;
      });
    }
    if (_watchdogServiceNames.isEmpty) {
      if (mounted) {
        setState(() {
          _serviceStates = {};
          _watchdogLoading = false;
          _watchdogError = null;
        });
      }
      return;
    }
    try {
      final m = await LocalMaintenanceService.fetchWindowsServicesStatusBatch(
        _watchdogServiceNames,
      );
      if (!mounted) return;
      setState(() {
        _serviceStates = m;
        _watchdogLoading = false;
        _watchdogError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serviceStates = {};
        _watchdogLoading = false;
        _watchdogError = LocalMaintenanceService.isRequiresAdminDataError(e)
            ? lm('lm-needs-admin-service')
            : e.toString();
      });
    }
  }

  Future<void> _onStartStoppedWatchdogServices() async {
    if (_busyWatchdogManualStart) return;
    if (!await _ensureProForLocalDashboard(context)) return;
    setState(() => _busyWatchdogManualStart = true);
    try {
      final stopped = _watchdogServiceNames.where((n) {
        final st = (_serviceStates[n] ?? '').toLowerCase();
        return st != 'running';
      }).toList();
      if (stopped.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                lm('lm-all-services-running'),
                textDirection: lmDir,
              ),
            ),
          );
        }
        return;
      }
      await LocalMaintenanceService.startWindowsServicesIfStopped(stopped);
      if (!mounted) return;
      final uac =
          LocalMaintenanceService.takePendingUacFallbackCompletionHint();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            uac
                ? lm('lm-done-after-uac')
                : lm('lm-start-stopped-requested'),
            textDirection: lmDir,
          ),
        ),
      );
      await _refreshWatchdogServices();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${lm('lm-error-prefix')} $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyWatchdogManualStart = false);
    }
  }

  Future<void> _addWatchdogService(String name) async {
    if (!_lmProOk) return;
    final t = name.trim();
    if (!LocalMaintenanceService.isValidWatchdogServiceName(t)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lm('lm-invalid-service-name'),
              textDirection: lmDir,
            ),
          ),
        );
      }
      return;
    }
    final low = t.toLowerCase();
    if (_watchdogServiceNames.any((x) => x.toLowerCase() == low)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lm('lm-service-already-listed'),
              textDirection: lmDir,
            ),
          ),
        );
      }
      return;
    }
    setState(() {
      _watchdogServiceNames = [..._watchdogServiceNames, t];
      _watchdogLoading = true;
    });
    await _saveWatchdogPrefs();
    await _refreshWatchdogServices();
  }

  Future<void> _removeWatchdogService(String name) async {
    if (!await _ensureProForLocalDashboard(context)) return;
    setState(() {
      _watchdogServiceNames =
          _watchdogServiceNames.where((n) => n != name).toList();
      _serviceStates.remove(name);
    });
    await _saveWatchdogPrefs();
    await _refreshWatchdogServices();
  }

  Future<void> _setWatchdogPaused(bool v) async {
    if (!_lmProOk) return;
    setState(() => _watchdogPaused = v);
    await _saveWatchdogPrefs();
    if (!v && mounted) {
      unawaited(_watchdogTick());
    }
  }

  ({Color color, String label}) _watchdogStatusChip(String? raw) {
    final s = (raw ?? '').trim().toLowerCase();
    if (s == 'running') {
      return (color: Colors.green, label: lm('lm-status-running'));
    }
    if (s == 'stopped') {
      return (color: Colors.orange, label: lm('lm-status-stopped'));
    }
    if (s == 'unknown') {
      return (color: Colors.blueGrey, label: lm('lm-status-unknown'));
    }
    final t = (raw ?? '').trim();
    if (t.isEmpty) {
      return (color: Colors.blueGrey, label: '—');
    }
    return (
      color: Colors.blueGrey,
      label: t.length > 12 ? '${t.substring(0, 12)}…' : t,
    );
  }

  void _showAddWatchdogServiceDialog() {
    if (!_lmProOk) return;
    final c = TextEditingController();
    showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          lm('lm-add-service-title'),
          textDirection: lmDir,
        ),
        content: TextField(
          controller: c,
          autofocus: true,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(
            hintText: lm('lm-add-service-hint'),
            isDense: true,
          ),
          onSubmitted: (s) => Navigator.pop(ctx, s.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(lm('lm-cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(lm('lm-add')),
          ),
        ],
      ),
    ).then((v) async {
      c.dispose();
      if (v == null || v.isEmpty) return;
      await _addWatchdogService(v);
    });
  }

  Future<void> _refreshNetworkEndpointIps() async {
    if (kIsWeb) return;
    try {
      final ips = await LocalMaintenanceService.fetchNetworkEndpointIps();
      if (!mounted) return;
      setState(() {
        _netLocalIpv4 = ips.localIpv4;
        _netPublicIp = ips.publicIp;
      });
    } catch (_) {}
  }

  /// דגימה כפולה (מרווח ~שנייה) לחישוב Mbps — פעם אחת בכניסה ללוח.
  Future<void> _loadNetworkOnce() async {
    if (kIsWeb) return;
    if (mounted) {
      setState(() {
        _netLoading = true;
        _netError = null;
      });
    }
    try {
      final t0 = DateTime.now();
      final n1 = await LocalMaintenanceService.getNetworkAdapterByteCounters();
      await Future<void>.delayed(const Duration(seconds: 1));
      final t1 = DateTime.now();
      final n2 = await LocalMaintenanceService.getNetworkAdapterByteCounters();
      if (!mounted) return;
      setState(() {
        _prevNetAt = t0;
        _prevNetRx = n1.rx;
        _prevNetTx = n1.tx;
        _applyNetworkSample(n2.rx, n2.tx, t1);
        _netLoading = false;
        _netError = null;
      });
      await _refreshNetworkEndpointIps();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _netRx = null;
        _netTx = null;
        _netMbps = null;
        _netLoading = false;
        _netError = LocalMaintenanceService.isRequiresAdminDataError(e)
            ? lm('lm-needs-admin-service')
            : e.toString();
      });
      await _refreshNetworkEndpointIps();
    }
  }

  void _applyNetworkSample(int rx, int tx, DateTime now) {
    _netRx = rx;
    _netTx = tx;
    if (_prevNetAt != null && _prevNetRx != null && _prevNetTx != null) {
      final dt = now.difference(_prevNetAt!).inMilliseconds / 1000.0;
      if (dt >= 0.25) {
        final dr = rx - _prevNetRx!;
        final dtx = tx - _prevNetTx!;
        final dBytes = dr + dtx;
        if (dBytes >= 0 && dt > 0) {
          _netMbps = (dBytes * 8) / (dt * 1000000);
        }
      }
    }
    _prevNetRx = rx;
    _prevNetTx = tx;
    _prevNetAt = now;
    unawaited(_updateNetDailyTracking(rx, tx));
  }

  Future<void> _updateNetDailyTracking(int rx, int tx) async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final d = DateTime.now();
      final dayKey =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final savedDay = prefs.getString(_kPrefNetDailyDate);
      final baseRx = prefs.getInt(_kPrefNetDailyBaseRx);
      final baseTx = prefs.getInt(_kPrefNetDailyBaseTx);

      int daily;
      if (savedDay != dayKey) {
        await prefs.setString(_kPrefNetDailyDate, dayKey);
        await prefs.setInt(_kPrefNetDailyBaseRx, rx);
        await prefs.setInt(_kPrefNetDailyBaseTx, tx);
        daily = 0;
      } else if (baseRx == null || baseTx == null) {
        await prefs.setInt(_kPrefNetDailyBaseRx, rx);
        await prefs.setInt(_kPrefNetDailyBaseTx, tx);
        daily = 0;
      } else if (rx < baseRx || tx < baseTx) {
        await prefs.setInt(_kPrefNetDailyBaseRx, rx);
        await prefs.setInt(_kPrefNetDailyBaseTx, tx);
        daily = 0;
      } else {
        daily = rx + tx - baseRx - baseTx;
        if (daily < 0) daily = 0;
      }

      if (!mounted) return;
      setState(() => _netDailyBytes = daily);
    } catch (_) {}
  }

  Future<void> _openWindowsDataUsageSettings() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      await LocalMaintenanceService.openWindowsDataUsageSettings();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${lm('lm-open-storage-failed-prefix')} $e',
            textDirection: lmDir,
          ),
        ),
      );
    }
  }

  Future<void> _openNetworkConnectionsClassic() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      await LocalMaintenanceService.openWindowsNetworkConnectionsNcpa();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${lm('lm-open-network-failed-prefix')} $e',
            textDirection: lmDir,
          ),
        ),
      );
    }
  }

  Future<void> _openWindowsPrintersFolder() async {
    if (kIsWeb || !Platform.isWindows) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
        content: Text(
          lm('lm-opening-printers'),
          textDirection: lmDir,
        ),
        duration: Duration(seconds: 2),
      ),
    );
    try {
      await LocalMaintenanceService.openWindowsPrintersFolder();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${lm('lm-open-printers-failed-prefix')} $e',
            textDirection: lmDir,
          ),
        ),
      );
    }
  }

  Future<void> _openRealTimeLoadDiagnostic(
      {_LmRtLoadMode mode = _LmRtLoadMode.full}) async {
    if (!mounted) return;
    if (!await _ensureProForLocalDashboard(context)) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _LmRealTimeLoadAlert(mode: mode),
    );
  }

  Future<void> _openDiskStorageSenseFromInfo() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
        content: Text(
          lm('lm-opening-storage'),
          textDirection: lmDir,
        ),
        duration: Duration(seconds: 2),
      ),
    );
    try {
      await LocalMaintenanceService.openWindowsStorageSenseSettings();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${lm('lm-open-settings-failed-prefix')} $e',
            textDirection: lmDir,
          ),
        ),
      );
    }
  }

  Future<void> _openApplicationErrorsLast5Dialog() async {
    if (!mounted) return;
    if (!await _ensureProForLocalDashboard(context)) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => const _LmAppErrorsAlert(),
    );
  }

  Future<void> _openUnexpectedShutdownsLast5Dialog() async {
    if (!mounted) return;
    if (!await _ensureProForLocalDashboard(context)) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => const _LmUnexpectedShutdownsAlert(),
    );
  }

  ({Color color, String label}) _cpuHealth() {
    final v = _cpu ?? 0;
    if (v > 85) return (color: Colors.red, label: lm('lm-status-cpu-critical'));
    if (v > 70) return (color: Colors.orange, label: lm('lm-status-cpu-medium'));
    return (color: Colors.green, label: lm('lm-status-ok'));
  }

  ({Color color, String label}) _ramHealth() {
    final v = _ramUsedPct ?? 0;
    if (v > 85) return (color: Colors.red, label: lm('lm-status-ram-low'));
    if (v > 75) return (color: Colors.orange, label: lm('lm-status-ram-high'));
    return (color: Colors.green, label: lm('lm-status-ok'));
  }

  bool _cpuNeedsAi() {
    if ((_cpu ?? 0) > 85) return true;
    final ts = _hw?['temp_status']?.toString();
    return ts == 'yellow' || ts == 'red';
  }

  bool _ramNeedsAi() => (_ramUsedPct ?? 0) > 85;

  bool _watchdogNeedsAi() {
    for (final n in _watchdogServiceNames) {
      final st = (_serviceStates[n] ?? '').trim().toLowerCase();
      if (st.isEmpty) continue;
      if (st != 'running') return true;
    }
    return false;
  }

  bool _diskNeedsAi(String? health, double? usedPct) {
    if (usedPct != null && usedPct > 90) return true;
    return health == 'yellow' || health == 'red';
  }

  List<String> _hintsCpu() {
    final lines = <String>[];
    if ((_cpu ?? 0) >= 85) {
      lines.addAll(const [
        '1. סגרו אפליקציות כבדות (דפדפן, משחקים, קידוד וידאו).',
        '2. בדקו תוכנות בהפעלה (Task Manager → Startup).',
        '3. עדכנו BIOS/צ׳יפסט ודרייברי מעבד; נטרו חימום.',
      ]);
    }
    final ts = _hw?['temp_status']?.toString();
    if (ts == 'yellow' || ts == 'red') {
      lines.addAll(const [
        '1. נקו אבק ממאווררים ובדקו זרימת אוויר.',
        '2. החליפו משחה תרמית במידת הצורך.',
        '3. ודאו שמצב החשמל/ביצועים ב-Windows מתאים לעומס.',
      ]);
    }
    return lines;
  }

  List<String> _hintsRam() => const [
        '1. סגרו כרטיסיות דפדפן ואפליקציות מיותרות.',
        '2. הגדירו קובץ דיסק (page file) אוטומטי או הוסיפו RAM פיזית.',
        '3. בדקו דליפות זיכרון בתוכנות ספציפיות ב-Resource Monitor.',
      ];

  List<String> _hintsDisk() => const [
        '1. הריצו ניקוי מערכת מתקדם מהסרגל הצדדי.',
        '2. השתמשו ב-TreeSize / WinDirStat לאיתור קבצים גדולים.',
        '3. רוקנו את סל המחזור והעבירו נתונים לכונן חיצוני.',
      ];

  List<String> _hintsStability() => const [
        '1. עדכנו דרייברים של GPU ורשת.',
        '2. הריצו בדיקת זיכרון (MemTest / אבחון זיכרון של Windows).',
        '3. נתחו minidumps עם BlueScreenView או WinDbg.',
      ];

  /// [crashCount] — last 30 days Application Error 1000.
  List<String> _hintsAppHealthFor(int crashCount) {
    if (crashCount > 10) {
      return const [
        '1. יש ריבוי קריסות — זההו את האפליקציה השכיחה (שורה "תדיר ביותר") ועדכנו/התקינו מחדש.',
        '2. בדקו .NET / Visual C++ Redistributables ועדכוני Windows.',
        '3. סקרו Event Viewer (1000) והריצו את האפליקציה כמנהל אם נדרש.',
        '4. השביתו תוספים או הרצה ב-Safe Mode לבידוד בעיה.',
      ];
    }
    return const [
      '1. עדכנו את האפליקציה הבעייתית והתקינו מחדש במידת הצורך.',
      '2. בדקו תאימות Windows / .NET / Visual C++ Redistributables.',
      '3. השביתו תוספים/הרחבות אם מדובר בדפדפן או IDE.',
    ];
  }

  List<String> _hintsAppHealth() =>
      _hintsAppHealthFor(_forensic?.appError1000 ?? 0);

  List<String> _hintsWatchdog() => const [
        '1. פתחו services.msc וודאו שהשירותים ברשימה מוגדרים ל"אוטומטי" או "ידני" לפי הצורך.',
        '2. אם שירות נופל — בדקו הרשאות מנהל; ניתן להפעיל ידנית מכפתור lm("lm-start-stopped-services").',
        '3. ל-Print Spooler: נקו תור (עצירת Spooler, ריקון spool\\PRINTERS, הפעלה מחדש).',
      ];

  List<String> _hintsSecurity() => const [
        '1. בדקו אם RDP (פורט 3389) חשוף לאינטרנט — הגבילו ב-Firewall/VPN.',
        '2. חזקו מדיניות נעילת חשבון (Account Lockout).',
        '3. החליפו סיסמת מנהל מערכת; הפעילו MFA אם רלוונטי.',
      ];

  List<String> _hintsSecureBoot() => const [
        '1. Secure Boot כבוי — היכנסו ל-BIOS/UEFI והפעילו Secure Boot כדי להקשות על bootkits.',
        '2. ודאו שהדיסק מעוצב ב-GPT (ולא MBR) אם נדרש ל-Secure Boot.',
      ];

  List<String> _hintsAntivirus() => const [
        '1. ייתכן שאין אנטי-וירוס פעיל או ש-Windows Defender אינו מדווח — בדקו את Windows Security.',
        '2. ודאו שהמוצר מעודכן ושהגנה בזמן אמת פועלת.',
      ];

  bool _secureBootNeedsAi() =>
      (_audit?.secureBoot ?? '').trim().toLowerCase() == 'off';

  bool _antivirusNeedsAi() {
    final a = (_audit?.antivirusName ?? '').trim();
    if (a.isEmpty) return true;
    return !a.toLowerCase().contains('windows defender');
  }

  List<String> _hintsSecurityCombined() {
    final lines = <String>[];
    final fl = _forensic?.failedLogon4625 ?? -1;
    if (fl > 0) {
      lines.addAll(_hintsSecurity());
    }
    if (_antivirusNeedsAi()) {
      lines.addAll(_hintsAntivirus());
    }
    if (lines.isEmpty) {
      lines.addAll(_hintsSecurity());
    }
    return lines;
  }

  String _formatRamSlotLine(({String label, int capacityMb}) s) {
    final cap = s.capacityMb <= 0
        ? '—'
        : (s.capacityMb >= 1024
            ? '${(s.capacityMb / 1024).toStringAsFixed(0)} GB'
            : '${s.capacityMb} MB');
    final lab = s.label.trim().isEmpty ? lm('lm-module') : s.label;
    return '$lab: $cap';
  }

  void _showArpDialog(BuildContext context) {
    final a = _audit;
    final rows = a?.arpNeighbors ?? [];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          lm('lm-arp-dialog-title'),
          textDirection: lmDir,
        ),
        content: SizedBox(
          width: 520,
          height: 400,
          child: rows.isEmpty
              ? Text(
                  lm('lm-no-data'),
                  textDirection: lmDir,
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SelectableText(
                        '${r.ip}  ·  ${r.name}  ·  ${r.mac}',
                        style:
                            TextStyle(fontSize: _lmInnerSize(11), height: 1.25),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(lm('lm-close-alt')),
          ),
        ],
      ),
    );
  }

  void _showLocalUsersDialog(BuildContext context) {
    final a = _audit;
    final rows = a?.localUsers ?? [];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          lm('lm-local-users-title'),
          textDirection: lmDir,
        ),
        content: SizedBox(
          width: 480,
          height: 400,
          child: rows.isEmpty
              ? Text(
                  lm('lm-no-data'),
                  textDirection: lmDir,
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final en = r.enabled ? lm('lm-user-enabled') : lm('lm-user-disabled');
                    final ll = r.lastLogon.isEmpty ? '—' : r.lastLogon;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(
                        '${r.name}  ·  $en${lm('lm-last-logon-inline')} $ll',
                        style:
                            TextStyle(fontSize: _lmInnerSize(11), height: 1.25),
                        textDirection: lmDir,
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(lm('lm-close-alt')),
          ),
        ],
      ),
    );
  }

  void _showPrintersDialog(BuildContext context) {
    final a = _audit;
    final rows = a?.printers ?? [];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          lm('lm-printers-ports-title'),
          textDirection: lmDir,
        ),
        content: SizedBox(
          width: 480,
          height: 360,
          child: rows.isEmpty
              ? Text(
                  lm('lm-no-data'),
                  textDirection: lmDir,
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(
                        '${r.name}${lm('lm-port-inline')} ${r.port}',
                        style:
                            TextStyle(fontSize: _lmInnerSize(11), height: 1.25),
                        textDirection: lmDir,
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(lm('lm-close-alt')),
          ),
        ],
      ),
    );
  }

  ({Color color, String label}) _tempHealth() {
    final s = _hw?['temp_status']?.toString();
    switch (s) {
      case 'green':
        return (color: Colors.green, label: lm('lm-status-ok'));
      case 'yellow':
        return (color: Colors.orange, label: lm('lm-status-warm'));
      case 'red':
        return (color: Colors.red, label: lm('lm-status-hot'));
      default:
        return (color: Colors.blueGrey, label: lm('lm-status-unavailable'));
    }
  }

  String _diskHebrew(String? health) {
    switch (health) {
      case 'green':
        return lm('lm-status-ok');
      case 'yellow':
        return lm('lm-disk-space-low');
      case 'red':
        return lm('lm-disk-space-limited');
      default:
        return '—';
    }
  }

  Color _diskColor(String? health) {
    switch (health) {
      case 'green':
        return Colors.green;
      case 'yellow':
        return Colors.orange;
      case 'red':
        return Colors.red;
      default:
        return Colors.blueGrey;
    }
  }

  Color _diskSmartColor(String status) {
    final s = status.toLowerCase();
    if (s.contains('ok') || s.contains('healthy')) return Colors.green;
    if (s.contains('warn') || s.contains('caution') || s.contains('predict')) {
      return Colors.orange;
    }
    if (s.contains('bad') || s.contains('fail') || s.contains('unhealthy')) {
      return Colors.red;
    }
    return Colors.blueGrey;
  }

  double _responsiveSidebarWidth(double availableWidth) {
    if (availableWidth >= 1100) return _kSidebarWidth;
    if (availableWidth >= 900) return 216;
    return 196;
  }

  int _dashboardColumnCount(double width) {
    if (width < 420) return 1;
    final minCell = width < 900 ? 210.0 : 188.0;
    return (width / minCell).floor().clamp(1, 6).toInt();
  }

  double _dashboardCardExtent(double gridWidth, int columns) {
    const spacing = 8.0;
    final cellWidth = (gridWidth - spacing * (columns - 1)) / columns;
    if (cellWidth < 190) return 238;
    if (cellWidth < 230) return 222;
    if (cellWidth < 280) return 204;
    return 188;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final copper = kLocalMaintenanceCopper;

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            lm('lm-windows-only'),
            textDirection: lmDir,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    final tempC = (_hw?['cpu_temp_c'] as num?)?.toDouble();
    final disksRaw = _hw?['disks'];
    final diskList = disksRaw is List ? disksRaw : const <dynamic>[];

    final cpuAi = _cpuNeedsAi();
    final ramAi = _ramNeedsAi();
    final wdAi = _watchdogNeedsAi();

    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: cs.copyWith(
          primary: copper,
          secondary: kLocalMaintenanceCopperDim,
        ),
      ),
      child: ColoredBox(
        color: cs.surface,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < _kCompactRmmBreakpoint;
            final sidebar = _buildLeftActionSidebar(context);
            final dashboard = _buildResponsiveDashboardGrid(
              context,
              copper: copper,
              cs: cs,
              tempC: tempC,
              diskList: diskList,
              cpuAi: cpuAi,
              ramAi: ramAi,
              wdAi: wdAi,
            );

            return Directionality(
              textDirection: TextDirection.ltr,
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: constraints.maxHeight < 620 ? 148 : 196,
                          child: sidebar,
                        ),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: copper.withOpacity(0.35),
                        ),
                        Expanded(child: dashboard),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: _responsiveSidebarWidth(constraints.maxWidth),
                          child: sidebar,
                        ),
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: copper.withOpacity(0.35),
                        ),
                        Expanded(child: dashboard),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildResponsiveDashboardGrid(
    BuildContext context, {
    required Color copper,
    required ColorScheme cs,
    required double? tempC,
    required List<dynamic> diskList,
    required bool cpuAi,
    required bool ramAi,
    required bool wdAi,
  }) {
    return Directionality(
      textDirection: lmDir,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final innerW = constraints.maxWidth;
          final cc = _dashboardColumnCount(innerW);
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        lm('lm-dashboard-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: innerW < 420 ? 12.5 : 14,
                          fontWeight: FontWeight.w800,
                          color: copper,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: _staticRefreshBusy
                          ? lm('lm-refresh-busy')
                          : lm('lm-refresh-dashboard-tip'),
                      icon: _staticRefreshBusy
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: copper.withOpacity(0.9),
                              ),
                            )
                          : Icon(
                              Icons.refresh_rounded,
                              size: 20,
                              color: copper.withOpacity(0.9),
                            ),
                      onPressed: _staticRefreshBusy
                          ? null
                          : () => unawaited(_refreshStaticDashboardNow()),
                    ),
                    IconButton(
                      tooltip: _lmProOk
                          ? lm('lm-font-settings-tip')
                          : lm('lm-font-settings-pro-tip'),
                      icon: Icon(
                        Icons.tune,
                        size: 20,
                        color: _lmProOk
                            ? copper.withOpacity(0.9)
                            : cs.onSurfaceVariant.withOpacity(0.35),
                      ),
                      onPressed: _lmProOk
                          ? () => _showLmCubeFontSettingsDialog(context)
                          : null,
                    ),
                    const ItTroubleshootingChatIfRmm(
                      panelBelowTrigger: true,
                      compactTrigger: true,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _osLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _lmInnerTextStyle(
                    cs,
                    10,
                    fontWeight: FontWeight.w400,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: GridView(
                    padding: EdgeInsets.zero,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cc,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      mainAxisExtent: _dashboardCardExtent(innerW, cc),
                    ),
                    children: [
                      _winSatPerformanceCard(context),
                      _cpuCombinedCard(
                        context,
                        cpuModel: _cpuModelLine,
                        cpuPct: _cpu,
                        tempC: tempC,
                        showAi: _lmProOk && cpuAi,
                        onAiTap: _lmProOk && cpuAi
                            ? () => _openAiAdviceDialog(_hintsCpu())
                            : null,
                      ),
                      _auditSystemMotherboardCard(context),
                      _ramCard(
                        context,
                        pct: _ramUsedPct,
                        ramSlots: _audit?.ramSlots,
                        auditLoading: _auditLoading,
                        showAi: _lmProOk && ramAi,
                        onAiTap: _lmProOk && ramAi
                            ? () => _openAiAdviceDialog(_hintsRam())
                            : null,
                      ),
                      _diskOverviewCard(context, diskList),
                      _auditGpuCard(context),
                      _multimediaCard(context),
                      _networkCard(context),
                      _microsoftSoftwareCard(context),
                      _osSystemCard(context),
                      _watchdogCard(
                        context,
                        showAi: _lmProOk && wdAi,
                        onAiTap: _lmProOk && wdAi
                            ? () => _openAiAdviceDialog(_hintsWatchdog())
                            : null,
                      ),
                      _forensicStabilityCard(context),
                      _forensicAppHealthCard(context),
                      _forensicSecurityCard(context),
                      _auditPrintersCard(context),
                      _seedesktopLicenseCard(context),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Physically **left**; content RTL for labels.
  Widget _buildLeftActionSidebar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withOpacity(0.92),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Directionality(
          textDirection: lmDir,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    lm('lm-system-actions'),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: _lmActionInnerSize(12),
                      fontWeight: FontWeight.w800,
                      color: kLocalMaintenanceCopper,
                      letterSpacing: 0.3,
                    ),
                  ),
                  if (!_lmProOk) ...[
                    const SizedBox(height: 3),
                    Text(
                      lm('lm-pro-only-hint'),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: _lmActionInnerSize(8.5),
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    _lmProOk
                        ? lm('lm-pro-active-hint')
                        : lm('lm-pro-required-hint'),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: _lmActionInnerSize(9),
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: _lmProOk
                          ? cs.onSurfaceVariant.withOpacity(0.85)
                          : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_lmProOk) ...[
                        _sidebarActionButton(
                          context,
                          label: lm('lm-action-cleanup'),
                          icon: Icons.cleaning_services_rounded,
                          tooltip: lm('lm-action-cleanup-tip'),
                          busy: false,
                          requiresProLicense: true,
                          onPressed: () => unawaited(
                            openSeeDesktopCleanupLocally(context),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _sidebarActionButton(
                          context,
                          label: lm('lm-action-disk-check'),
                          icon: Icons.storage_rounded,
                          tooltip:
                              lm('lm-action-disk-check-tip'),
                          busy: false,
                          requiresProLicense: true,
                          onPressed: () => unawaited(
                            openSeeDesktopBundledToolLocally(
                              context,
                              'SeeDesktopDiskCheck.exe',
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _sidebarActionButton(
                          context,
                          label: lm('lm-action-sfc-dism'),
                          icon: Icons.build_circle_outlined,
                          tooltip:
                              lm('lm-action-sfc-dism-tip'),
                          busy: false,
                          requiresProLicense: true,
                          onPressed: () => unawaited(
                            openSeeDesktopBundledToolLocally(
                              context,
                              'SeeDesktopSystemRepair.exe',
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _sidebarActionButton(
                          context,
                          label: lm('lm-action-ram-test'),
                          icon: Icons.memory_rounded,
                          tooltip:
                              lm('lm-action-ram-test-tip'),
                          busy: false,
                          requiresProLicense: true,
                          onPressed: () =>
                              unawaited(_launchWindowsMemoryTest()),
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kLocalMaintenanceCopper,
                            foregroundColor: cs.onPrimary,
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 8,
                            ),
                            elevation: 4,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.speed_rounded, size: 22),
                          label: Text(
                            lm('lm-action-load-analysis'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: _lmActionInnerSize(12.5),
                              height: 1.15,
                            ),
                          ),
                          onPressed: () =>
                              unawaited(_openRealTimeLoadDiagnostic()),
                        ),
                        const SizedBox(height: 8),
                        _sidebarActionButton(
                          context,
                          label: lm('lm-action-system-terminal'),
                          icon: Icons.terminal_rounded,
                          tooltip:
                              lm('lm-action-system-terminal-tip'),
                          busy: false,
                          requiresProLicense: true,
                          onPressed: () =>
                              unawaited(_openLocalSystemTerminal()),
                        ),
                        if (!kIsWeb && isWindows) ...[
                          ..._windowsSecretFolderSidebarWidgets(context),
                          const SizedBox(height: 14),
                          Text(
                            translate('lm-external-tools-section'),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: _lmActionInnerSize(11),
                              fontWeight: FontWeight.w800,
                              color: kLocalMaintenanceCopper,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (var i = 0; i < kExternalItTools.length; i++) ...[
                            _sidebarExternalToolButton(
                              context,
                              tool: kExternalItTools[i],
                            ),
                            if (i < kExternalItTools.length - 1)
                              const SizedBox(height: 8),
                          ],
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// טרמינל למחשב המקומי לפי [bind.mainGetMyId] — עם IS_TERMINAL_ADMIN (מצב SYSTEM בצד שרת).
  Future<void> _openLocalSystemTerminal() async {
    if (kIsWeb) return;
    if (!_lmProOk) return;
    try {
      final id = (await bind.mainGetMyId()).trim();
      if (id.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lm('lm-terminal-no-desk-id'),
              textDirection: lmDir,
            ),
          ),
        );
        return;
      }
      setEnvTerminalAdmin();
      await rustDeskWinManager.newTerminal(id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            lm('lm-terminal-opened'),
            textDirection: lmDir,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${lm('lm-open-terminal-failed-prefix')} $e',
            textDirection: lmDir,
          ),
        ),
      );
    }
  }

  Future<void> _launchWindowsMemoryTest() async {
    try {
      await LocalMaintenanceService.launchWindowsMemoryDiagnostic();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            lm('lm-ram-test-started'),
            textDirection: lmDir,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${lm('lm-launch-failed-prefix')} $e',
            textDirection: lmDir,
          ),
        ),
      );
    }
  }

  Widget _sidebarActionButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required String tooltip,
    required bool busy,
    bool requiresProLicense = true,
    required VoidCallback? onPressed,
  }) {
    final cs = Theme.of(context).colorScheme;
    final allowed = !requiresProLicense || _lmProOk;
    final tip = !requiresProLicense || _lmProOk
        ? tooltip
        : '$tooltip — ${lm('lm-pro-license-required-suffix')}';
    final btn = FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: kLocalMaintenanceCopper,
        foregroundColor: cs.onPrimary,
        disabledBackgroundColor: cs.surfaceContainerHighest,
        disabledForegroundColor: cs.onSurfaceVariant.withOpacity(0.45),
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
        elevation: allowed && !busy ? 3 : 0,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: Colors.black.withOpacity(0.12),
          ),
        ),
      ),
      onPressed: busy || !allowed ? null : onPressed,
      child: Row(
        textDirection: lmDir,
        children: [
          if (busy)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.onPrimary,
              ),
            )
          else
            Icon(icon, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: _lmActionInnerSize(12.5),
                height: 1.15,
              ),
            ),
          ),
        ],
      ),
    );
    return Tooltip(
      message: tip,
      child: requiresProLicense && !_lmProOk
          ? Opacity(opacity: 0.72, child: btn)
          : btn,
    );
  }

  /// Windows-only sidebar block: «תיקיות סודיות» (e.g. FolderHide.exe).
  List<Widget> _windowsSecretFolderSidebarWidgets(BuildContext context) {
    final tools = secretFolderItToolsForPlatform();
    if (tools.isEmpty) return const [];
    return [
      const SizedBox(height: 14),
      Text(
        translate('lm-secret-folders-section'),
        textAlign: TextAlign.right,
        style: TextStyle(
          fontSize: _lmActionInnerSize(11),
          fontWeight: FontWeight.w800,
          color: kLocalMaintenanceCopper,
          letterSpacing: 0.2,
        ),
      ),
      const SizedBox(height: 8),
      for (var i = 0; i < tools.length; i++) ...[
        _sidebarExternalToolButton(context, tool: tools[i]),
        if (i < tools.length - 1) const SizedBox(height: 8),
      ],
    ];
  }

  /// External IT apps from `tools\extapps\` — short name + info icon (Hebrew tooltip only on icon).
  Widget _sidebarExternalToolButton(
    BuildContext context, {
    required ExternalItTool tool,
  }) {
    final cs = Theme.of(context).colorScheme;
    final allowed = _lmProOk;
    final btn = FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: kLocalMaintenanceCopper,
        foregroundColor: cs.onPrimary,
        disabledBackgroundColor: cs.surfaceContainerHighest,
        disabledForegroundColor: cs.onSurfaceVariant.withOpacity(0.45),
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
        elevation: allowed ? 3 : 0,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: Colors.black.withOpacity(0.12),
          ),
        ),
      ),
      onPressed: !allowed
          ? null
          : () => unawaited(launchExternalItTool(context, tool)),
      child: Row(
        textDirection: lmDir,
        children: [
          Expanded(
            child: Text(
              translate(tool.nameKey),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: _lmActionInnerSize(12.5),
                height: 1.15,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: translate(tool.tooltipKey),
            waitDuration: const Duration(milliseconds: 400),
            child: Icon(
              Icons.info_outline,
              size: 22,
              color: allowed
                  ? cs.onPrimary
                  : cs.onSurfaceVariant.withOpacity(0.45),
            ),
          ),
        ],
      ),
    );
    return !allowed ? Opacity(opacity: 0.72, child: btn) : btn;
  }

  Widget _metricCardShell(
    BuildContext context, {
    required Widget child,
    bool showAi = false,
    VoidCallback? onAiTap,
    VoidCallback? onInfoPressed,
    String? infoTooltip,
  }) {
    final cs = Theme.of(context).colorScheme;
    final tooltip = infoTooltip ?? lm('lm-info-expand');
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.72),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: kLocalMaintenanceCopper.withOpacity(0.28)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: onInfoPressed != null ? 22 : 0),
            child: child,
          ),
          if (showAi && onAiTap != null)
            Positioned(
              top: -2,
              right: -2,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onAiTap,
                  borderRadius: BorderRadius.circular(20),
                  child: Tooltip(
                    message: lm('lm-ai-helper'),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.auto_awesome,
                        size: 18,
                        color: kLocalMaintenanceCopper.withOpacity(0.95),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (onInfoPressed != null)
            Positioned(
              left: 0,
              bottom: 0,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  tooltip: tooltip,
                  onPressed: onInfoPressed,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  icon: Icon(
                    Icons.info_outline,
                    size: 18,
                    color: kLocalMaintenanceCopper.withOpacity(0.92),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cardInfoLine(
    ColorScheme cs, {
    required String label,
    required String value,
    int maxLines = 1,
    bool ltrValue = false,
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textDirection: lmDir,
            style: TextStyle(
              fontSize: _lmInnerSize(7.8),
              color: cs.onSurfaceVariant,
              height: 1.05,
            ),
          ),
          Text(
            value.trim().isEmpty ? '—' : value,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            textDirection: ltrValue ? TextDirection.ltr : TextDirection.rtl,
            textAlign: ltrValue ? TextAlign.right : TextAlign.start,
            style: TextStyle(
              fontSize: _lmInnerSize(8.8),
              fontWeight: FontWeight.w700,
              color: valueColor ?? cs.onSurface,
              height: 1.12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardSectionHeader(
    ColorScheme cs, {
    required IconData icon,
    required String title,
    Widget? trailing,
  }) {
    return Row(
      children: [
        Icon(icon, size: 15, color: kLocalMaintenanceCopper),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _lmCubeTitleStyle(cs),
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _cpuCombinedCard(
    BuildContext context, {
    required String cpuModel,
    required double? cpuPct,
    required double? tempC,
    required bool showAi,
    required VoidCallback? onAiTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final pct = cpuPct?.clamp(0.0, 100.0) ?? 0.0;
    final showTemp = tempC != null && tempC > 0.5;
    final cpuH = _cpuHealth();
    final tempH = _tempHealth();
    return _metricCardShell(
      context,
      showAi: showAi,
      onAiTap: onAiTap,
      onInfoPressed: _lmProOk
          ? () => unawaited(
                _openRealTimeLoadDiagnostic(mode: _LmRtLoadMode.cpuOnly),
              )
          : null,
      infoTooltip: lm('lm-cpu-load-tip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.memory_outlined,
                  size: 15, color: kLocalMaintenanceCopper),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-cpu'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
              _miniChip(cpuH.label, cpuH.color),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            cpuModel,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _lmInnerSize(9.5),
              height: 1.15,
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${lm('lm-usage-cpu-prefix')}${cpuPct != null ? '${cpuPct.toStringAsFixed(0)}%' : '—'}',
            style: TextStyle(
              fontSize: _lmInnerSize(17),
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: cpuPct != null ? pct / 100.0 : 0,
              minHeight: 4,
              backgroundColor: cs.surfaceContainerHigh,
              color: kLocalMaintenanceCopper.withOpacity(0.9),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.thermostat_outlined,
                size: 13,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 3),
              Expanded(
                child: Text(
                  showTemp
                      ? '${tempC.toStringAsFixed(0)}°C · ${tempH.label}'
                      : tempH.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _lmInnerSize(11),
                    fontWeight: FontWeight.w800,
                    color: showTemp ? cs.onSurface : tempH.color,
                  ),
                ),
              ),
            ],
          ),
          _cpuCoresPanel(cs, showTemp: showTemp),
        ],
      ),
    );
  }

  /// Per-core CPU temperatures (LibreHardwareMonitor via `hw_helper.exe`).
  ///
  /// When `cpu_cores_temp_c` is empty (common when running as a regular user
  /// because LHM needs admin to load WinRing0.sys), shows a hint that the
  /// app must be launched as Administrator for detailed CPU sensors.
  Widget _cpuCoresPanel(ColorScheme cs, {required bool showTemp}) {
    final raw = _hw?['cpu_cores_temp_c'];
    final cores = <(String, double)>[];
    if (raw is List) {
      for (final c in raw) {
        if (c is! Map) continue;
        final name = c['name']?.toString().trim() ?? '';
        final t = c['temp_c'];
        if (t is num) {
          cores.add((name.isEmpty ? 'Core' : name, t.toDouble()));
        }
      }
    }

    if (cores.isEmpty) {
      if (showTemp) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          lm('lm-cpu-cores-need-admin'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: _lmInnerSize(9),
            color: cs.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    Color colorForTemp(double t) {
      if (t < 70) return const Color(0xFF16A34A);
      if (t <= 85) return const Color(0xFFF59E0B);
      return const Color(0xFFDC2626);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final (name, temp) in cores)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: colorForTemp(temp).withOpacity(0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: colorForTemp(temp).withOpacity(0.4),
                  width: 0.7,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _shortenCoreName(name),
                    style: TextStyle(
                      fontSize: _lmInnerSize(9),
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${temp.toStringAsFixed(0)}°C',
                    style: TextStyle(
                      fontSize: _lmInnerSize(9.5),
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      color: colorForTemp(temp),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// "CPU Core #1" → "C1", "Core #2" → "C2".
  static String _shortenCoreName(String name) {
    final m = RegExp(r'#?(\d+)').firstMatch(name);
    if (m != null) return 'C${m.group(1)}';
    return name;
  }

  String _fmtWinSatScore(double? value) {
    if (value == null || value <= 0) return '—';
    return value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  ({String label, String description, Color color}) _winSatBand(
    double? score,
  ) {
    if (score == null || score <= 0) {
      return (
        label: lm('lm-status-unavailable'),
        description: lm('lm-winsat-not-found'),
        color: Colors.blueGrey,
      );
    }
    if (score < 4.0) {
      return (
        label: lm('lm-tier-basic'),
        description: lm('lm-winsat-tier-basic-desc'),
        color: Colors.redAccent,
      );
    }
    if (score < 6.0) {
      return (
        label: lm('lm-tier-daily'),
        description: lm('lm-winsat-tier-daily-desc'),
        color: Colors.orange,
      );
    }
    if (score < 8.0) {
      return (
        label: lm('lm-tier-high'),
        description: lm('lm-winsat-tier-high-desc'),
        color: Colors.lightGreen.shade700,
      );
    }
    return (
      label: lm('lm-tier-workstation'),
      description: lm('lm-winsat-tier-workstation-desc'),
      color: Colors.green,
    );
  }

  ({String title, String details}) _winSatUpgradeSuggestion(
    LocalMaintenanceWinSatSnapshot? ws,
  ) {
    if (ws == null) {
      return (
        title: lm('lm-winsat-run'),
        details: lm('lm-winsat-no-scores-yet'),
      );
    }
    final scores = <({String part, double? score, String suggestion})>[
      (
        part: lm('lm-disk-short'),
        score: ws.diskScore,
        suggestion: lm('lm-winsat-suggest-disk'),
      ),
      (
        part: lm('lm-part-ram'),
        score: ws.memoryScore,
        suggestion: lm('lm-winsat-suggest-ram'),
      ),
      (
        part: lm('lm-part-gpu'),
        score: ws.graphicsScore,
        suggestion: lm('lm-winsat-suggest-gpu'),
      ),
      (
        part: lm('lm-part-3d'),
        score: ws.d3dScore,
        suggestion: lm('lm-winsat-suggest-3d'),
      ),
      (
        part: lm('lm-part-cpu'),
        score: ws.cpuScore,
        suggestion: lm('lm-winsat-suggest-cpu'),
      ),
    ].where((s) => s.score != null && s.score! > 0).toList();
    if (scores.isEmpty) {
      return (
        title: lm('lm-winsat-no-data'),
        details: lm('lm-winsat-no-valid-scores'),
      );
    }
    scores.sort((a, b) => a.score!.compareTo(b.score!));
    final weakest = scores.first;
    if (weakest.score! >= 8.0) {
      return (
        title: lm('lm-winsat-not-urgent'),
        details: lm('lm-winsat-strong-system'),
      );
    }
    if (weakest.score! >= 6.0) {
      return (
        title: lm('lm-winsat-optional'),
        details: '${weakest.part} ${lm('lm-winsat-weak-but-ok')}',
      );
    }
    return (
      title: '${lm('lm-winsat-upgrade-title-prefix')} ${weakest.part}',
      details: weakest.suggestion,
    );
  }

  Future<void> _openWinSatInfoDialog() async {
    if (!mounted) return;
    final ws = _winSat;
    final score = ws?.effectiveScore;
    final band = _winSatBand(score);
    final upgrade = _winSatUpgradeSuggestion(ws);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        TextStyle titleStyle() => TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            );
        TextStyle bodyStyle() => TextStyle(
              fontSize: 12,
              height: 1.35,
              color: cs.onSurfaceVariant,
            );
        Widget scoreLine(String label, double? value) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(label, style: bodyStyle()),
                ),
                Text(
                  _fmtWinSatScore(value),
                  style: bodyStyle().copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          );
        }

        return AlertDialog(
          title: Text(
            lm('lm-winsat-title'),
            textDirection: lmDir,
          ),
          content: SizedBox(
            width: 460,
            child: Directionality(
              textDirection: lmDir,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${lm('lm-winsat-overall-score-prefix')} ${_fmtWinSatScore(score)} — ${band.label}',
                      style: titleStyle(),
                    ),
                    const SizedBox(height: 4),
                    Text(band.description, style: bodyStyle()),
                    const SizedBox(height: 10),
                    Text(upgrade.title, style: titleStyle()),
                    const SizedBox(height: 4),
                    Text(upgrade.details, style: bodyStyle()),
                    const SizedBox(height: 12),
                    Text(lm('lm-winsat-scores'), style: titleStyle()),
                    const SizedBox(height: 6),
                    scoreLine(lm('lm-card-cpu'), ws?.cpuScore),
                    scoreLine(lm('lm-memory-en'), ws?.memoryScore),
                    scoreLine(lm('lm-disk-short'), ws?.diskScore),
                    scoreLine(lm('lm-graphics-short'), ws?.graphicsScore),
                    scoreLine(lm('lm-d3d-short'), ws?.d3dScore),
                    const Divider(height: 20),
                    Text(lm('lm-winsat-howto'), style: titleStyle()),
                    const SizedBox(height: 6),
                    Text(
                      lm('lm-winsat-howto-body'),
                      style: bodyStyle(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(lm('lm-close-alt')),
            ),
          ],
        );
      },
    );
  }

  Widget _winSatPerformanceCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_winSatLoading && _winSat == null) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-performance'),
        icon: Icons.speed_outlined,
      );
    }
    if (_winSatError != null && _winSat == null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-performance'),
        icon: Icons.speed_outlined,
        message: _shortServiceError(_winSatError!),
      );
    }
    final ws = _winSat;
    final score = ws?.effectiveScore;
    final band = _winSatBand(score);
    final upgrade = _winSatUpgradeSuggestion(ws);
    final progress = score == null ? 0.0 : (score / 9.9).clamp(0.0, 1.0);
    return _metricCardShell(
      context,
      onInfoPressed: () => unawaited(_openWinSatInfoDialog()),
      infoTooltip: lm('lm-winsat-detail-tip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.speed_outlined,
                  size: 15, color: kLocalMaintenanceCopper),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-performance'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
              _miniChip(band.label, band.color),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _fmtWinSatScore(score),
            style: TextStyle(
              fontSize: _lmInnerSize(22),
              fontWeight: FontWeight.w900,
              color: cs.onSurface,
            ),
          ),
          Text(
            band.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _lmInnerSize(8.7),
              color: cs.onSurfaceVariant,
              height: 1.15,
            ),
          ),
          Text(
            '${upgrade.title}: ${upgrade.details}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textDirection: lmDir,
            style: TextStyle(
              fontSize: _lmInnerSize(8.2),
              color: kLocalMaintenanceCopper.withOpacity(0.95),
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: cs.surfaceContainerHigh,
              color: band.color,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'CPU ${_fmtWinSatScore(ws?.cpuScore)} · RAM ${_fmtWinSatScore(ws?.memoryScore)} · Disk ${_fmtWinSatScore(ws?.diskScore)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _lmInnerSize(8),
              color: cs.onSurfaceVariant.withOpacity(0.9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _osSystemCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_forensicLoading && _forensic == null) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-os'),
        icon: Icons.laptop_windows_outlined,
      );
    }
    if (_forensicError != null && _forensic == null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-os'),
        icon: Icons.laptop_windows_outlined,
        message: _shortServiceError(_forensicError!),
      );
    }
    final caption = (_forensic?.osCaption ?? '').trim();
    final display = caption.isNotEmpty ? caption : _osLine;
    final license = (_audit?.osLicense ?? '').trim();
    return _metricCardShell(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardSectionHeader(
            cs,
            icon: Icons.laptop_windows_outlined,
            title: lm('lm-windows'),
          ),
          const SizedBox(height: 5),
          _cardInfoLine(cs, label: lm('lm-label-version'), value: display, maxLines: 3),
          if (_auditLoading && _audit == null)
            _cardInfoLine(cs, label: lm('lm-label-windows-license'), value: lm('lm-loading-ellipsis'))
          else
            _cardInfoLine(
              cs,
              label: lm('lm-label-windows-license'),
              value: license.isEmpty ? '—' : license,
              maxLines: 3,
            ),
        ],
      ),
    );
  }

  Widget _microsoftSoftwareCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_auditLoading && _audit == null) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-office'),
        icon: Icons.apps_rounded,
      );
    }
    if (_auditError != null && _audit == null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-office'),
        icon: Icons.apps_rounded,
        message: _shortServiceError(_auditError!),
      );
    }
    final office = _audit?.officeProducts ?? const <String>[];
    final microsoft = _audit?.microsoftProducts ?? const <String>[];
    final officeText =
        office.isEmpty ? lm('lm-office-not-installed') : office.take(3).join('\n');
    final msText = microsoft.isEmpty
        ? lm('lm-no-extra-ms-apps')
        : microsoft.take(4).join('\n');
    return _metricCardShell(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardSectionHeader(
            cs,
            icon: Icons.apps_rounded,
            title: lm('lm-card-office'),
            trailing: _miniChip(
              office.isEmpty ? lm('lm-office-not-detected') : lm('lm-label-office'),
              office.isEmpty ? Colors.blueGrey : Colors.green,
            ),
          ),
          const SizedBox(height: 5),
          _cardInfoLine(cs, label: lm('lm-label-office'), value: officeText, maxLines: 4),
          _cardInfoLine(
            cs,
            label: lm('lm-label-ms-apps'),
            value: msText,
            maxLines: 5,
          ),
        ],
      ),
    );
  }

  Widget _seedesktopLicenseCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _metricCardShell(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 15,
                color: kLocalMaintenanceCopper,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-license'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _licenseMaskedDisplay,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: _lmInnerSize(10),
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          if (_licenseStatusLine.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              _licenseStatusLine,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textDirection: lmDir,
              style: TextStyle(
                fontSize: _lmInnerSize(8),
                color: cs.onSurfaceVariant,
                height: 1.2,
              ),
            ),
          ],
          const Spacer(),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            runSpacing: 2,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _licenseBusy ? null : _openLicenseSettings,
                child: Text(
                  lm('lm-change-license'),
                  style: TextStyle(
                    fontSize: _lmInnerSize(9),
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _licenseBusy
                    ? null
                    : () => unawaited(_syncLicenseWithServer()),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_licenseBusy)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: kLocalMaintenanceCopper.withOpacity(0.95),
                          ),
                        ),
                      ),
                    Text(
                      _licenseBusy ? lm('lm-syncing') : lm('lm-sync-server'),
                      style: TextStyle(
                        fontSize: _lmInnerSize(9),
                        fontWeight: FontWeight.w700,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ramCard(
    BuildContext context, {
    required double? pct,
    List<({String label, int capacityMb})>? ramSlots,
    required bool auditLoading,
    required bool showAi,
    required VoidCallback? onAiTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final p = pct?.clamp(0.0, 100.0) ?? 0.0;
    final ramH = _ramHealth();
    final gbLine = (_ramUsedGb != null && _ramTotalGb != null)
        ? '${_ramUsedGb!.toStringAsFixed(1)} / ${_ramTotalGb!.toStringAsFixed(1)} GB'
        : '—';
    final slots = ramSlots ?? const <({String label, int capacityMb})>[];
    return _metricCardShell(
      context,
      showAi: showAi,
      onAiTap: onAiTap,
      onInfoPressed: _lmProOk
          ? () => unawaited(
                _openRealTimeLoadDiagnostic(mode: _LmRtLoadMode.ramOnly),
              )
          : null,
      infoTooltip: lm('lm-ram-pagefile-tip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.sd_storage_outlined,
                  size: 15, color: kLocalMaintenanceCopper),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-ram'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
              _miniChip(ramH.label, ramH.color),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            pct != null ? '${pct.toStringAsFixed(0)}%' : '—',
            style: TextStyle(
              fontSize: _lmInnerSize(20),
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          Text(
            gbLine,
            style: TextStyle(
                fontSize: _lmInnerSize(9.5), color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct != null ? p / 100.0 : 0,
              minHeight: 4,
              backgroundColor: cs.surfaceContainerHigh,
              color: kLocalMaintenanceCopper.withOpacity(0.9),
            ),
          ),
          if (auditLoading)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                lm('lm-ram-modules-loading'),
                style: TextStyle(
                    fontSize: _lmInnerSize(8), color: cs.onSurfaceVariant),
                textDirection: lmDir,
              ),
            )
          else if (slots.isNotEmpty) ...[
            const SizedBox(height: 4),
            ...slots.take(3).map(
                  (s) => Text(
                    _formatRamSlotLine(s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textDirection: lmDir,
                    style: TextStyle(
                      fontSize: _lmInnerSize(8),
                      height: 1.15,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
            if (slots.length > 3)
              Text(
                '… +${slots.length - 3}',
                style: TextStyle(
                    fontSize: _lmInnerSize(7.5), color: cs.onSurfaceVariant),
                textDirection: lmDir,
              ),
          ],
        ],
      ),
    );
  }

  String _shortServiceError(Object e) {
    final t = e.toString();
    return t.length > 140 ? '${t.substring(0, 140)}…' : t;
  }

  Widget _forensicCardLoadingShell(
    BuildContext context, {
    required String title,
    required IconData icon,
  }) {
    final cs = Theme.of(context).colorScheme;
    return _metricCardShell(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: kLocalMaintenanceCopper),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  title,
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
            ],
          ),
          const Spacer(),
          Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: kLocalMaintenanceCopper.withOpacity(0.9),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            lm('lm-loading-from-service'),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: _lmInnerSize(8.5), color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _forensicCardErrorShell(
    BuildContext context, {
    required String title,
    required IconData icon,
    required String message,
  }) {
    final cs = Theme.of(context).colorScheme;
    return _metricCardShell(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: kLocalMaintenanceCopper),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  title,
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
              Icon(Icons.error_outline,
                  size: 16, color: Colors.orange.shade700),
            ],
          ),
          const Spacer(),
          Text(
            message,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: _lmInnerSize(9), color: cs.error),
          ),
          Text(
            lm('lm-ensure-ipc-service'),
            style: TextStyle(
                fontSize: _lmInnerSize(8.5), color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _networkCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rx = _netRx;
    final tx = _netTx;
    final mbps = _netMbps;

    if (_netLoading && rx == null && tx == null) {
      return _metricCardShell(
        context,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.sync_alt_rounded,
                    size: 15, color: kLocalMaintenanceCopper),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    lm('lm-card-network'),
                    style: _lmCubeTitleStyle(cs),
                  ),
                ),
              ],
            ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kLocalMaintenanceCopper.withOpacity(0.9),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      lm('lm-loading-neighbors-service'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: _lmInnerSize(8.5),
                          color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_netError != null && rx == null && tx == null) {
      return _metricCardShell(
        context,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.sync_alt_rounded,
                    size: 15, color: kLocalMaintenanceCopper),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    lm('lm-card-network'),
                    style: _lmCubeTitleStyle(cs),
                  ),
                ),
                Icon(Icons.error_outline,
                    size: 16, color: Colors.orange.shade700),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.zero,
                physics: const ClampingScrollPhysics(),
                child: Text(
                  _shortServiceError(_netError!),
                  style: TextStyle(fontSize: _lmInnerSize(9), color: cs.error),
                  textDirection: lmDir,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final daily = _netDailyBytes;
    final cumulativeBytes = (rx != null && tx != null) ? (rx + tx) : 0;
    final overDaily = daily != null && daily > _kNetDailyWarnBytes;
    final overCumulative = cumulativeBytes > _kNetDailyWarnBytes;
    final dataWarn = overDaily || overCumulative;

    return _metricCardShell(
      context,
      onInfoPressed: rx != null && tx != null && _lmProOk
          ? () => _showArpDialog(context)
          : null,
      infoTooltip:
          _lmProOk ? lm('lm-net-arp-tip') : lm('lm-net-arp-pro-tip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.sync_alt_rounded,
                  size: 15, color: kLocalMaintenanceCopper),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-network'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
              if (rx != null && tx != null)
                _miniChip(
                  dataWarn ? lm('lm-status-data-warning') : lm('lm-status-ok'),
                  dataWarn ? Colors.deepOrange : Colors.green,
                ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              physics: const ClampingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    lm('lm-net-cumulative'),
                    style: TextStyle(
                        fontSize: _lmInnerSize(9), color: cs.onSurfaceVariant),
                  ),
                  Text(
                    rx != null && tx != null
                        ? '↓ ${LocalMaintenanceService.formatBytes(rx)} · ↑ ${LocalMaintenanceService.formatBytes(tx)}'
                        : '—',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _lmInnerSize(9.5),
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mbps != null
                        ? '${lm('lm-bandwidth-est-prefix')} ${mbps.toStringAsFixed(2)} Mb/s'
                        : lm('lm-rate-none'),
                    style: TextStyle(
                      fontSize: _lmInnerSize(9.5),
                      fontWeight: FontWeight.w600,
                      color: kLocalMaintenanceCopper.withOpacity(0.95),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    lm('lm-net-ipv4-internal'),
                    style: TextStyle(
                        fontSize: _lmInnerSize(8.5),
                        color: cs.onSurfaceVariant),
                  ),
                  SelectableText(
                    _netLocalIpv4 ?? '—',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      fontSize: _lmInnerSize(9.5),
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    lm('lm-net-ipv4-external'),
                    style: TextStyle(
                        fontSize: _lmInnerSize(8.5),
                        color: cs.onSurfaceVariant),
                  ),
                  SelectableText(
                    _netPublicIp ?? '—',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      fontSize: _lmInnerSize(9.5),
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  if (rx != null && tx != null) ...[
                    const SizedBox(height: 6),
                    if (daily != null) ...[
                      Text(
                        '${lm('lm-net-est-today-prefix')} ${LocalMaintenanceService.formatBytes(daily)}',
                        style: TextStyle(
                          fontSize: _lmInnerSize(8.5),
                          fontWeight: FontWeight.w600,
                          color: dataWarn
                              ? Colors.deepOrange.shade800
                              : cs.onSurfaceVariant,
                        ),
                        textDirection: lmDir,
                      ),
                      if (dataWarn)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            overCumulative && !overDaily
                                ? lm('lm-net-cumulative-over-5gb')
                                : lm('lm-net-daily-over-5gb'),
                            style: TextStyle(
                              fontSize: _lmInnerSize(8),
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                              color: Colors.deepOrange.shade900,
                            ),
                            textDirection: lmDir,
                          ),
                        ),
                    ],
                    const SizedBox(height: 4),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 4,
                      runSpacing: 2,
                      children: [
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () =>
                              unawaited(_openWindowsDataUsageSettings()),
                          icon: Icon(
                            Icons.data_usage_outlined,
                            size: 16,
                            color: cs.primary,
                          ),
                          label: Text(
                            lm('lm-app-usage-settings'),
                            style: TextStyle(
                              fontSize: _lmInnerSize(8.5),
                              fontWeight: FontWeight.w700,
                              color: cs.primary,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () =>
                              unawaited(_openNetworkConnectionsClassic()),
                          icon: Icon(
                            Icons.settings_ethernet,
                            size: 16,
                            color: cs.primary,
                          ),
                          label: Text(
                            lm('lm-mb-network-cards'),
                            style: TextStyle(
                              fontSize: _lmInnerSize(8.5),
                              fontWeight: FontWeight.w700,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_auditLoading)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        lm('lm-mac-arp-loading'),
                        style: TextStyle(
                            fontSize: _lmInnerSize(8),
                            color: cs.onSurfaceVariant),
                        textDirection: lmDir,
                      ),
                    )
                  else ...[
                    if ((_audit?.primaryMac ?? '').trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'MAC: ${_audit!.primaryMac}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textDirection: lmDir,
                          style: TextStyle(
                            fontSize: _lmInnerSize(8.5),
                            color: cs.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      '${lm('lm-active-net-devices-prefix')} ${_audit?.netUpCount ?? 0}',
                      textDirection: lmDir,
                      style: TextStyle(
                        fontSize: _lmInnerSize(8.5),
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Watchdog: רשימת שירותי Windows, בדיקה כל דקה והפעלה אוטומטית (אלא אם מושהה).
  Widget _watchdogCard(
    BuildContext context, {
    required bool showAi,
    VoidCallback? onAiTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final title = lm('lm-card-watchdog');

    if (_watchdogLoading) {
      return _metricCardShell(
        context,
        showAi: false,
        onAiTap: null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.monitor_heart_outlined,
                  size: 15,
                  color: kLocalMaintenanceCopper,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    title,
                    style: _lmCubeTitleStyle(cs),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: kLocalMaintenanceCopper.withOpacity(0.9),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              lm('lm-loading-services'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: _lmInnerSize(8.5), color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (_watchdogError != null) {
      return _metricCardShell(
        context,
        showAi: false,
        onAiTap: null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.monitor_heart_outlined,
                  size: 15,
                  color: kLocalMaintenanceCopper,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    title,
                    style: _lmCubeTitleStyle(cs),
                  ),
                ),
                Icon(Icons.error_outline,
                    size: 16, color: Colors.orange.shade700),
              ],
            ),
            const Spacer(),
            Text(
              _shortServiceError(_watchdogError!),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: _lmInnerSize(9), color: cs.error),
            ),
          ],
        ),
      );
    }

    final allRunning = _watchdogServiceNames.isNotEmpty &&
        _watchdogServiceNames.every((n) {
          final st = (_serviceStates[n] ?? '').toLowerCase();
          return st == 'running';
        });
    final chip = allRunning && _watchdogServiceNames.isNotEmpty
        ? _miniChip(lm('lm-all-running'), Colors.green)
        : _miniChip(
            _watchdogPaused ? lm('lm-paused') : lm('lm-monitoring'),
            _watchdogPaused ? Colors.blueGrey : Colors.teal.shade700,
          );
    final pro = _lmProOk;

    return _metricCardShell(
      context,
      showAi: showAi,
      onAiTap: onAiTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.monitor_heart_outlined,
                size: 15,
                color: kLocalMaintenanceCopper,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  title,
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
              chip,
              Tooltip(
                message: pro
                    ? (_watchdogPaused ? lm('lm-resume-monitoring') : lm('lm-pause-monitoring'))
                    : lm('lm-pro-required-short'),
                child: InkWell(
                  onTap: pro
                      ? () => unawaited(_setWatchdogPaused(!_watchdogPaused))
                      : null,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      _watchdogPaused ? Icons.play_arrow : Icons.pause,
                      size: 20,
                      color: pro
                          ? cs.primary
                          : cs.onSurfaceVariant.withOpacity(0.35),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_watchdogPaused)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                lm('lm-monitoring-paused-hint'),
                style: TextStyle(
                  fontSize: _lmInnerSize(8),
                  fontWeight: FontWeight.w600,
                  color: Colors.orange.shade800,
                ),
                textDirection: lmDir,
              ),
            ),
          const SizedBox(height: 4),
          if (_watchdogServiceNames.isEmpty)
            Text(
              lm('lm-no-services-hint'),
              style: TextStyle(
                  fontSize: _lmInnerSize(8.5), color: cs.onSurfaceVariant),
              textDirection: lmDir,
            )
          else
            ..._watchdogServiceNames.map((n) {
              final st = _serviceStates[n];
              final ch = _watchdogStatusChip(st);
              return Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  textDirection: lmDir,
                  children: [
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      tooltip: pro ? lm('lm-remove-from-list') : lm('lm-remove-pro-required'),
                      onPressed: pro
                          ? () => unawaited(_removeWatchdogService(n))
                          : null,
                      icon: Icon(
                        Icons.close,
                        size: 14,
                        color: cs.onSurfaceVariant.withOpacity(0.85),
                      ),
                    ),
                    _miniChip(ch.label, ch.color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        n,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: _lmInnerSize(9),
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          const Spacer(),
          Text(
            lm('lm-watchdog-minute-hint'),
            style: TextStyle(
                fontSize: _lmInnerSize(7.5), color: cs.onSurfaceVariant),
            textDirection: lmDir,
          ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            runSpacing: 2,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: pro ? _showAddWatchdogServiceDialog : null,
                child: Text(
                  lm('lm-add-service'),
                  style: TextStyle(
                    fontSize: _lmInnerSize(9),
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: !pro ||
                        _busyWatchdogManualStart ||
                        _watchdogServiceNames.isEmpty
                    ? null
                    : () => unawaited(_onStartStoppedWatchdogServices()),
                icon: _busyWatchdogManualStart
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: kLocalMaintenanceCopper.withOpacity(0.95),
                        ),
                      )
                    : Icon(
                        Icons.play_circle_outline,
                        size: 14,
                        color: kLocalMaintenanceCopper.withOpacity(0.95),
                      ),
                label: Text(
                  _busyWatchdogManualStart ? lm('lm-starting') : lm('lm-start-stopped-services'),
                  style: TextStyle(
                    fontSize: _lmInnerSize(9),
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _diskOverviewCard(BuildContext context, List<dynamic> diskList) {
    final cs = Theme.of(context).colorScheme;
    final volumeRows = diskList
        .whereType<Map>()
        .map((d) => Map<String, dynamic>.from(d))
        .toList(growable: false);
    final physicalDisks =
        _audit?.physicalDisks ?? const <LocalMaintenancePhysicalDisk>[];
    final hasWarn =
        physicalDisks.any((d) => _diskNeedsAi(d.smartStatus, null)) ||
            volumeRows.any((d) => _diskNeedsAi(
                  d['health']?.toString(),
                  (d['used_pct'] as num?)?.toDouble(),
                ));
    String? chipHealth;
    for (final d in physicalDisks) {
      if (_diskNeedsAi(d.smartStatus, null)) {
        chipHealth = d.smartStatus;
        break;
      }
    }
    chipHealth ??= volumeRows
        .map((d) => d['health']?.toString())
        .firstWhere((h) => _diskNeedsAi(h, null), orElse: () => null);
    return _metricCardShell(
      context,
      showAi: _lmProOk && hasWarn,
      onAiTap:
          _lmProOk && hasWarn ? () => _openAiAdviceDialog(_hintsDisk()) : null,
      onInfoPressed: () => unawaited(_openDiskStorageSenseFromInfo()),
      infoTooltip: lm('lm-disk-storage-tip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardSectionHeader(
            cs,
            icon: Icons.storage_outlined,
            title: lm('lm-card-disks'),
            trailing: _miniChip(
              hasWarn
                  ? (physicalDisks.isNotEmpty
                      ? 'SMART'
                      : _diskHebrew(chipHealth))
                  : lm('lm-status-ok'),
              hasWarn ? Colors.orange : Colors.green,
            ),
          ),
          const SizedBox(height: 5),
          Expanded(
            child: physicalDisks.isNotEmpty
                ? ListView.separated(
                    padding: EdgeInsets.zero,
                    physics: const ClampingScrollPhysics(),
                    itemCount: physicalDisks.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 10,
                      color: cs.outlineVariant.withOpacity(0.35),
                    ),
                    itemBuilder: (context, i) {
                      final d = physicalDisks[i];
                      final status = d.smartStatus.trim().isEmpty
                          ? 'SMART: —'
                          : d.smartStatus;
                      final partitions = d.partitions;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  d.model.trim().isEmpty
                                      ? '${lm('lm-physical-disk-prefix')}${d.index}'
                                      : d.model,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textDirection: lmDir,
                                  style: TextStyle(
                                    fontSize: _lmInnerSize(9.2),
                                    fontWeight: FontWeight.w800,
                                    color: cs.onSurface,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                              _miniChip(
                                status.replaceFirst(
                                    RegExp(r'^(SMART|Health|Status):\s*'), ''),
                                _diskSmartColor(status),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (d.diskType.trim().isNotEmpty) d.diskType,
                              if (d.port.trim().isNotEmpty)
                                '${lm('lm-port-bus-label')} ${d.port}',
                              if (d.busType.trim().isNotEmpty &&
                                  d.busType.trim() != d.port.trim())
                                'Bus: ${d.busType}',
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textDirection: lmDir,
                            style: TextStyle(
                              fontSize: _lmInnerSize(7.8),
                              color: cs.onSurfaceVariant,
                              height: 1.12,
                            ),
                          ),
                          const SizedBox(height: 3),
                          if (partitions.isEmpty)
                            Text(
                              lm('lm-partitions-none'),
                              textDirection: lmDir,
                              style: TextStyle(
                                fontSize: _lmInnerSize(7.8),
                                color: cs.onSurfaceVariant,
                              ),
                            )
                          else
                            ...partitions.take(4).map((p) {
                              final total = p.totalGb;
                              final free = p.freeGb;
                              final pctUsed =
                                  total != null && total > 0 && free != null
                                      ? ((total - free) / total).clamp(0.0, 1.0)
                                      : 0.0;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${p.id}${p.label.isNotEmpty ? ' · ${p.label}' : ''}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textDirection: lmDir,
                                            style: TextStyle(
                                              fontSize: _lmInnerSize(7.8),
                                              fontWeight: FontWeight.w700,
                                              color: cs.onSurface,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          total != null && free != null
                                              ? '${free.toStringAsFixed(1)}/${total.toStringAsFixed(1)}GB ${lm('lm-free-short')}'
                                              : '—',
                                          style: TextStyle(
                                            fontSize: _lmInnerSize(7.4),
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(2),
                                      child: LinearProgressIndicator(
                                        value: pctUsed,
                                        minHeight: 3,
                                        backgroundColor:
                                            cs.surfaceContainerHigh,
                                        color: kLocalMaintenanceCopper
                                            .withOpacity(0.85),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                        ],
                      );
                    },
                  )
                : volumeRows.isEmpty
                    ? Center(
                        child: Text(
                          lm('lm-no-drives-found'),
                          textDirection: lmDir,
                          style: TextStyle(
                            fontSize: _lmInnerSize(9),
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.zero,
                        physics: const ClampingScrollPhysics(),
                        itemCount: volumeRows.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 5),
                        itemBuilder: (context, i) {
                          final d = volumeRows[i];
                          final id = d['id']?.toString() ?? '';
                          final label = d['label']?.toString() ?? '';
                          final health = d['health']?.toString();
                          final usedPct = (d['used_pct'] as num?)?.toDouble();
                          final totalGb = (d['total_gb'] as num?)?.toDouble();
                          final freeGb = (d['free_gb'] as num?)?.toDouble();
                          final dm =
                              (d['disk_model'] ?? d['model'])?.toString() ?? '';
                          final dt =
                              (d['disk_type'] ?? d['type'])?.toString() ?? '';
                          final p = usedPct?.clamp(0.0, 100.0) ?? 0.0;
                          final title = [
                            if (id.isNotEmpty) id,
                            if (label.isNotEmpty) label,
                          ].join(' · ');
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      title.isEmpty ? lm('lm-drive-generic') : title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textDirection: lmDir,
                                      style: TextStyle(
                                        fontSize: _lmInnerSize(9.2),
                                        fontWeight: FontWeight.w800,
                                        color: cs.onSurface,
                                        height: 1.1,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    usedPct != null
                                        ? '${usedPct.toStringAsFixed(0)}%'
                                        : '—',
                                    style: TextStyle(
                                      fontSize: _lmInnerSize(9),
                                      fontWeight: FontWeight.w800,
                                      color: cs.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: usedPct != null ? p / 100.0 : 0,
                                  minHeight: 4,
                                  backgroundColor: cs.surfaceContainerHigh,
                                  color: _diskColor(health),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                [
                                  if (freeGb != null && totalGb != null)
                                    '${freeGb.toStringAsFixed(1)} / ${totalGb.toStringAsFixed(1)} GB ${lm('lm-free-short')}',
                                  if (dt.isNotEmpty || dm.isNotEmpty)
                                    [dt, dm]
                                        .where((s) => s.trim().isNotEmpty)
                                        .join(' · '),
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textDirection: lmDir,
                                style: TextStyle(
                                  fontSize: _lmInnerSize(7.8),
                                  color: cs.onSurfaceVariant,
                                  height: 1.1,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _forensicStabilityCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_forensicLoading) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-stability'),
        icon: Icons.bolt_outlined,
      );
    }
    if (_forensicError != null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-stability'),
        icon: Icons.bolt_outlined,
        message: _shortServiceError(_forensicError!),
      );
    }
    final f = _forensic;
    final bsod = f?.bsod1001 ?? 0;
    final e41 = f?.unexpectedShutdown41 ?? 0;
    final bad = bsod > 0 || e41 > 0;
    final chipColor = bad ? Colors.orange : Colors.green;
    final chipLabel = bad ? lm('lm-warning-short') : lm('lm-status-ok');
    final pro = _lmProOk;
    return _metricCardShell(
      context,
      showAi: pro && bad,
      onAiTap: pro && bad ? () => _openAiAdviceDialog(_hintsStability()) : null,
      onInfoPressed:
          pro ? () => unawaited(_openUnexpectedShutdownsLast5Dialog()) : null,
      infoTooltip: lm('lm-stability-shutdown-tip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.bolt_outlined,
                size: 15,
                color: kLocalMaintenanceCopper,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-stability'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
              _miniChip(chipLabel, chipColor),
            ],
          ),
          const Spacer(),
          Text(
            'BSOD (1001): $bsod',
            style: TextStyle(
              fontSize: _lmInnerSize(10.5),
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          Text(
            '${lm('lm-unexpected-shutdown-41-prefix')} $e41',
            style: TextStyle(
                fontSize: _lmInnerSize(9.5), color: cs.onSurfaceVariant),
          ),
          Text(
            'חלון: 30 יום',
            style: TextStyle(
              fontSize: _lmInnerSize(8.5),
              color: cs.onSurfaceVariant.withOpacity(0.9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _forensicAppHealthCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_forensicLoading) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-app-health'),
        icon: Icons.apps_outage_outlined,
      );
    }
    if (_forensicError != null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-app-health'),
        icon: Icons.apps_outage_outlined,
        message: _shortServiceError(_forensicError!),
      );
    }
    final f = _forensic;
    final n = f?.appError1000 ?? 0;
    final top = (f?.topCrashApp ?? '').trim();
    final bad = n > 0;
    final chipColor = bad ? Colors.orange : Colors.green;
    final chipLabel = bad ? lm('lm-warning-short') : lm('lm-status-ok');
    final pro = _lmProOk;
    return _metricCardShell(
      context,
      showAi: pro && bad,
      onAiTap: pro && bad ? () => _openAiAdviceDialog(_hintsAppHealth()) : null,
      onInfoPressed:
          pro ? () => unawaited(_openApplicationErrorsLast5Dialog()) : null,
      infoTooltip: 'חמש שגיאות Application אחרונות',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.apps_outage_outlined,
                size: 15,
                color: kLocalMaintenanceCopper,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-app-health'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
              _miniChip(chipLabel, chipColor),
            ],
          ),
          const Spacer(),
          Text(
            'קריסות (1000): $n',
            style: TextStyle(
              fontSize: _lmInnerSize(11),
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          Text(
            top.isNotEmpty ? 'תדיר ביותר: $top' : 'תדיר ביותר: —',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: _lmInnerSize(9), color: cs.onSurfaceVariant),
          ),
          Text(
            'חלון: 30 יום',
            style: TextStyle(
              fontSize: _lmInnerSize(8.5),
              color: cs.onSurfaceVariant.withOpacity(0.9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _forensicSecurityCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_forensicLoading) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-security'),
        icon: Icons.lock_outline_rounded,
      );
    }
    if (_forensicError != null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-security'),
        icon: Icons.lock_outline_rounded,
        message: _shortServiceError(_forensicError!),
      );
    }
    final f = _forensic;
    final fl = f?.failedLogon4625 ?? -1;
    final unavailable = fl < 0;
    final bad = fl > 0;
    final chipColor =
        unavailable ? Colors.blueGrey : (bad ? Colors.orange : Colors.green);
    final chipLabel = unavailable ? lm('lm-status-unavailable') : (bad ? lm('lm-warning-short') : lm('lm-status-ok'));
    final showSecAi = bad || _antivirusNeedsAi();
    final pro = _lmProOk;
    return _metricCardShell(
      context,
      showAi: pro && showSecAi,
      onAiTap: pro && showSecAi
          ? () => _openAiAdviceDialog(_hintsSecurityCombined())
          : null,
      onInfoPressed: pro ? () => _showLocalUsersDialog(context) : null,
      infoTooltip: pro ? 'רשימת משתמשים מקומיים' : 'רשימת משתמשים — נדרש Pro',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 15,
                color: kLocalMaintenanceCopper,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-security'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
              _miniChip(chipLabel, chipColor),
            ],
          ),
          const Spacer(),
          Text(
            unavailable
                ? 'התחברויות שנכשלו (4625): לא זמין'
                : 'התחברויות שנכשלו (4625): $fl',
            style: TextStyle(
              fontSize: _lmInnerSize(10.5),
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          Text(
            unavailable
                ? 'לא ניתן לקרוא את יומן האבטחה (4625). אם שירות הרקע פעיל — בדקו auditing / הרשאות.'
                : 'חלון: 7 ימים',
            style: TextStyle(
              fontSize: _lmInnerSize(8.5),
              color: cs.onSurfaceVariant.withOpacity(0.95),
            ),
          ),
          if (_auditLoading)
            Text(
              'AV / משתמשים: טוען…',
              style: TextStyle(
                  fontSize: _lmInnerSize(8), color: cs.onSurfaceVariant),
              textDirection: lmDir,
            )
          else if (_auditError != null)
            Text(
              _shortServiceError(_auditError!),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: _lmInnerSize(8), color: cs.error),
              textDirection: lmDir,
            )
          else ...[
            Text(
              'AV: ${(_audit?.antivirusName ?? '').trim().isEmpty ? '—' : _audit!.antivirusName}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textDirection: lmDir,
              style: TextStyle(
                fontSize: _lmInnerSize(8.5),
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            Text(
              'משתמשים מקומיים פעילים: ${_audit?.localUsersActive ?? 0}',
              textDirection: lmDir,
              style: TextStyle(
                fontSize: _lmInnerSize(8.5),
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _auditSystemMotherboardCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sbAi = _secureBootNeedsAi();
    if (_auditLoading) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-motherboard'),
        icon: Icons.dns_outlined,
      );
    }
    if (_auditError != null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-motherboard'),
        icon: Icons.dns_outlined,
        message: _shortServiceError(_auditError!),
      );
    }
    final a = _audit!;
    final sb = a.secureBoot.trim();
    final sbLabel = sb.isEmpty ? 'Unknown' : sb;
    final pro = _lmProOk;
    return _metricCardShell(
      context,
      showAi: pro && sbAi,
      onAiTap:
          pro && sbAi ? () => _openAiAdviceDialog(_hintsSecureBoot()) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardSectionHeader(
            cs,
            icon: Icons.dns_outlined,
            title: lm('lm-card-motherboard'),
          ),
          const SizedBox(height: 5),
          _cardInfoLine(
            cs,
            label: lm('lm-label-vendor-model'),
            value: a.motherboard.isEmpty ? '—' : a.motherboard,
            maxLines: 2,
          ),
          _cardInfoLine(
            cs,
            label: lm('lm-bios-version'),
            value: a.biosVersion.isEmpty ? '—' : a.biosVersion,
            maxLines: 2,
            ltrValue: true,
          ),
          _cardInfoLine(
            cs,
            label: lm('lm-usb'),
            value:
                'בקרים: ${a.usbControllerCount} · Hubs/יציאות מדווחות: ${a.usbHubCount}',
            maxLines: 2,
          ),
          _cardInfoLine(
            cs,
            label: lm('lm-storage-controller'),
            value:
                a.storageControllerMode.isEmpty ? '—' : a.storageControllerMode,
            maxLines: 2,
            ltrValue: true,
          ),
          _cardInfoLine(
            cs,
            label: lm('lm-secure-boot'),
            value: sbLabel,
            valueColor:
                sb.toLowerCase() == 'off' ? Colors.orange : cs.onSurface,
          ),
        ],
      ),
    );
  }

  Widget _auditGpuCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_auditLoading) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-gpu'),
        icon: Icons.memory_outlined,
      );
    }
    if (_auditError != null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-gpu'),
        icon: Icons.memory_outlined,
        message: _shortServiceError(_auditError!),
      );
    }
    final a = _audit!;
    final gpus = a.gpuAdapters;
    return _metricCardShell(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.memory_outlined,
                  size: 15, color: kLocalMaintenanceCopper),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-gpu'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: gpus.isEmpty
                ? Text(
                    a.primaryGpu.isEmpty ? '—' : a.primaryGpu,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    textDirection: lmDir,
                    style: TextStyle(
                      fontSize: _lmInnerSize(9),
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                      height: 1.2,
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: gpus.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 10,
                      color: cs.outlineVariant.withOpacity(0.35),
                    ),
                    itemBuilder: (context, i) {
                      final g = gpus[i];
                      final vram = g.adapterRamMb > 0
                          ? '${g.adapterRamMb} MB'
                          : 'לא דווח / משותף';
                      final res = (g.width > 0 && g.height > 0)
                          ? '${g.width}×${g.height}'
                          : '—';
                      final hzLine = g.refreshHz.trim().isNotEmpty
                          ? '${g.refreshHz} Hz'
                          : '—';
                      return Directionality(
                        textDirection: lmDir,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              g.name,
                              style: TextStyle(
                                fontSize: _lmInnerSize(9.5),
                                fontWeight: FontWeight.w800,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'זיכרון מתאם (VRAM): $vram',
                              style: TextStyle(
                                fontSize: _lmInnerSize(8.5),
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              'דרייבר: ${g.driverVersion.isEmpty ? '—' : g.driverVersion}',
                              style: TextStyle(
                                fontSize: _lmInnerSize(8.5),
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              'מצב תצוגה: ${g.videoMode.isEmpty ? '—' : g.videoMode}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: _lmInnerSize(8),
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              'רזולוציה נוכחית: $res · רענון: $hzLine',
                              style: TextStyle(
                                fontSize: _lmInnerSize(8.5),
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                            ),
                            Text(
                              'סטטוס: ${g.status.isEmpty ? '—' : g.status}',
                              style: TextStyle(
                                fontSize: _lmInnerSize(8),
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _multimediaCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_auditLoading) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-multimedia'),
        icon: Icons.speaker_outlined,
      );
    }
    if (_auditError != null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-multimedia'),
        icon: Icons.speaker_outlined,
        message: _shortServiceError(_auditError!),
      );
    }
    final audio = _audit?.audioDevices ?? const <String>[];
    return _metricCardShell(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardSectionHeader(
            cs,
            icon: Icons.speaker_outlined,
            title: lm('lm-card-multimedia'),
            trailing: _miniChip(
              audio.isEmpty ? 'לא זוהה' : 'Audio',
              audio.isEmpty ? Colors.blueGrey : Colors.green,
            ),
          ),
          const SizedBox(height: 5),
          _cardInfoLine(
            cs,
            label: lm('lm-label-sound'),
            value: audio.isEmpty ? '—' : audio.take(5).join('\n'),
            maxLines: 6,
          ),
        ],
      ),
    );
  }

  Widget _auditPrintersCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_auditLoading) {
      return _forensicCardLoadingShell(
        context,
        title: lm('lm-card-printers'),
        icon: Icons.print_outlined,
      );
    }
    if (_auditError != null) {
      return _forensicCardErrorShell(
        context,
        title: lm('lm-card-printers'),
        icon: Icons.print_outlined,
        message: _shortServiceError(_auditError!),
      );
    }
    final a = _audit!;
    final n = a.printers.length;
    final rows = a.printers;
    return _metricCardShell(
      context,
      onInfoPressed: _lmProOk ? () => _showPrintersDialog(context) : null,
      infoTooltip: _lmProOk ? 'רשימת מדפסות מלאה' : 'רשימה מלאה — נדרש Pro',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.print_outlined,
                  size: 15, color: kLocalMaintenanceCopper),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  lm('lm-card-printers'),
                  style: _lmCubeTitleStyle(cs),
                ),
              ),
            ],
          ),
          Text(
            'סה״כ: $n',
            textDirection: lmDir,
            style: TextStyle(
              fontSize: _lmInnerSize(8.5),
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          if (rows.isEmpty) ...[
            const Spacer(),
            Text(
              'אין מדפסות מדווחות',
              textDirection: lmDir,
              style: TextStyle(
                  fontSize: _lmInnerSize(9), color: cs.onSurfaceVariant),
            ),
          ] else
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: rows.take(5).map((r) {
                  final line = '${r.name.trim()}  ·  פורט: ${r.port.trim()}';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textDirection: lmDir,
                      style: TextStyle(
                        fontSize: _lmInnerSize(8.5),
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                        height: 1.15,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => unawaited(_openWindowsPrintersFolder()),
              icon: Icon(
                Icons.open_in_new,
                size: 16,
                color: cs.primary,
              ),
              label: Text(
                'מדפסות זמינות (Windows)',
                style: TextStyle(
                  fontSize: _lmInnerSize(8.5),
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniChip(String text, Color c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.withOpacity(0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.withOpacity(0.45)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: _lmInnerSize(8.5),
          fontWeight: FontWeight.w700,
          color: c,
        ),
      ),
    );
  }
}

/// דיאלוג עומס בזמן אמת (רענון / סגירה).
class _LmRealTimeLoadAlert extends StatefulWidget {
  const _LmRealTimeLoadAlert({this.mode = _LmRtLoadMode.full});

  final _LmRtLoadMode mode;

  @override
  State<_LmRealTimeLoadAlert> createState() => _LmRealTimeLoadAlertState();
}

class _LmRealTimeLoadAlertState extends State<_LmRealTimeLoadAlert> {
  late Future<LocalMaintenanceRealTimeLoad> _future;

  _LmRtLoadMode get _mode => widget.mode;

  @override
  void initState() {
    super.initState();
    _future = LocalMaintenanceService.fetchRealTimeLoad();
  }

  void _refresh() {
    setState(() {
      _future = LocalMaintenanceService.fetchRealTimeLoad();
    });
  }

  int? _uptimeDays(String uptime) {
    final m = RegExp(r'(\d+)\s*Days').firstMatch(uptime);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fs = Theme.of(context).textTheme.bodyMedium?.fontSize ?? 13.0;
    return AlertDialog(
      title: Text(
        lm('lm-action-load-analysis'),
        textDirection: lmDir,
      ),
      content: SizedBox(
        width: 440,
        child: FutureBuilder<LocalMaintenanceRealTimeLoad>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return SingleChildScrollView(
                child: SelectableText(
                  '${snap.error}',
                  textDirection: lmDir,
                ),
              );
            }
            final d = snap.data!;
            final cpuV = (d.totalCpu ?? 0).clamp(0.0, 100.0) / 100.0;
            final ramV = d.totalRamPct.clamp(0.0, 100.0) / 100.0;
            final cpuHigh = (d.totalCpu ?? 0) > 85;
            final ramHigh = d.totalRamPct > 85;
            final upDays = _uptimeDays(d.uptime);
            final uptimeWarn = upDays != null && upDays > 14;

            Widget rowProcCpu(LocalMaintenanceRealTimeProcCpu p) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  textDirection: lmDir,
                  children: [
                    Expanded(
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: fs,
                        ),
                      ),
                    ),
                    Text(
                      'PID ${p.id} · CPU ${p.cpu}',
                      style: TextStyle(
                        fontSize: fs - 1,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }

            Widget rowProcRam(LocalMaintenanceRealTimeProcRam p) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  textDirection: lmDir,
                  children: [
                    Expanded(
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: fs,
                        ),
                      ),
                    ),
                    Text(
                      'PID ${p.id} · ${p.ramMb} MB',
                      style: TextStyle(
                        fontSize: fs - 1,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }

            final swapTotal = d.swapTotalMb;
            final swapUsed = d.swapUsedMb;
            final swapBlock = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'קובץ החלפה (page file)',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: fs,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  swapTotal != null && swapTotal > 0
                      ? 'סה״כ ${swapTotal.toStringAsFixed(1)} MB · בשימוש ${(swapUsed ?? 0).toStringAsFixed(1)} MB'
                      : 'אין קובץ החלפה פעיל / גודל אפס',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: fs,
                    color: cs.onSurface,
                  ),
                ),
              ],
            );

            final children = <Widget>[];

            if (_mode != _LmRtLoadMode.ramOnly) {
              children.addAll([
                Text(
                  'מעבד כולל',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: fs,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                Text(
                  '${(d.totalCpu ?? 0).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: fs + 4,
                    color: cpuHigh ? Colors.red.shade800 : cs.onSurface,
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: cpuV,
                    minHeight: 10,
                    backgroundColor: cs.surfaceContainerHighest,
                    color: cpuHigh ? Colors.red : cs.primary,
                  ),
                ),
                const SizedBox(height: 14),
              ]);
            }

            if (_mode != _LmRtLoadMode.cpuOnly) {
              children.addAll([
                Text(
                  'זיכרון (שימוש)',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: fs,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                Text(
                  '${d.totalRamPct.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: fs + 4,
                    color: ramHigh ? Colors.red.shade800 : cs.onSurface,
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ramV,
                    minHeight: 10,
                    backgroundColor: cs.surfaceContainerHighest,
                    color: ramHigh ? Colors.red : Colors.teal.shade600,
                  ),
                ),
                const SizedBox(height: 14),
              ]);
            }

            if (_mode != _LmRtLoadMode.cpuOnly) {
              children.addAll([swapBlock, const SizedBox(height: 14)]);
            }

            children.addAll([
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      'זמן פעולה רצוף: ${d.uptime}',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: fs,
                      ),
                    ),
                  ),
                  if (uptimeWarn) ...[
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange.shade800,
                      size: 26,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 2,
                      child: Text(
                        'מעל 14 ימים ללא אתחול — מומלץ לאתחל את המחשב.',
                        style: TextStyle(
                          fontSize: fs - 1,
                          color: Colors.orange.shade900,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 16),
            ]);

            if (_mode != _LmRtLoadMode.ramOnly) {
              children.addAll([
                Text(
                  lm('lm-top-cpu-processes'),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: fs + 1,
                    color: kLocalMaintenanceCopper,
                  ),
                ),
                const SizedBox(height: 6),
                ...d.topCpu.map(rowProcCpu),
              ]);
              if (_mode == _LmRtLoadMode.full) {
                children.add(const SizedBox(height: 12));
              }
            }

            if (_mode != _LmRtLoadMode.cpuOnly) {
              children.addAll([
                Text(
                  lm('lm-top-ram-processes'),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: fs + 1,
                    color: kLocalMaintenanceCopper,
                  ),
                ),
                const SizedBox(height: 6),
                ...d.topRam.map(rowProcRam),
              ]);
            }

            return SingleChildScrollView(
              child: Directionality(
                textDirection: lmDir,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            );
          },
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton.icon(
          onPressed: _refresh,
          icon: const Icon(Icons.refresh, size: 20),
          label: Text(lm('lm-refresh')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(lm('lm-close-alt'), style: TextStyle(color: cs.primary)),
        ),
      ],
    );
  }
}

/// דיאלוג 5 שגיאות Application אחרונות.
class _LmAppErrorsAlert extends StatefulWidget {
  const _LmAppErrorsAlert();

  @override
  State<_LmAppErrorsAlert> createState() => _LmAppErrorsAlertState();
}

class _LmAppErrorsAlertState extends State<_LmAppErrorsAlert> {
  late Future<List<LocalMaintenanceAppErrorRow>> _future;

  @override
  void initState() {
    super.initState();
    _future = LocalMaintenanceService.fetchApplicationErrorsLast5();
  }

  void _refresh() {
    setState(() {
      _future = LocalMaintenanceService.fetchApplicationErrorsLast5();
    });
  }

  static String _truncate(String s, int max) {
    final t = s.trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fs = Theme.of(context).textTheme.bodyMedium?.fontSize ?? 13.0;
    return AlertDialog(
      title: Text(
        lm('lm-last-5-crashes-title'),
        textDirection: lmDir,
      ),
      content: SizedBox(
        width: 440,
        height: 360,
        child: FutureBuilder<List<LocalMaintenanceAppErrorRow>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return SelectableText(
                '${snap.error}',
                textDirection: lmDir,
              );
            }
            final rows = snap.data ?? [];
            if (rows.isEmpty) {
              return Center(
                child: Text(
                  lm('lm-no-recent-error-records'),
                  textDirection: lmDir,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: fs),
                ),
              );
            }
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 16),
              itemBuilder: (context, i) {
                final r = rows[i];
                return Directionality(
                  textDirection: lmDir,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        r.time,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: fs,
                          color: kLocalMaintenanceCopper,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${lm('lm-error-source-prefix')} ${r.source}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: fs - 0.5,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        _truncate(r.message, 320),
                        style: TextStyle(
                          fontSize: fs - 1,
                          color: cs.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton.icon(
          onPressed: _refresh,
          icon: const Icon(Icons.refresh, size: 20),
          label: Text(lm('lm-refresh')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(lm('lm-close-alt'), style: TextStyle(color: cs.primary)),
        ),
      ],
    );
  }
}

/// דיאלוג 5 אירועי כיבוי בלתי צפוי אחרונים (System Event ID 41).
class _LmUnexpectedShutdownsAlert extends StatefulWidget {
  const _LmUnexpectedShutdownsAlert();

  @override
  State<_LmUnexpectedShutdownsAlert> createState() =>
      _LmUnexpectedShutdownsAlertState();
}

class _LmUnexpectedShutdownsAlertState
    extends State<_LmUnexpectedShutdownsAlert> {
  late Future<List<LocalMaintenanceUnexpectedShutdownRow>> _future;

  @override
  void initState() {
    super.initState();
    _future = LocalMaintenanceService.fetchUnexpectedShutdownsLast5();
  }

  void _refresh() {
    setState(() {
      _future = LocalMaintenanceService.fetchUnexpectedShutdownsLast5();
    });
  }

  static String _truncate(String s, int max) {
    final t = s.trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fs = Theme.of(context).textTheme.bodyMedium?.fontSize ?? 13.0;
    return AlertDialog(
      title: Text(
        lm('lm-last-5-unexpected-shutdowns-title'),
        textDirection: lmDir,
      ),
      content: SizedBox(
        width: 460,
        height: 380,
        child: FutureBuilder<List<LocalMaintenanceUnexpectedShutdownRow>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return SelectableText(
                '${snap.error}',
                textDirection: lmDir,
              );
            }
            final rows = snap.data ?? [];
            if (rows.isEmpty) {
              return Center(
                child: Text(
                  lm('lm-no-recent-unexpected-shutdowns'),
                  textDirection: lmDir,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: fs),
                ),
              );
            }
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 16),
              itemBuilder: (context, i) {
                final r = rows[i];
                return Directionality(
                  textDirection: lmDir,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        r.time,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: fs,
                          color: kLocalMaintenanceCopper,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'מקור: ${r.provider} · רמה: ${r.level}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: fs - 0.5,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        _truncate(r.message, 360),
                        style: TextStyle(
                          fontSize: fs - 1,
                          color: cs.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton.icon(
          onPressed: _refresh,
          icon: const Icon(Icons.refresh, size: 20),
          label: Text(lm('lm-refresh')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(lm('lm-close-alt'), style: TextStyle(color: cs.primary)),
        ),
      ],
    );
  }
}
