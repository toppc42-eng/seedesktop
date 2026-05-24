import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/utils/local_cleanup_catalog.dart';
import 'package:flutter_hbb/utils/seedesktop_cleanup_launcher.dart';
import 'package:path/path.dart' as p;

class LocalCleanupStorage {
  static String? _configDir() {
    final la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return null;
    return p.join(la, 'SeeDesktopCleanup');
  }

  static File? _settingsFile() {
    final d = _configDir();
    if (d == null) return null;
    return File(p.join(d, 'settings.json'));
  }

  static File? _logFile() {
    final d = _configDir();
    if (d == null) return null;
    return File(p.join(d, 'last_auto_run.log'));
  }

  static Future<Map<String, dynamic>> loadMerged() async {
    final f = _settingsFile();
    Map<String, dynamic> raw = {};
    if (f != null && f.existsSync()) {
      try {
        raw = jsonDecode(await f.readAsString(encoding: utf8))
            as Map<String, dynamic>;
      } catch (_) {}
    }
    final cats = Map<String, bool>.from(defaultCategoriesBool());
    final fromFile = raw['categories'];
    if (fromFile is Map) {
      for (final e in fromFile.entries) {
        final k = e.key?.toString();
        if (k != null && cats.containsKey(k) && e.value is bool) {
          cats[k] = e.value as bool;
        }
      }
    }
    final sched = Map<String, dynamic>.from(defaultSchedule());
    final s = raw['schedule'];
    if (s is Map) {
      for (final e in sched.entries) {
        if (s.containsKey(e.key)) sched[e.key] = s[e.key];
      }
    }
    final opts = Map<String, dynamic>.from(defaultOptions());
    final o = raw['options'];
    if (o is Map) {
      for (final e in opts.entries) {
        if (o.containsKey(e.key)) opts[e.key] = o[e.key];
      }
    }
    return <String, dynamic>{
      'categories': cats,
      'schedule': sched,
      'options': opts,
    };
  }

  static Future<void> save(Map<String, dynamic> data) async {
    final d = _configDir();
    if (d == null) return;
    Directory(d).createSync(recursive: true);
    final f = _settingsFile();
    if (f == null) return;
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      encoding: utf8,
    );
  }

  static String? readLastLog() {
    final f = _logFile();
    if (f == null || !f.existsSync()) return null;
    try {
      return f.readAsStringSync(encoding: utf8);
    } catch (_) {
      return null;
    }
  }

  static String cleanupExePath() => seeDesktopCleanupExePath();

  /// Returns process exit code, or -1 on failure to start.
  static Future<int> runAutoCleanupDetached() async {
    final exe = cleanupExePath();
    if (exe.isEmpty || !File(exe).existsSync()) return -1;
    final pr = await Process.start(
      exe,
      const ['--auto-run'],
      mode: ProcessStartMode.detachedWithStdIO,
    );
    return pr.exitCode;
  }
}
