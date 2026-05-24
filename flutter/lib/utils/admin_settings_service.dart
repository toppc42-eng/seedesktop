import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_hbb/utils/admin_cloud_sync_hooks.dart';

class AdminSettingsService {
  static const String _initialAdminPassword = '326542';
  static const int _defaultPromoDelaySeconds = 30;
  static const String _cachePromoDelayKey =
      'admin_settings_promo_delay_seconds';

  /// Incremented after any successful cloud pull that may have changed fleet policy,
  /// or after a successful [saveToCloud]. Widgets can listen to react app-wide.
  static final ValueNotifier<int> fleetPolicyRevision = ValueNotifier<int>(0);

  static void _notifyFleetPolicyChanged() {
    fleetPolicyRevision.value = fleetPolicyRevision.value + 1;
  }

  static final List<String> _settingsJsonUrls = [
    'https://seedesktop.com/elivc/public_html/downloads/admin/settings.json',
    'https://www.seedesktop.com/elivc/public_html/downloads/admin/settings.json',
  ];
  static final List<String> _updatePhpUrls = [
    'https://seedesktop.com/elivc/public_html/downloads/admin/update.php',
    'https://www.seedesktop.com/elivc/public_html/downloads/admin/update.php',
  ];

  static Timer? _timer;
  static bool _started = false;
  static String _lastSyncError = '';
  static int _promoDelaySeconds = _defaultPromoDelaySeconds;

  /// Last values applied from cloud JSON (or after a successful [saveToCloud]).
  static bool _rmmScriptsUiVisibleCloud = false;
  static bool _upgradeMarketingVisibleCloud = true;

  static String get adminPassword => _initialAdminPassword;
  static int get promoDelaySeconds => _promoDelaySeconds;
  static String get lastSyncError => _lastSyncError;

  /// Mirrors fleet policy from `settings.json` for UI/debug; notifiers are updated via hooks.
  static bool get rmmScriptsUiVisibleFromCloud => _rmmScriptsUiVisibleCloud;
  static bool get upgradeMarketingVisibleFromCloud =>
      _upgradeMarketingVisibleCloud;

  static Future<void> startSync() async {
    if (_started) {
      return;
    }
    _started = true;
    await _loadCache();
    await syncFromCloud();
    _timer ??= Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(syncFromCloud());
    });
  }

  static Future<void> _loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    _promoDelaySeconds =
        prefs.getInt(_cachePromoDelayKey) ?? _defaultPromoDelaySeconds;
  }

  static Future<void> _saveCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_cachePromoDelayKey, _promoDelaySeconds);
  }

  static bool _parseJsonBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().trim().toLowerCase();
    if (s.isEmpty) return false;
    if (s == 'false' || s == '0' || s == 'no' || s == 'off') return false;
    return s == 'true' || s == '1' || s == 'yes' || s == 'on';
  }

  /// Reads a boolean from JSON using canonical + legacy key names (PHP / hand-edited files).
  static bool? _readCloudBool(
    Map<String, dynamic> data,
    List<String> keys,
  ) {
    for (final k in keys) {
      if (!data.containsKey(k)) continue;
      final v = data[k];
      if (v == null) continue;
      return _parseJsonBool(v);
    }
    return null;
  }

  static Future<void> _applyOptionalCloudFlags(
      Map<String, dynamic> data) async {
    var applied = false;
    final rmmParsed = _readCloudBool(data, const [
      'rmm_scripts_ui_visible',
      'rmm_scripts_ui',
      'show_rmm_scripts',
    ]);
    if (rmmParsed != null) {
      applied = true;
      _rmmScriptsUiVisibleCloud = rmmParsed;
      final rmmHook = AdminCloudSyncHooks.onRmmScriptsUiVisible;
      if (rmmHook != null) {
        await rmmHook(rmmParsed);
      } else {
        debugPrint(
          'AdminSettingsService: onRmmScriptsUiVisible hook is null; '
          'fleet RMM visibility not applied to local prefs.',
        );
      }
    }

    final marketingParsed = _readCloudBool(data, const [
      'upgrade_marketing_visible',
      'upgrade_marketing',
      'show_upgrade_marketing',
    ]);
    if (marketingParsed != null) {
      applied = true;
      _upgradeMarketingVisibleCloud = marketingParsed;
      final mHook = AdminCloudSyncHooks.onUpgradeMarketingVisible;
      if (mHook != null) {
        await mHook(marketingParsed);
      } else {
        debugPrint(
          'AdminSettingsService: onUpgradeMarketingVisible hook is null; '
          'fleet marketing visibility not applied to local prefs.',
        );
      }
    }
    if (applied) {
      _notifyFleetPolicyChanged();
    }
  }

  /// Static JSON files are often cached by CDN/edge even with Cache-Control; add a nonce query.
  static Uri _settingsJsonGetUri(String baseUrl) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      queryParameters: <String, String>{
        ...base.queryParameters,
        't': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
  }

  /// Pulls fleet admin settings from cloud JSON. All connected clients should converge
  /// on the same values (promo delay, RMM UI, upgrade marketing).
  static Future<bool> syncFromCloud() async {
    _lastSyncError = '';
    for (final url in _settingsJsonUrls) {
      try {
        final uri = _settingsJsonGetUri(url);
        final response = await http.get(
          uri,
          headers: const {
            'Cache-Control': 'no-cache, no-store',
            'Pragma': 'no-cache',
          },
        );
        if (response.statusCode != 200) {
          _lastSyncError =
              'Cloud read failed ($url): HTTP ${response.statusCode}';
          continue;
        }
        final decoded = jsonDecode(response.body);
        final data = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
        if (data == null) {
          _lastSyncError = 'Invalid JSON in settings response.';
          continue;
        }
        final rawDelay = data['ad_delay_seconds'];
        final parsedDelay =
            rawDelay is int ? rawDelay : int.tryParse('${rawDelay ?? ''}');
        if (parsedDelay != null) {
          _promoDelaySeconds = parsedDelay < 0 ? 0 : parsedDelay;
          await _saveCache();
        }
        await _applyOptionalCloudFlags(data);
        if (kDebugMode) {
          final hasRmm = _readCloudBool(data, const [
                'rmm_scripts_ui_visible',
                'rmm_scripts_ui',
                'show_rmm_scripts',
              ]) !=
              null;
          final hasMkt = _readCloudBool(data, const [
                'upgrade_marketing_visible',
                'upgrade_marketing',
                'show_upgrade_marketing',
              ]) !=
              null;
          if (!hasRmm || !hasMkt) {
            debugPrint(
              'AdminSettingsService: settings.json missing RMM/marketing booleans '
              '(expected rmm_scripts_ui_visible / upgrade_marketing_visible).',
            );
          }
        }
        _lastSyncError = '';
        return true;
      } catch (e) {
        _lastSyncError = 'Cloud read failed ($url): $e';
      }
    }
    return false;
  }

  static Future<bool> saveToCloud({
    required String password,
    required int promoDelaySeconds,
    required bool rmmScriptsUiVisible,
    required bool upgradeMarketingVisible,
  }) async {
    final safeDelay = promoDelaySeconds < 0 ? 0 : promoDelaySeconds;
    final trimmedPassword = password.trim();
    if (trimmedPassword.isEmpty) {
      _lastSyncError = 'Admin password cannot be empty.';
      return false;
    }

    // Canonical POST keys must match update.php / settings.json field names.
    final formBody = <String, String>{
      'password': trimmedPassword,
      'delay': safeDelay.toString(),
      'rmm_scripts_ui_visible': rmmScriptsUiVisible.toString(),
      'upgrade_marketing_visible': upgradeMarketingVisible.toString(),
    };
    final encodedBody = formBody.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');

    for (final url in _updatePhpUrls) {
      try {
        final response = await http.post(
          Uri.parse(url),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          },
          body: encodedBody,
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _promoDelaySeconds = safeDelay;
          _rmmScriptsUiVisibleCloud = rmmScriptsUiVisible;
          _upgradeMarketingVisibleCloud = upgradeMarketingVisible;
          _lastSyncError = '';
          await _saveCache();
          await rmmHookApplyLocal(rmmScriptsUiVisible);
          await marketingHookApplyLocal(upgradeMarketingVisible);
          // Wait for read-back so CDN/cache sees the new JSON before we return.
          await syncFromCloud();
          return true;
        }
        _lastSyncError =
            'HTTP write failed ($url): HTTP ${response.statusCode}';
      } catch (e) {
        _lastSyncError = 'HTTP write failed ($url): $e';
      }
    }
    return false;
  }

  static Future<void> rmmHookApplyLocal(bool v) async {
    final h = AdminCloudSyncHooks.onRmmScriptsUiVisible;
    if (h != null) await h(v);
  }

  static Future<void> marketingHookApplyLocal(bool v) async {
    final h = AdminCloudSyncHooks.onUpgradeMarketingVisible;
    if (h != null) await h(v);
  }
}
