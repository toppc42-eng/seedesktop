import 'dart:convert';

import 'package:get/get.dart';

import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/license_api_router.dart';

class CloudSyncService {
  CloudSyncService._();

  /// Bumped when cloud OTP session is created or cleared so UI (e.g. title bar) can Obx-rebuild.
  static final RxInt authRevision = 0.obs;

  static void _touchAuthState() {
    authRevision.value++;
  }

  static String? _messageFromResponseBody(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final m = decoded['message'] ?? decoded['error'] ?? decoded['detail'];
        if (m != null) return m.toString();
      }
    } catch (_) {}
    return null;
  }

  /// Bind local-option key for the cloud OTP session (Settings → Account).
  static const String cloudAuthTokenKey = 'cloud_sync_auth_token';
  static const String _tokenKey = cloudAuthTokenKey;
  static const String _emailKey = 'cloud_sync_email';
  static const String _userNameKey = 'cloud_sync_user_name';
  static const String _displayNameKey = 'cloud_sync_display_name';
  static final Uri _requestOtpUri =
      Uri.parse('https://api.seedesktop.com/api/cloud/request_otp');
  static final Uri _verifyOtpUri =
      Uri.parse('https://api.seedesktop.com/api/cloud/verify_otp');
  static final Uri _syncUri =
      Uri.parse('https://api.seedesktop.com/api/cloud/sync');

  /// Latest cloud session token from bind (read on every call).
  static String get savedToken =>
      bind.mainGetLocalOption(key: cloudAuthTokenKey).trim();
  static String get savedEmail =>
      bind.mainGetLocalOption(key: _emailKey).trim();
  static String get savedUserName =>
      bind.mainGetLocalOption(key: _userNameKey).trim();
  static String get savedDisplayName =>
      bind.mainGetLocalOption(key: _displayNameKey).trim();

  static bool get hasToken => savedToken.isNotEmpty;

  /// Headers for VPS routes that require cloud OTP ([savedToken]).
  /// Sends `Authorization: Bearer` plus legacy header names the server accepts.
  static Map<String, String> apiAuthHeaders({bool includeJsonContentType = true}) {
    final headers = <String, String>{};
    if (includeJsonContentType) {
      headers['Content-Type'] = 'application/json';
    }
    final token = savedToken;
    if (token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
      headers['auth_token'] = token;
      headers['X-Auth-Token'] = token;
    }
    return headers;
  }

  static Future<void> clearToken() async {
    await bind.mainSetLocalOption(key: _tokenKey, value: '');
    _touchAuthState();
  }

  static Future<void> clearSession() async {
    await bind.mainSetLocalOption(key: _tokenKey, value: '');
    await bind.mainSetLocalOption(key: _emailKey, value: '');
    await bind.mainSetLocalOption(key: _userNameKey, value: '');
    await bind.mainSetLocalOption(key: _displayNameKey, value: '');
    _touchAuthState();
  }

  static Future<String?> requestOtp(String email) async {
    final normalized = email.trim();
    if (normalized.isEmpty) return 'Email is required';
    try {
      final response = await LicenseApiRouter.post(
        _requestOtpUri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'email': normalized}),
        requestTimeout: const Duration(seconds: 15),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }
      return _messageFromResponseBody(response.body) ??
          'OTP request failed (${response.statusCode})';
    } catch (_) {
      return 'Could not request OTP';
    }
  }

  static Future<String?> verifyOtp({
    required String email,
    required String otp,
  }) async {
    final normalizedEmail = email.trim();
    final normalizedOtp = otp.trim();
    if (normalizedEmail.isEmpty || normalizedOtp.length != 6) {
      return 'Invalid email or OTP';
    }
    try {
      final response = await LicenseApiRouter.post(
        _verifyOtpUri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'email': normalizedEmail, 'otp': normalizedOtp}),
        requestTimeout: const Duration(seconds: 15),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _messageFromResponseBody(response.body) ??
            'OTP verification failed (${response.statusCode})';
      }
      final decoded = jsonDecode(response.body);
      String token = '';
      if (decoded is Map<String, dynamic>) {
        token = (decoded['auth_token'] ?? '').toString().trim();
        if (token.isEmpty && decoded['data'] is Map<String, dynamic>) {
          token = (decoded['data']['auth_token'] ?? '').toString().trim();
        }
      }
      if (token.isEmpty) {
        return 'Missing auth token in server response';
      }
      await bind.mainSetLocalOption(key: _tokenKey, value: token);
      await bind.mainSetLocalOption(key: _emailKey, value: normalizedEmail);
      final profile = _extractProfileMap(decoded);
      if (profile != null) {
        final displayName = (profile['display_name'] ?? profile['name'] ?? '')
            .toString()
            .trim();
        final userName = (profile['username'] ??
                profile['user_name'] ??
                profile['name'] ??
                '')
            .toString()
            .trim();
        if (displayName.isNotEmpty) {
          await bind.mainSetLocalOption(
              key: _displayNameKey, value: displayName);
        }
        if (userName.isNotEmpty) {
          await bind.mainSetLocalOption(key: _userNameKey, value: userName);
        }
      }
      _touchAuthState();
      return null;
    } catch (_) {
      return 'Could not verify OTP';
    }
  }

  /// Cloud sync: uploads local address book entries, merges server response into Rust AB store.
  /// Returns `null` on success, or a user-visible error string.
  static Future<String?> runCloudSync() async {
    final token = savedToken.trim();
    if (token.isEmpty) {
      return 'Please connect to Cloud first — use “Connect to Cloud” to sign in.';
    }

    try {
      final localAbRaw = await bind.mainLoadAb();
      dynamic localDecoded;
      try {
        localDecoded = jsonDecode(localAbRaw.isEmpty ? '{}' : localAbRaw);
      } catch (_) {
        return 'Local address book data is invalid';
      }
      if (localDecoded is! Map<String, dynamic>) {
        return 'Local address book data is invalid';
      }

      final localEntries = localDecoded['ab_entries'];
      final List<dynamic> addressBookList =
          localEntries is List ? List<dynamic>.from(localEntries) : <dynamic>[];

      final body = jsonEncode({
        'address_book': addressBookList,
        'settings': <String, dynamic>{},
      });

      final response = await LicenseApiRouter.post(
        _syncUri,
        headers: apiAuthHeaders(),
        body: body,
        requestTimeout: const Duration(seconds: 30),
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        return _messageFromResponseBody(response.body) ??
            'Authentication failed. Please connect to Cloud again.';
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _messageFromResponseBody(response.body) ??
            'Cloud sync failed (${response.statusCode})';
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return 'Unexpected response from cloud';
      }

      final merged = _extractMergedAddressBook(decoded);
      if (merged == null) {
        return 'Server did not return address_book data';
      }

      final accessToken = (localDecoded['access_token'] ?? '').toString();
      final toSave = <String, dynamic>{
        'access_token': accessToken,
        'ab_entries': merged,
      };
      await bind.mainSaveAb(json: jsonEncode(toSave));
      await bind.mainLoadAb();
      return null;
    } catch (_) {
      return 'Could not sync with cloud. Check your network connection.';
    }
  }

  /// Parses merged `address_book` from API (array of folder/peer maps, or wrapped in `data`).
  static List<dynamic>? _extractMergedAddressBook(
      Map<String, dynamic> decoded) {
    dynamic raw = decoded['address_book'];
    if (raw == null && decoded['data'] is Map<String, dynamic>) {
      raw = (decoded['data'] as Map<String, dynamic>)['address_book'];
    }
    if (raw is List) {
      return List<dynamic>.from(raw);
    }
    return null;
  }

  static Map<String, dynamic>? _extractProfileMap(
      Map<String, dynamic> decoded) {
    if (decoded['user'] is Map<String, dynamic>) {
      return decoded['user'] as Map<String, dynamic>;
    }
    if (decoded['data'] is Map<String, dynamic>) {
      final data = decoded['data'] as Map<String, dynamic>;
      if (data['user'] is Map<String, dynamic>) {
        return data['user'] as Map<String, dynamic>;
      }
      return data;
    }
    return null;
  }

  /// Alias for [runCloudSync].
  static Future<String?> sync() => runCloudSync();
}
