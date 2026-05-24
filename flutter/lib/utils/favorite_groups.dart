import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kFavoriteGroupsPrefsKey = 'favorite_groups';
const String _kFavoritePeerGroupMapPrefsKey = 'favorite_peer_group_map';
const String _kFavoriteGroupIconsPrefsKey = 'favorite_group_icons';
const String kDefaultFavoriteGroup = 'General';

/// `*` = any substring, `?` = single character (glob). Without `*`/`?`, matches if [folderName] contains [pattern]. Case-insensitive.
bool folderMatchesWildcard(String pattern, String folderName) {
  final p = pattern.trim().toLowerCase();
  if (p.isEmpty) return true;
  final n = folderName.toLowerCase();
  if (!p.contains('*') && !p.contains('?')) {
    return n.contains(p);
  }
  try {
    final regexStr = globSimpleToRegex(p);
    return RegExp(regexStr, caseSensitive: false).hasMatch(n);
  } catch (_) {
    return n.contains(p);
  }
}

/// Minimal glob: only `*` and `?`, no character classes.
String globSimpleToRegex(String glob) {
  final buf = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      buf.write('.*');
    } else if (c == '?') {
      buf.write('.');
    } else if (RegExp(r'[\^$.*+?()\[\]{}|\\]').hasMatch(c)) {
      buf.write('\\$c');
    } else {
      buf.write(c);
    }
  }
  buf.write(r'$');
  return buf.toString();
}

class FavoriteGroupsStore {
  static Future<List<String>> loadGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_kFavoriteGroupsPrefsKey) ?? [];
    final groups = <String>{kDefaultFavoriteGroup};
    for (final group in saved) {
      final normalized = _normalizeGroup(group);
      if (normalized != null) {
        groups.add(normalized);
      }
    }
    final result = groups.toList()..sort((a, b) => a.compareTo(b));
    await prefs.setStringList(_kFavoriteGroupsPrefsKey, result);
    return result;
  }

  static Future<void> addGroup(String group) async {
    final normalized = _normalizeGroup(group);
    if (normalized == null) return;
    final prefs = await SharedPreferences.getInstance();
    final groups = await loadGroups();
    if (!groups.contains(normalized)) {
      groups.add(normalized);
      groups.sort((a, b) => a.compareTo(b));
      await prefs.setStringList(_kFavoriteGroupsPrefsKey, groups);
    }
  }

  static Future<void> removeGroup(String group) async {
    final normalized = _normalizeGroup(group);
    if (normalized == null || normalized == kDefaultFavoriteGroup) return;

    final prefs = await SharedPreferences.getInstance();
    final groups = await loadGroups();
    if (groups.remove(normalized)) {
      await prefs.setStringList(_kFavoriteGroupsPrefsKey, groups);
    }

    final iconMap = await loadGroupIcons();
    if (iconMap.remove(normalized) != null) {
      await saveGroupIcons(iconMap);
    }

    final map = await loadPeerGroups();
    var changed = false;
    for (final entry in map.entries.toList()) {
      if (entry.value == normalized) {
        map[entry.key] = kDefaultFavoriteGroup;
        changed = true;
      }
    }
    if (changed) {
      await savePeerGroups(map);
    }
  }

  static Future<void> renameGroup(String oldGroup, String newGroup) async {
    final oldNormalized = _normalizeGroup(oldGroup);
    final newNormalized = _normalizeGroup(newGroup);
    if (oldNormalized == null ||
        newNormalized == null ||
        oldNormalized == kDefaultFavoriteGroup) {
      return;
    }
    if (oldNormalized == newNormalized) return;

    final prefs = await SharedPreferences.getInstance();
    final groups = await loadGroups();
    if (!groups.contains(oldNormalized)) return;
    if (groups.contains(newNormalized)) return;

    final updatedGroups = groups
        .map((g) => g == oldNormalized ? newNormalized : g)
        .toList()
      ..sort((a, b) => a.compareTo(b));
    await prefs.setStringList(_kFavoriteGroupsPrefsKey, updatedGroups);

    final map = await loadPeerGroups();
    var changed = false;
    for (final entry in map.entries.toList()) {
      if (entry.value == oldNormalized) {
        map[entry.key] = newNormalized;
        changed = true;
      }
    }
    if (changed) {
      await savePeerGroups(map);
    }
    await _renameGroupIcon(oldNormalized, newNormalized);
  }

  static Future<void> _renameGroupIcon(String oldGroup, String newGroup) async {
    final icons = await loadGroupIcons();
    final cp = icons.remove(oldGroup);
    if (cp != null) {
      icons[newGroup] = cp;
      await saveGroupIcons(icons);
    }
  }

  static Future<Map<String, int>> loadGroupIcons() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFavoriteGroupIconsPrefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map<String, int>((key, value) {
        final int? v = value is int
            ? value
            : value is num
                ? value.toInt()
                : int.tryParse(value.toString());
        if (v == null || v <= 0) {
          return MapEntry(key.toString(), Icons.folder_outlined.codePoint);
        }
        return MapEntry(key.toString(), v);
      });
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveGroupIcons(Map<String, int> value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kFavoriteGroupIconsPrefsKey,
        jsonEncode(value.map((k, v) => MapEntry(k, v))));
  }

  static Future<void> setGroupIcon(String group, int? iconCodePoint) async {
    final normalized = _normalizeGroup(group);
    if (normalized == null) return;
    final icons = await loadGroupIcons();
    if (iconCodePoint == null) {
      icons.remove(normalized);
    } else {
      icons[normalized] = iconCodePoint;
    }
    await saveGroupIcons(icons);
  }

  static Future<Map<String, String>> loadPeerGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFavoritePeerGroupMapPrefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map<String, String>((key, value) {
        final id = key.toString();
        final group = _normalizeGroup(value.toString()) ?? kDefaultFavoriteGroup;
        return MapEntry(id, group);
      });
    } catch (_) {
      return {};
    }
  }

  static Future<void> savePeerGroups(Map<String, String> value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFavoritePeerGroupMapPrefsKey, jsonEncode(value));
  }

  static Future<void> assignPeerToGroup(String peerId, String group) async {
    final normalized = _normalizeGroup(group) ?? kDefaultFavoriteGroup;
    await addGroup(normalized);
    final map = await loadPeerGroups();
    map[peerId] = normalized;
    await savePeerGroups(map);
  }

  static Future<void> removePeer(String peerId) async {
    final map = await loadPeerGroups();
    map.remove(peerId);
    await savePeerGroups(map);
  }

  static Future<void> ensureDefaultsForFavorites(List<String> favoriteIds) async {
    // Keep existing folder mapping stable across startup/restore windows where
    // favorites may still be loading (temporary empty list). We must never
    // wipe mappings in this phase, otherwise all peers fall back to "General".
    if (favoriteIds.isEmpty) {
      await addGroup(kDefaultFavoriteGroup);
      return;
    }
    final map = await loadPeerGroups();
    var changed = false;
    for (final id in favoriteIds) {
      if (!map.containsKey(id)) {
        map[id] = kDefaultFavoriteGroup;
        changed = true;
      }
    }
    if (changed) {
      await savePeerGroups(map);
    }
    await addGroup(kDefaultFavoriteGroup);
  }

  static String? _normalizeGroup(String? value) {
    final group = (value ?? '').trim();
    if (group.isEmpty) return null;
    return group;
  }
}

Future<String?> showFavoriteGroupDialog(
  BuildContext context, {
  String title = 'Select Favorites Group',
  String? initialGroup,
  String confirmLabel = 'Save',
}) async {
  final loadedGroups = await FavoriteGroupsStore.loadGroups();
  var selectedGroup =
      loadedGroups.contains(initialGroup) ? initialGroup! : kDefaultFavoriteGroup;
  final newGroupController = TextEditingController();

  final result = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Group'),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: loadedGroups.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, index) {
                      final group = loadedGroups[index];
                      final selected = group == selectedGroup;
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () {
                          setState(() {
                            selectedGroup = group;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).dividerColor,
                            ),
                            color: selected
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withOpacity(0.08)
                                : Colors.transparent,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  group,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (selected)
                                Icon(
                                  Icons.check,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: newGroupController,
                  decoration: InputDecoration(
                    labelText: 'Create new group',
                    suffixIcon: IconButton(
                      tooltip: 'Add',
                      onPressed: () {
                        final newGroup = newGroupController.text.trim();
                        if (newGroup.isEmpty || loadedGroups.contains(newGroup)) {
                          return;
                        }
                        setState(() {
                          loadedGroups.add(newGroup);
                          loadedGroups.sort((a, b) => a.compareTo(b));
                          selectedGroup = newGroup;
                          newGroupController.clear();
                        });
                      },
                      icon: const Icon(Icons.add),
                    ),
                  ),
                  onSubmitted: (_) {
                    final newGroup = newGroupController.text.trim();
                    if (newGroup.isEmpty || loadedGroups.contains(newGroup)) {
                      return;
                    }
                    setState(() {
                      loadedGroups.add(newGroup);
                      loadedGroups.sort((a, b) => a.compareTo(b));
                      selectedGroup = newGroup;
                      newGroupController.clear();
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(selectedGroup),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    ),
  );

  newGroupController.dispose();
  if (result != null) {
    await FavoriteGroupsStore.addGroup(result);
  }
  return result;
}
