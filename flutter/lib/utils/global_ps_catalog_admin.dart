import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory unlock for editing the global PowerShell catalog (session only).
class GlobalPsCatalogAdminSession {
  GlobalPsCatalogAdminSession._();

  static bool unlocked = false;

  static void clear() => unlocked = false;
}

const String _kPwdHashPrefsKey = 'global_ps_catalog_admin_pwd_sha256';

/// Password for global catalog edit mode. Override at build time:
/// `--dart-define=PS_CATALOG_ADMIN_PASSWORD=...`
///
/// Verification uses SHA-256: either a hash stored in [SharedPreferences]
/// (after a future "change password" flow) or the hash of the compile-time
/// default / dart-define password when no custom hash exists.
class GlobalPsCatalogAdmin {
  GlobalPsCatalogAdmin._();

  static const String _password = String.fromEnvironment(
    'PS_CATALOG_ADMIN_PASSWORD',
    defaultValue: 'SeeDesk_PsCatalog_Admin',
  );

  static String _hash(String s) =>
      sha256.convert(utf8.encode(s.trim())).toString();

  static String get _defaultPasswordHash => _hash(_password);

  static Future<bool> verifyPassword(String input) async {
    final h = _hash(input);
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kPwdHashPrefsKey);
    if (stored != null && stored.isNotEmpty) {
      return h == stored;
    }
    return h == _defaultPasswordHash;
  }
}
