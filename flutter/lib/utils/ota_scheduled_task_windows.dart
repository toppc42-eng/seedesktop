import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'package:flutter_hbb/common.dart';

import 'local_maintenance_service.dart';
import 'ota_update_service.dart';

/// Windows Task Scheduler integration for daily silent OTA (SYSTEM, highest privileges).
class OtaWindowsScheduledTask {
  OtaWindowsScheduledTask._();

  static const String taskName = r'SeeDesktop_OTA_Silent_Daily';
  static const String argSilent = '--ota-silent-scheduled';

  /// Default daily silent OTA time when no task / saved option exists.
  static const TimeOfDay defaultScheduleTime = TimeOfDay(hour: 16, minute: 0);

  /// Last error from [syncFromSettings] (shown in Updates UI).
  static String? lastSyncError;

  /// Non-error hint (e.g. success as current user).
  static String? lastSyncInfo;

  /// True after a successful `/Create` while daily schedule is enabled.
  static bool taskRegistered = false;

  /// True when the task runs as LOCAL SYSTEM (works when app is closed).
  static bool taskRunsAsSystem = false;

  /// Last [queryOsTask] result (for mismatch detection).
  static TimeOfDay? _osTaskStartTime;
  static String? _osTaskCommandLine;

  /// Registers or removes the task from current Flutter local options.
  ///
  /// Call only from the Updates UI button ([requestElevation] + UAC) or from the
  /// headless scheduled runner (direct `schtasks`, no admin IPC).
  static Future<void> syncFromSettings({
    bool requestElevation = false,
    bool skipAdminIpc = false,
    bool allowUserFallback = true,
  }) async {
    lastSyncError = null;
    lastSyncInfo = null;
    taskRegistered = false;
    taskRunsAsSystem = false;
    if (!Platform.isWindows) return;
    try {
      if (!OtaUpdateService.dailySilentScheduleEnabled) {
        if (requestElevation) {
          try {
            await LocalMaintenanceService.runSchtasksElevated(
              ['/Delete', '/TN', taskName, '/F'],
            );
          } catch (e) {
            lastSyncError =
                _friendlyError(e, requestElevation: requestElevation);
            return;
          }
        } else {
          await _deleteTask(
            requestElevation: requestElevation,
            skipAdminIpc: skipAdminIpc,
          );
        }
        return;
      }
      final exe = Platform.resolvedExecutable;
      if (!File(exe).existsSync()) {
        lastSyncError = 'SeeDesktop.exe path not found: $exe';
        return;
      }
      final t = OtaUpdateService.dailySilentScheduleTime;
      final st = _formatSchtasksTime(t);
      final tr = _taskRunValue(exe);
      final createArgs = _createArgs(tr: tr, st: st, asSystem: true);

      if (requestElevation) {
        try {
          // Use Register-ScheduledTask (PowerShell cmdlet) to avoid CMD-level
          // quoting issues when the exe path contains spaces.
          await LocalMaintenanceService.elevatedRegisterScheduledTask(
            taskName: taskName,
            exePath: exe,
            argument: argSilent,
            startTime: st,
          );
          taskRegistered = true;
          taskRunsAsSystem = true;
          lastSyncInfo =
              translate('ota-task-registered-system').replaceAll('{}', st);
          if (kDebugMode) {
            debugPrint('[OTA] Register-ScheduledTask $taskName @ $st (SYSTEM, HIGHEST)');
          }
          unawaited(refreshRegistrationStateFromOs());
          return;
        } catch (e) {
          lastSyncError = _friendlyError(e, requestElevation: requestElevation);
          if (kDebugMode) {
            debugPrint('[OTA] Register-ScheduledTask failed: $e');
          }
          return;
        }
      }

      await _deleteTask(
        requestElevation: false,
        skipAdminIpc: skipAdminIpc,
      );

      try {
        await LocalMaintenanceService.runSchtasks(
          createArgs,
          allowUacFallback: false,
          skipAdminIpc: skipAdminIpc,
        );
        taskRegistered = true;
        taskRunsAsSystem = true;
        lastSyncInfo =
            translate('ota-task-registered-system').replaceAll('{}', st);
        if (kDebugMode) {
          debugPrint('[OTA] scheduled task $taskName @ $st (SYSTEM, HIGHEST)');
        }
        unawaited(refreshRegistrationStateFromOs());
        return;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[OTA] SYSTEM schtasks failed: $e');
        }
        if (!allowUserFallback) {
          lastSyncError = _friendlyError(e, requestElevation: requestElevation);
          return;
        }
      }

      if (!allowUserFallback) {
        lastSyncError ??= translate('ota-err-system-failed');
        return;
      }

      try {
        await LocalMaintenanceService.runSchtasks(
          _createArgs(tr: tr, st: st, asSystem: false),
          allowUacFallback: false,
          skipAdminIpc: true,
        );
        taskRegistered = true;
        taskRunsAsSystem = false;
        lastSyncInfo = translate('ota-task-registered-user');
        if (kDebugMode) {
          debugPrint('[OTA] scheduled task $taskName @ $st (current user)');
        }
      } catch (e) {
        lastSyncError = _friendlyError(e, requestElevation: requestElevation);
        if (kDebugMode) {
          debugPrint('[OTA] scheduled task sync failed: $lastSyncError');
        }
      }
    } catch (e, st) {
      lastSyncError = _friendlyError(e, requestElevation: requestElevation);
      if (kDebugMode) {
        debugPrint('[OTA] scheduled task sync error: $e\n$st');
      }
    }
  }

  /// User pressed "register task" — persist is already done; apply via UAC if needed.
  static Future<void> registerWithHighestPrivileges() => syncFromSettings(
        requestElevation: true,
        skipAdminIpc: true,
        allowUserFallback: false,
      );

  /// Called from `--ota-silent-scheduled` before install: refresh task from disk options.
  static Future<void> syncBeforeScheduledRun() => syncFromSettings(
        requestElevation: false,
        skipAdminIpc: true,
        allowUserFallback: false,
      );

  /// Creates the daily OTA task at [defaultScheduleTime] (SYSTEM, HIGHEST) when missing.
  static Future<void> ensureScheduledTaskIfMissing() async {
    if (!Platform.isWindows) return;
    await refreshRegistrationStateFromOs();
    if (taskRegistered) return;
    if (!OtaUpdateService.dailySilentScheduleEnabled) return;
    await syncFromSettings(
      requestElevation: false,
      skipAdminIpc: false,
      allowUserFallback: false,
    );
    await refreshRegistrationStateFromOs();
  }

  /// Reads Task Scheduler state (no admin). Updates [taskRegistered] / [taskRunsAsSystem].
  static Future<void> refreshRegistrationStateFromOs() async {
    _osTaskStartTime = null;
    _osTaskCommandLine = null;
    taskRegistered = false;
    taskRunsAsSystem = false;
    if (!Platform.isWindows) return;

    final q = await queryOsTask();
    if (!q.exists) return;

    taskRegistered = true;
    _osTaskStartTime = q.startTime;
    _osTaskCommandLine = q.commandLine;
    taskRunsAsSystem = q.runsAsSystem;
    if (kDebugMode) {
      debugPrint(
        '[OTA] probed task: ST=${q.startTime} cmd=${q.commandLine} system=${q.runsAsSystem}',
      );
    }
  }

  /// True when an existing scheduled task does not match saved options / current EXE.
  static bool needsSyncWithSavedSettings() {
    if (!taskRegistered) return false;
    if (!OtaUpdateService.dailySilentScheduleEnabled) return false;

    final saved = OtaUpdateService.dailySilentScheduleTime;
    final os = _osTaskStartTime;
    if (os == null ||
        os.hour != saved.hour ||
        os.minute != saved.minute) {
      return true;
    }

    final expected = _normalizeRunCommand(_taskRunValue(Platform.resolvedExecutable));
    final actual = _normalizeRunCommand(_osTaskCommandLine ?? '');
    if (expected.isEmpty) return false;
    return expected != actual;
  }

  /// Apply saved schedule to an existing task (service IPC first; no UAC unless [requestElevation]).
  static Future<void> syncWithSavedSettingsIfNeeded({
    bool requestElevation = false,
  }) async {
    await refreshRegistrationStateFromOs();
    if (!OtaUpdateService.dailySilentScheduleEnabled) {
      if (taskRegistered) {
        await syncFromSettings(
          requestElevation: requestElevation,
          skipAdminIpc: !requestElevation,
          allowUserFallback: false,
        );
      }
      return;
    }
    if (!taskRegistered || !needsSyncWithSavedSettings()) return;
    await syncFromSettings(
      requestElevation: requestElevation,
      skipAdminIpc: !requestElevation,
      allowUserFallback: false,
    );
    await refreshRegistrationStateFromOs();
  }

  static Future<({bool exists, TimeOfDay? startTime, String? commandLine, bool runsAsSystem})>
      queryOsTask() async {
    if (!Platform.isWindows) {
      return (
        exists: false,
        startTime: null,
        commandLine: null,
        runsAsSystem: false,
      );
    }
    try {
      final pr = await Process.run(
        r'C:\Windows\System32\schtasks.exe',
        ['/Query', '/TN', taskName, '/XML'],
        runInShell: false,
      );
      if (pr.exitCode != 0) {
        return (
          exists: false,
          startTime: null,
          commandLine: null,
          runsAsSystem: false,
        );
      }
      final xml = '${pr.stdout}';
      final boundary = RegExp(
        r'<StartBoundary>([^<]+)</StartBoundary>',
        caseSensitive: false,
      ).firstMatch(xml)?.group(1)?.trim();
      TimeOfDay? startTime;
      if (boundary != null && boundary.isNotEmpty) {
        final dt = DateTime.tryParse(boundary);
        if (dt != null) {
          startTime = TimeOfDay(hour: dt.hour, minute: dt.minute);
        }
      }
      final cmd = RegExp(
        r'<Command>([^<]*)</Command>',
        caseSensitive: false,
      ).firstMatch(xml)?.group(1)?.trim();
      final args = RegExp(
        r'<Arguments>([^<]*)</Arguments>',
        caseSensitive: false,
      ).firstMatch(xml)?.group(1)?.trim();
      final commandLine = [
        if (cmd != null && cmd.isNotEmpty) cmd,
        if (args != null && args.isNotEmpty) args,
      ].join(' ').trim();

      final userId = RegExp(
        r'<UserId>([^<]+)</UserId>',
        caseSensitive: false,
      ).firstMatch(xml)?.group(1)?.trim().toLowerCase();
      final runsAsSystem = userId == 's-1-5-18' ||
          userId == 'system' ||
          userId?.contains('system') == true;

      return (
        exists: true,
        startTime: startTime,
        commandLine: commandLine.isEmpty ? null : commandLine,
        runsAsSystem: runsAsSystem,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OTA] queryOsTask failed: $e');
      }
      return (
        exists: false,
        startTime: null,
        commandLine: null,
        runsAsSystem: false,
      );
    }
  }

  static String _normalizeRunCommand(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return '';
    s = s.replaceAll(r'\\', r'\');
    s = s.replaceAll('"', '');
    while (s.contains('  ')) {
      s = s.replaceAll('  ', ' ');
    }
    return s;
  }

  static String _friendlyError(Object e, {required bool requestElevation}) {
    final raw = e.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('connection refused') ||
        lower.contains('failed host lookup') ||
        lower.contains('clientexception')) {
      return requestElevation
          ? translate('ota-err-uac-system')
          : translate('ota-err-connection');
    }
    if (lower.contains('elevation cancelled') ||
        lower.contains('no output (elevation')) {
      return translate('ota-err-uac-cancelled');
    }
    if (lower.contains('access is denied') || lower.contains('access denied')) {
      return requestElevation
          ? translate('ota-err-uac-system')
          : translate('ota-err-admin-required');
    }
    return raw
        .replaceFirst(RegExp(r'^StateError:\s*'), '')
        .replaceFirst(RegExp(r'^ClientException:\s*'), '')
        .trim();
  }

  static List<String> _createArgs({
    required String tr,
    required String st,
    required bool asSystem,
  }) {
    final args = <String>[
      '/Create',
      '/TN',
      taskName,
      '/TR',
      tr,
      '/SC',
      'DAILY',
      '/ST',
      st,
      '/RL',
      'HIGHEST',
      '/F',
    ];
    if (asSystem) {
      final fIndex = args.indexOf('/F');
      args.insertAll(fIndex, ['/RU', 'SYSTEM']);
    }
    return args;
  }

  static String _formatSchtasksTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String _taskRunValue(String exePath) {
    final escaped = exePath.replaceAll('"', r'\"');
    return '"$escaped" $argSilent';
  }

  static Future<void> _deleteTask({
    bool requestElevation = false,
    bool skipAdminIpc = false,
  }) async {
    taskRegistered = false;
    taskRunsAsSystem = false;
    final args = ['/Delete', '/TN', taskName, '/F'];
    try {
      await LocalMaintenanceService.runSchtasks(
        args,
        allowUacFallback: requestElevation,
        skipAdminIpc: skipAdminIpc,
      );
    } catch (_) {
      try {
        await Process.run('schtasks', args, runInShell: true);
      } catch (_) {}
    }
  }

  static bool readEnabledFromDisk() {
    try {
      final v =
          bind.getLocalFlutterOption(k: kOptionOtaSilentDailyEnabled).trim();
      if (v.isEmpty) return true;
      final s = v.toLowerCase();
      return s != 'n' && s != 'false' && s != '0';
    } catch (_) {
      return true;
    }
  }

  static TimeOfDay readTimeFromDisk() {
    try {
      final raw =
          bind.getLocalFlutterOption(k: kOptionOtaSilentDailyTime).trim();
      if (raw.isEmpty) return defaultScheduleTime;
      final parts = raw.split(':');
      if (parts.length >= 2) {
        final h = int.tryParse(parts[0].trim()) ?? defaultScheduleTime.hour;
        final m = int.tryParse(parts[1].trim()) ?? defaultScheduleTime.minute;
        return TimeOfDay(
          hour: h.clamp(0, 23),
          minute: m.clamp(0, 59),
        );
      }
    } catch (_) {}
    return defaultScheduleTime;
  }
}
