import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/utils/agent_heartbeat_manager.dart';
import 'package:flutter_hbb/utils/license_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const _kScriptsKey = 'rmm_maintenance_saved_scripts_v1';
const _kAutorunKey = 'rmm_maintenance_autorun_tasks_v1';

/// Saved PowerShell / shell snippet for RMM (queue_command).
class RmmSavedScript {
  RmmSavedScript({
    required this.id,
    required this.name,
    required this.content,
    required this.updatedMs,
  });

  final String id;
  final String name;
  final String content;
  final int updatedMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'content': content,
        'updatedMs': updatedMs,
      };

  factory RmmSavedScript.fromJson(Map<String, dynamic> m) {
    return RmmSavedScript(
      id: m['id']?.toString() ?? '',
      name: m['name']?.toString() ?? '',
      content: m['content']?.toString() ?? '',
      updatedMs: (m['updatedMs'] is num) ? (m['updatedMs'] as num).toInt() : 0,
    );
  }
}

/// Recurrence for scheduled maintenance commands.
enum RmmAutorunRecurrence { once, daily, weekly }

/// Queued maintenance task: run [scriptId] on agents parsed from [agentIdsRaw] at [schedule].
class RmmAutorunTask {
  RmmAutorunTask({
    required this.id,
    required this.taskName,
    required this.agentIdsRaw,
    required this.scriptId,
    required this.hour,
    required this.minute,
    required this.recurrence,
    required this.enabled,
    this.lastRunMs,
    this.nextRunMs,
  });

  final String id;
  final String taskName;
  /// Comma / newline / semicolon separated peer IDs.
  final String agentIdsRaw;
  final String scriptId;
  final int hour;
  final int minute;
  final RmmAutorunRecurrence recurrence;
  final bool enabled;
  final int? lastRunMs;
  final int? nextRunMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'taskName': taskName,
        'agentIdsRaw': agentIdsRaw,
        'scriptId': scriptId,
        'hour': hour,
        'minute': minute,
        'recurrence': recurrence.index,
        'enabled': enabled,
        'lastRunMs': lastRunMs,
        'nextRunMs': nextRunMs,
      };

  factory RmmAutorunTask.fromJson(Map<String, dynamic> m) {
    final ri = m['recurrence'];
    var r = RmmAutorunRecurrence.daily;
    if (ri is int && ri >= 0 && ri < RmmAutorunRecurrence.values.length) {
      r = RmmAutorunRecurrence.values[ri];
    }
    return RmmAutorunTask(
      id: m['id']?.toString() ?? '',
      taskName: m['taskName']?.toString() ?? '',
      agentIdsRaw: m['agentIdsRaw']?.toString() ?? '',
      scriptId: m['scriptId']?.toString() ?? '',
      hour: (m['hour'] is num) ? (m['hour'] as num).toInt().clamp(0, 23) : 9,
      minute: (m['minute'] is num) ? (m['minute'] as num).toInt().clamp(0, 59) : 0,
      recurrence: r,
      enabled: m['enabled'] == true,
      lastRunMs: m['lastRunMs'] is num ? (m['lastRunMs'] as num).toInt() : null,
      nextRunMs: m['nextRunMs'] is num ? (m['nextRunMs'] as num).toInt() : null,
    );
  }

  RmmAutorunTask copyWith({
    String? id,
    String? taskName,
    String? agentIdsRaw,
    String? scriptId,
    int? hour,
    int? minute,
    RmmAutorunRecurrence? recurrence,
    bool? enabled,
    int? lastRunMs,
    int? nextRunMs,
  }) {
    return RmmAutorunTask(
      id: id ?? this.id,
      taskName: taskName ?? this.taskName,
      agentIdsRaw: agentIdsRaw ?? this.agentIdsRaw,
      scriptId: scriptId ?? this.scriptId,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      recurrence: recurrence ?? this.recurrence,
      enabled: enabled ?? this.enabled,
      lastRunMs: lastRunMs ?? this.lastRunMs,
      nextRunMs: nextRunMs ?? this.nextRunMs,
    );
  }
}

/// Loads / saves scripts and autorun tasks in [SharedPreferences].
class RmmMaintenanceStore {
  static Future<List<RmmSavedScript>> loadScripts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kScriptsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>?;
      if (list == null) return [];
      return list
          .map((e) => RmmSavedScript.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((s) => s.id.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveScripts(List<RmmSavedScript> scripts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kScriptsKey, jsonEncode(scripts.map((s) => s.toJson()).toList()));
  }

  static Future<List<RmmAutorunTask>> loadAutorunTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kAutorunKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>?;
      if (list == null) return [];
      return list
          .map((e) => RmmAutorunTask.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((t) => t.id.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAutorunTasks(List<RmmAutorunTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kAutorunKey, jsonEncode(tasks.map((t) => t.toJson()).toList()));
  }
}

/// Parses agent id tokens from free text (commas, semicolons, newlines).
List<String> parseRmmAgentIdTokens(String raw) {
  final out = <String>[];
  for (final part in raw.split(RegExp(r'[\s,;]+'))) {
    final t = part.trim();
    if (t.isEmpty) continue;
    final n = normalizePeerIdForLicenseTracking(t);
    if (n.isNotEmpty) out.add(n);
  }
  return out;
}

int _nextRunAfter(
  DateTime from,
  int hour,
  int minute,
  RmmAutorunRecurrence recurrence,
) {
  DateTime candidate = DateTime(from.year, from.month, from.day, hour, minute);
  if (!candidate.isAfter(from)) {
    candidate = candidate.add(const Duration(days: 1));
  }
  switch (recurrence) {
    case RmmAutorunRecurrence.once:
    case RmmAutorunRecurrence.daily:
      return candidate.millisecondsSinceEpoch;
    case RmmAutorunRecurrence.weekly:
      while (!candidate.isAfter(from)) {
        candidate = candidate.add(const Duration(days: 7));
      }
      return candidate.millisecondsSinceEpoch;
  }
}

/// Runs due [RmmAutorunTask]s by posting [queueCommandRemote]. Best-effort.
Future<void> runDueAutorunTasks(List<RmmSavedScript> scripts) async {
  final now = DateTime.now();
  final nowMs = now.millisecondsSinceEpoch;
  var tasks = await RmmMaintenanceStore.loadAutorunTasks();
  if (tasks.isEmpty) return;

  final byScriptId = {for (final s in scripts) s.id: s};
  var changed = false;

  final next = <RmmAutorunTask>[];
  for (var t in tasks) {
    if (!t.enabled) {
      next.add(t);
      continue;
    }
    final nr = t.nextRunMs;
    if (nr != null && nr > nowMs) {
      next.add(t);
      continue;
    }
    final script = byScriptId[t.scriptId];
    if (script == null || script.content.trim().isEmpty) {
      next.add(t.copyWith(
        lastRunMs: nowMs,
        nextRunMs: _nextRunAfter(now.add(const Duration(minutes: 1)),
            t.hour, t.minute, t.recurrence),
      ));
      changed = true;
      continue;
    }
    final agents = parseRmmAgentIdTokens(t.agentIdsRaw);
    for (final aid in agents) {
      try {
        await queueCommandRemote(agentId: aid, command: script.content.trim());
      } catch (e) {
        debugPrint('[RmmAutorun] queue failed for $aid: $e');
      }
    }
    final last = nowMs;
    int? nxt;
    switch (t.recurrence) {
      case RmmAutorunRecurrence.once:
        nxt = null;
        break;
      case RmmAutorunRecurrence.daily:
        nxt = _nextRunAfter(
            DateTime.fromMillisecondsSinceEpoch(last).add(const Duration(seconds: 1)),
            t.hour,
            t.minute,
            RmmAutorunRecurrence.daily);
        break;
      case RmmAutorunRecurrence.weekly:
        nxt = DateTime.fromMillisecondsSinceEpoch(last)
            .add(const Duration(days: 7))
            .millisecondsSinceEpoch;
        break;
    }
    next.add(t.copyWith(
      lastRunMs: last,
      nextRunMs: nxt,
      enabled: t.recurrence == RmmAutorunRecurrence.once ? false : t.enabled,
    ));
    changed = true;
  }

  if (changed) {
    await RmmMaintenanceStore.saveAutorunTasks(next);
  }
}

/// Periodic check while the app runs (desktop). Does not replace OS schedulers.
class RmmAutorunScheduler {
  RmmAutorunScheduler._();
  static Timer? _timer;
  static bool _started = false;

  static void ensureStarted() {
    if (_started) return;
    _started = true;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    unawaited(_tick());
  }

  static Future<void> _tick() async {
    try {
      final scripts = await RmmMaintenanceStore.loadScripts();
      await runDueAutorunTasks(scripts);
    } catch (e) {
      debugPrint('[RmmAutorunScheduler] $e');
    }
  }
}

String generateRmmId() => const Uuid().v4();

/// Next run at [hour]:[minute] after [from] (tomorrow if today's slot passed). Weekly adds 7 days for first slot.
int computeFirstNextRunMs(
  int hour,
  int minute,
  RmmAutorunRecurrence r, [
  DateTime? from,
]) {
  final base = from ?? DateTime.now();
  var d = DateTime(base.year, base.month, base.day, hour, minute);
  if (!d.isAfter(base)) {
    d = d.add(const Duration(days: 1));
  }
  if (r == RmmAutorunRecurrence.weekly) {
    d = d.add(const Duration(days: 7));
  }
  return d.millisecondsSinceEpoch;
}
