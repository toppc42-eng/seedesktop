import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Mirrors [seedesktop_cleanup.config_store] JSON shape: categories + schedule + options.
class LocalCleanupSettings {
  final Map<String, bool> categories;
  final Map<String, dynamic> schedule;
  final Map<String, dynamic> options;

  const LocalCleanupSettings({
    required this.categories,
    required this.schedule,
    required this.options,
  });

  static Map<String, bool> defaultCategories() => Map<String, bool>.from({
        'temp_user': true,
        'temp_windows': true,
        'temp_inet': true,
        'thumbnails': true,
        'recycle_bin': false,
        'dns_cache': true,
        'wer_local': true,
        'delivery_opt': false,
        'chrome_cache': false,
        'edge_cache': false,
        'firefox_cache': false,
        'directx_shader': true,
        'windows_logs': false,
        'dism_winsxs': false,
        'store_cache': true,
        'windows_bt': false,
        'event_logs_wevt': false,
        'prefetch': false,
        'spotify_cache': false,
        'teams_cache': false,
        'onedrive_logs': false,
        'discord_cache': false,
        'privacy_chromium': false,
        'privacy_firefox': false,
        'browser_history_chromium': false,
      });

  static Map<String, dynamic> defaultSchedule() => Map<String, dynamic>.from({
        'enabled': false,
        'mode': 'daily',
        'hour': 2,
        'minute': 0,
        'weekday': 0,
        'monthday': 1,
      });

  static Map<String, dynamic> defaultOptions() => Map<String, dynamic>.from({
        'backup_manifest_before_run': false,
      });

  factory LocalCleanupSettings.defaults() => LocalCleanupSettings(
        categories: defaultCategories(),
        schedule: defaultSchedule(),
        options: defaultOptions(),
      );

  factory LocalCleanupSettings.fromJson(Map<String, dynamic> j) {
    final dc = defaultCategories();
    final rawCats = j['categories'];
    if (rawCats is Map) {
      for (final e in dc.entries) {
        final v = rawCats[e.key];
        if (v is bool) dc[e.key] = v;
      }
    }
    final ds = defaultSchedule();
    final rawS = j['schedule'];
    if (rawS is Map) {
      rawS.forEach((k, v) {
        if (ds.containsKey(k)) ds[k] = v;
      });
    }
    final dop = defaultOptions();
    final rawO = j['options'];
    if (rawO is Map) {
      rawO.forEach((k, v) {
        if (dop.containsKey(k)) dop[k] = v;
      });
    }
    return LocalCleanupSettings(
      categories: dc,
      schedule: ds,
      options: dop,
    );
  }

  Map<String, dynamic> toJson() => {
        'categories': categories,
        'schedule': schedule,
        'options': options,
      };

  static File? _configFileOrNull() {
    if (kIsWeb) return null;
    final la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return null;
    return File('$la${Platform.pathSeparator}SeeDesktopCleanup'
        '${Platform.pathSeparator}settings.json');
  }

  static Future<LocalCleanupSettings> load() async {
    final f = _configFileOrNull();
    if (f == null || !await f.exists()) {
      return LocalCleanupSettings.defaults();
    }
    try {
      final text = await f.readAsString(encoding: utf8);
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return LocalCleanupSettings.fromJson(decoded);
      }
    } catch (_) {}
    return LocalCleanupSettings.defaults();
  }

  static Future<void> save(LocalCleanupSettings s) async {
    final f = _configFileOrNull();
    if (f == null) {
      throw StateError('Cannot resolve cleanup config path.');
    }
    await f.parent.create(recursive: true);
    const enc = JsonEncoder.withIndent('  ');
    await f.writeAsString(enc.convert(s.toJson()), encoding: utf8);
  }
}
