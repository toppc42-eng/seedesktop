import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const String _kPrefsKey = 'rmm_custom_scripts_v1';

class RmmCustomScript {
  final String id;
  final String title;
  final String body;
  final int createdAtMs;
  final int updatedAtMs;

  const RmmCustomScript({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'createdAtMs': createdAtMs,
        'updatedAtMs': updatedAtMs,
      };

  factory RmmCustomScript.fromJson(Map<String, dynamic> j) {
    return RmmCustomScript(
      id: j['id'] as String? ?? '',
      title: j['title'] as String? ?? '',
      body: j['body'] as String? ?? '',
      createdAtMs: j['createdAtMs'] as int? ?? 0,
      updatedAtMs: j['updatedAtMs'] as int? ?? 0,
    );
  }
}

class RmmCustomScriptsStore {
  static Future<List<RmmCustomScript>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => RmmCustomScript.fromJson(
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<RmmCustomScript> scripts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kPrefsKey,
      jsonEncode(scripts.map((s) => s.toJson()).toList()),
    );
  }

  static Future<RmmCustomScript> add(String title, String body) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = RmmCustomScript(
      id: const Uuid().v4(),
      title: title.trim(),
      body: body,
      createdAtMs: now,
      updatedAtMs: now,
    );
    final list = await load();
    list.add(s);
    await save(list);
    return s;
  }

  static Future<void> update(RmmCustomScript s) async {
    final list = await load();
    final i = list.indexWhere((x) => x.id == s.id);
    if (i < 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    list[i] = RmmCustomScript(
      id: s.id,
      title: s.title.trim(),
      body: s.body,
      createdAtMs: s.createdAtMs,
      updatedAtMs: now,
    );
    await save(list);
  }

  static Future<void> deleteById(String id) async {
    final list = await load();
    list.removeWhere((x) => x.id == id);
    await save(list);
  }
}
