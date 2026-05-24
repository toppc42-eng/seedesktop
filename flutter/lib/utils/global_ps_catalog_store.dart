import 'dart:convert';

import 'package:flutter_hbb/utils/ps_commands_catalogue.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const String _kPrefsKey = 'global_ps_catalog_v1';

class GlobalPsCmdEntry {
  final String id;
  final String title;
  final String cmd;
  final String? hint;
  final List<String> params;

  const GlobalPsCmdEntry({
    required this.id,
    required this.title,
    required this.cmd,
    this.hint,
    this.params = const [],
  });

  PsCmd toPsCmd() => PsCmd(title, cmd, hint: hint, params: params);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'cmd': cmd,
        'hint': hint,
        'params': params,
      };

  factory GlobalPsCmdEntry.fromJson(Map<String, dynamic> j) {
    return GlobalPsCmdEntry(
      id: j['id'] as String? ?? '',
      title: j['title'] as String? ?? '',
      cmd: j['cmd'] as String? ?? '',
      hint: j['hint'] as String?,
      params: (j['params'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const [],
    );
  }

  GlobalPsCmdEntry copyWith({
    String? title,
    String? cmd,
    String? hint,
    List<String>? params,
  }) {
    return GlobalPsCmdEntry(
      id: id,
      title: title ?? this.title,
      cmd: cmd ?? this.cmd,
      hint: hint ?? this.hint,
      params: params ?? this.params,
    );
  }
}

class GlobalPsSectionEntry {
  final String id;
  final String group;
  final String label;
  final List<GlobalPsCmdEntry> cmds;

  const GlobalPsSectionEntry({
    required this.id,
    required this.group,
    required this.label,
    required this.cmds,
  });

  PsSection toPsSection() =>
      PsSection(group, label, cmds.map((c) => c.toPsCmd()).toList());

  Map<String, dynamic> toJson() => {
        'id': id,
        'group': group,
        'label': label,
        'cmds': cmds.map((c) => c.toJson()).toList(),
      };

  factory GlobalPsSectionEntry.fromJson(Map<String, dynamic> j) {
    final raw = j['cmds'] as List<dynamic>? ?? [];
    return GlobalPsSectionEntry(
      id: j['id'] as String? ?? '',
      group: j['group'] as String? ?? '',
      label: j['label'] as String? ?? '',
      cmds: raw
          .map((e) => GlobalPsCmdEntry.fromJson(
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>)))
          .toList(),
    );
  }
}

class GlobalPsCatalogStore {
  static Future<List<GlobalPsSectionEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      final map = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
      final list = map['sections'] as List<dynamic>? ?? [];
      return list
          .map((e) => GlobalPsSectionEntry.fromJson(
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<GlobalPsSectionEntry> sections) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kPrefsKey,
      jsonEncode({
        'v': 1,
        'sections': sections.map((s) => s.toJson()).toList(),
      }),
    );
  }

  /// Built-in catalogue plus global sections (append).
  static List<PsSection> mergeCatalogues(List<GlobalPsSectionEntry> global) {
    if (global.isEmpty) return psCatalogue;
    return [
      ...psCatalogue,
      ...global.map((s) => s.toPsSection()),
    ];
  }

  /// Same matching rules as [filterPsSections] for one global section.
  static List<GlobalPsSectionEntry> filterForQuery(
    List<GlobalPsSectionEntry> all,
    String query,
  ) {
    if (query.trim().isEmpty) return all;
    final q = query.toLowerCase();
    final out = <GlobalPsSectionEntry>[];
    for (final s in all) {
      final ps = s.toPsSection();
      final kept = s.cmds
          .where((c) => psCatalogItemMatchesQuery(ps, c.toPsCmd(), q))
          .toList();
      if (kept.isEmpty) continue;
      out.add(GlobalPsSectionEntry(
        id: s.id,
        group: s.group,
        label: s.label,
        cmds: kept,
      ));
    }
    return out;
  }

  static Future<void> addSection({
    required List<GlobalPsSectionEntry> current,
    required String group,
    required String label,
    required String title,
    required String cmd,
    String? hint,
    List<String> params = const [],
  }) async {
    final sid = const Uuid().v4();
    final cid = const Uuid().v4();
    final next = [
      ...current,
      GlobalPsSectionEntry(
        id: sid,
        group: group.trim(),
        label: label.trim(),
        cmds: [
          GlobalPsCmdEntry(
            id: cid,
            title: title.trim(),
            cmd: cmd.trim(),
            hint: (hint == null || hint.trim().isEmpty) ? null : hint.trim(),
            params: params,
          ),
        ],
      ),
    ];
    await save(next);
  }

  static Future<void> addCommandToSection({
    required List<GlobalPsSectionEntry> current,
    required String sectionId,
    required String title,
    required String cmd,
    String? hint,
    List<String> params = const [],
  }) async {
    final cid = const Uuid().v4();
    final next = current.map((s) {
      if (s.id != sectionId) return s;
      return GlobalPsSectionEntry(
        id: s.id,
        group: s.group,
        label: s.label,
        cmds: [
          ...s.cmds,
          GlobalPsCmdEntry(
            id: cid,
            title: title.trim(),
            cmd: cmd.trim(),
            hint: (hint == null || hint.trim().isEmpty) ? null : hint.trim(),
            params: params,
          ),
        ],
      );
    }).toList();
    await save(next);
  }

  static Future<void> updateSectionMeta({
    required List<GlobalPsSectionEntry> current,
    required String sectionId,
    required String group,
    required String label,
  }) async {
    final next = current.map((s) {
      if (s.id != sectionId) return s;
      return GlobalPsSectionEntry(
        id: s.id,
        group: group.trim(),
        label: label.trim(),
        cmds: s.cmds,
      );
    }).toList();
    await save(next);
  }

  static Future<void> updateCommand({
    required List<GlobalPsSectionEntry> current,
    required String sectionId,
    required String commandId,
    required String title,
    required String cmd,
    String? hint,
    List<String> params = const [],
  }) async {
    final next = current.map((s) {
      if (s.id != sectionId) return s;
      return GlobalPsSectionEntry(
        id: s.id,
        group: s.group,
        label: s.label,
        cmds: s.cmds.map((c) {
          if (c.id != commandId) return c;
          return GlobalPsCmdEntry(
            id: c.id,
            title: title.trim(),
            cmd: cmd.trim(),
            hint: (hint == null || hint.trim().isEmpty) ? null : hint.trim(),
            params: params,
          );
        }).toList(),
      );
    }).toList();
    await save(next);
  }

  static Future<void> deleteSection({
    required List<GlobalPsSectionEntry> current,
    required String sectionId,
  }) async {
    await save(current.where((s) => s.id != sectionId).toList());
  }

  static Future<void> deleteCommand({
    required List<GlobalPsSectionEntry> current,
    required String sectionId,
    required String commandId,
  }) async {
    final next = <GlobalPsSectionEntry>[];
    for (final s in current) {
      if (s.id != sectionId) {
        next.add(s);
        continue;
      }
      final cmds = s.cmds.where((c) => c.id != commandId).toList();
      if (cmds.isEmpty) continue;
      next.add(GlobalPsSectionEntry(
        id: s.id,
        group: s.group,
        label: s.label,
        cmds: cmds,
      ));
    }
    await save(next);
  }
}
