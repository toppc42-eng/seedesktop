import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_hbb/utils/user_menu_layout_model.dart';

const String _kPrefsKey = 'user_menu_layout_v1';

class UserMenuLayoutStore {
  static Future<UserMenuLayoutDocument> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw == null || raw.isEmpty) {
      return UserMenuLayoutDocument.empty();
    }
    try {
      final map = jsonDecode(raw);
      if (map is Map<String, dynamic>) {
        return UserMenuLayoutDocument.fromJson(map);
      }
      if (map is Map) {
        return UserMenuLayoutDocument.fromJson(
            Map<String, dynamic>.from(map));
      }
    } catch (_) {}
    return UserMenuLayoutDocument.empty();
  }

  static Future<void> save(UserMenuLayoutDocument doc) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsKey, jsonEncode(doc.toJson()));
  }
}
