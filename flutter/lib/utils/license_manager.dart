import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/license_debug_log_stub.dart'
    if (dart.library.io) 'package:flutter_hbb/utils/license_debug_log_io.dart';
import 'package:flutter_hbb/utils/license_api_router.dart';
import 'package:flutter_hbb/utils/license_restart.dart';
import 'package:flutter_hbb/utils/sdfree_account_trial.dart';

const String kLicenseServerBaseUrl = 'https://api.seedesktop.com/api';
const String kLicenseCheckEndpoint = '$kLicenseServerBaseUrl/check_license';
const String kLicenseStartSessionEndpoint =
    '$kLicenseServerBaseUrl/start_session';

/// When no license key: report active remote session so VPS / WordPress counts stay accurate.
const String kLicenseStartUnlicensedSessionEndpoint =
    '$kLicenseServerBaseUrl/start_unlicensed_session';
const String kLicenseReleaseConnectionEndpoint =
    '$kLicenseServerBaseUrl/release_connection';
const String kLicenseReleaseAllMySessionsEndpoint =
    '$kLicenseServerBaseUrl/release_all_my_sessions';
const String kLicenseGetActiveSessionsEndpoint =
    '$kLicenseServerBaseUrl/get_active_sessions';
const String kLicenseGetLicenseInfoEndpoint =
    '$kLicenseServerBaseUrl/get_license_info';
const String kLicenseHeartbeatEndpoint = '$kLicenseServerBaseUrl/heartbeat';
const String kJumboCreditsGetEndpoint =
    '$kLicenseServerBaseUrl/get_jumbo_credits';
const String kJumboCreditsConsumeEndpoint =
    '$kLicenseServerBaseUrl/consume_jumbo_credit';
const String kJumboBuyCreditsUrl = 'https://seedesktop.com/my-account/';
const String kLicenseCommunicationErrorMessage =
    'Communication error: Unable to connect to the license server. Check your internet connection.';
const String kLicenseExpiryIsoPrefsKey = 'license_expiry_iso_utc';
const String kLicenseIsExpiredPrefsKey = 'license_is_expired';
const String kLicenseGraceStartMsPrefsKey = 'license_grace_start_ms';
const String kLicenseGraceReasonPrefsKey = 'license_grace_reason';
const int kLicenseGracePeriodMs = 36 * 60 * 60 * 1000;

const String _kLegacySavedLicenseKey = 'saved_license';
const String _kPeerSessionMapKey = 'license_peer_sessions';
const String _kPendingPeerMapKey = 'license_pending_peer_sessions';
const int _kPendingPeerTtlMs = 2 * 60 * 1000;
const String _kHardwareIdPrefsKey = 'license_hardware_id';
const String kLicenseSessionTelemetryLogKey =
    'license_vps_session_telemetry_log';
const int _kTelemetryMaxEntries = 50;
const String kLicenseVpsUnlicensedTelemetryKey =
    'license_vps_unlicensed_telemetry_active';
const String _kLicenseDebugLogFileName = 'seedesktop_license_debug.log';
const List<int> _kReconnectBackoffSeconds = [2, 5, 10, 30];
const String _kForcedLicenseApiHost = 'api.seedesktop.com';
const String _kForcedRendezvousHost = 'api.seedesktop.com';
const FlutterSecureStorage _licenseSecureStorage = FlutterSecureStorage();
bool _startupSessionCleanupTriggered = false;
const Set<String> _kLicenseEndpointNames = <String>{
  'check_license',
  'start_session',
  'start_unlicensed_session',
  'release_connection',
  'release_all_my_sessions',
  'get_active_sessions',
  'get_license_info',
  'heartbeat',
  'get_jumbo_credits',
  'consume_jumbo_credit',
};

String _trimTrailingSlashes(String input) {
  var value = input.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

Future<Uri> _licenseUriFromDefault(String defaultEndpoint) async {
  final fallback = Uri.parse(defaultEndpoint);
  try {
    final configuredApiServer =
        _trimTrailingSlashes(await bind.mainGetApiServer());
    if (configuredApiServer.isEmpty) return fallback;
    final configuredUri = Uri.tryParse(configuredApiServer);
    if (configuredUri == null || configuredUri.host.trim().isEmpty) {
      return fallback;
    }
    final host = configuredUri.host.toLowerCase();
    if (host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '0.0.0.0' ||
        host == '::1') {
      // Never use localhost for mobile license checks.
      return fallback;
    }

    // Production VPS requires HTTPS for the license API.
    final normalizedHost =
        (host == _kForcedRendezvousHost || host == '77.42.68.134')
            ? _kForcedLicenseApiHost
            : configuredUri.host;
    final scheme = 'https';
    final port = configuredUri.hasPort ? configuredUri.port : 0;

    final baseSegments = configuredUri.pathSegments
        .where((segment) => segment.trim().isNotEmpty)
        .toList();
    if (baseSegments.isNotEmpty &&
        _kLicenseEndpointNames.contains(baseSegments.last.toLowerCase())) {
      baseSegments.removeLast();
    }
    if (!baseSegments.any((segment) => segment.toLowerCase() == 'api')) {
      baseSegments.add('api');
    }

    final endpointPath =
        fallback.pathSegments.isEmpty ? '' : fallback.pathSegments.last;
    if (endpointPath.isNotEmpty) {
      baseSegments.add(endpointPath);
    }

    return Uri(
      scheme: scheme,
      host: normalizedHost,
      port: port,
      pathSegments: baseSegments,
    );
  } catch (_) {
    return fallback;
  }
}

Future<http.Response> _licenseApiPost(
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
  Duration? requestTimeout,
}) {
  return LicenseApiRouter.post(
    uri,
    headers: headers,
    body: body,
    requestTimeout: requestTimeout,
  );
}

enum LicenseServerStatus {
  unknown,
  online,
  reconnecting,
}

class LicenseManager {
  LicenseManager._();
  static final LicenseManager instance = LicenseManager._();

  String get serverUrl => kLicenseServerBaseUrl;

  Future<String> _getCurrentLicenseKey() async {
    return (await getSavedLicenseKey())?.trim() ?? '';
  }

  Future<String> _getCurrentHardwareId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
  }

  Future<String> _getCurrentLocalComputerName() async {
    return _resolveLocalComputerNameForLicenseApi();
  }

  Future<void> trackSessionLocallyByKey(String key, String sessionId) async {
    await _trackSessionLocally(key, sessionId);
  }

  // 1) Fetch exact counters for license status UI.
  Future<Map<String, dynamic>> getActiveSessionsInfo() async {
    try {
      final currentLicenseKey = await _getCurrentLicenseKey();
      final currentHardwareId = await _getCurrentHardwareId();
      if (currentLicenseKey.isEmpty) {
        return {'success': false};
      }
      final endpointUri =
          await _licenseUriFromDefault(kLicenseGetActiveSessionsEndpoint);
      final response = await _licenseApiPost(
        endpointUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'license_key': currentLicenseKey}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        int totalSeats = data['allowed_connections'] ?? 0;
        int activeStations = data['active_stations'] ?? 0;
        List sessions = data['sessions'] ?? [];

        // Count sessions that belong to this local hardware ID.
        int myActiveConnections =
            sessions.where((s) => s['hardware_id'] == currentHardwareId).length;

        return {
          'success': true,
          'totalSeats': totalSeats,
          'activeStations': activeStations,
          'myConnections': myActiveConnections,
        };
      }
      return {'success': false};
    } catch (e) {
      return {'success': false};
    }
  }

  // 2) Start session with accurate target metadata.
  Future<String?> startSession(String targetPcName) async {
    try {
      final currentLicenseKey = await _getCurrentLicenseKey();
      final currentHardwareId = await _getCurrentHardwareId();
      final currentLocalComputerName = await _getCurrentLocalComputerName();
      if (currentLicenseKey.isEmpty || currentHardwareId.isEmpty) {
        return null;
      }
      final endpointUri =
          await _licenseUriFromDefault(kLicenseStartSessionEndpoint);
      final response = await _licenseApiPost(
        endpointUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'license_key': currentLicenseKey,
          'hardware_id': currentHardwareId,
          'computer_name': currentLocalComputerName,
          'target_pc': targetPcName,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final sessionId = data['session_id']?.toString() ?? '';
        if (sessionId.isNotEmpty) {
          await _trackSessionLocally(targetPcName, sessionId);
          await LicenseHeartbeatManager.instance.start();
        }
        return sessionId.isEmpty ? null : sessionId;
      } else if (response.statusCode == 403) {
        throw Exception('Seat Limit Reached');
      }
      return null;
    } catch (e) {
      rethrow;
    }
  }

  // 3) Release one specific session (fire-and-forget).
  void releaseConnection(String sessionId) {
    unawaited(() async {
      try {
        final err = await releaseConnectionBySessionId(sessionId);
        await _untrackSessionLocally(sessionId);
        if (err != null &&
            !err.toLowerCase().contains('not found') &&
            kDebugMode) {
          debugPrint('Release server warning (local slot cleared): $err');
        }
      } catch (e) {
        await _untrackSessionLocally(sessionId);
        if (kDebugMode) {
          debugPrint('Release error (local slot cleared): $e');
        }
      }
    }());
  }

  // 4) Startup cleanup for orphan sessions.
  void releaseAllMyOrphanSessions() {
    unawaited(Future.wait([
      _getCurrentLicenseKey(),
      _getCurrentHardwareId(),
    ]).then((values) async {
      final currentLicenseKey = values[0];
      final currentHardwareId = values[1];
      if (currentLicenseKey.isEmpty || currentHardwareId.isEmpty) return;
      try {
        final endpointUri =
            await _licenseUriFromDefault(kLicenseReleaseAllMySessionsEndpoint);
        final response = await _licenseApiPost(
          endpointUri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'license_key': currentLicenseKey,
            'hardware_id': currentHardwareId,
          }),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          await _savePeerSessionMap(<String, List<String>>{});
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('session_id');
          await prefs.setInt('active_connections', 0);
        }
      } catch (e) {
        debugPrint('Cleanup error: $e');
      }
    }));
  }
}

class LicenseVerifyResult {
  final bool approved;
  final bool isExpired;
  final String message;
  final int allowedConnections;
  final int activeConnections;
  final String expiryDateIsoUtc;
  int get maxConnections => allowedConnections;

  const LicenseVerifyResult({
    required this.approved,
    this.isExpired = false,
    required this.message,
    this.allowedConnections = 0,
    this.activeConnections = 0,
    this.expiryDateIsoUtc = '',
  });
}

class LicenseSessionResult {
  final bool approved;
  final bool limitReached;
  final String message;
  final String sessionId;
  final int allowedConnections;
  final int activeConnections;

  const LicenseSessionResult({
    required this.approved,
    required this.limitReached,
    required this.message,
    this.sessionId = '',
    this.allowedConnections = 0,
    this.activeConnections = 0,
  });
}

class ActiveLicenseSession {
  final String computerName;
  final String ip;
  final String hardwareId;

  /// VPS session id when present — keeps two controllers from collapsing when target_pc matches.
  final String sessionId;

  const ActiveLicenseSession({
    required this.computerName,
    required this.ip,
    this.hardwareId = '',
    this.sessionId = '',
  });
}

class ActiveSessionsResult {
  final bool success;
  final String message;
  final List<ActiveLicenseSession> sessions;
  final int totalSeats;
  final int occupiedSeats;
  final int myActiveConnections;

  const ActiveSessionsResult({
    required this.success,
    required this.message,
    this.sessions = const [],
    this.totalSeats = 0,
    this.occupiedSeats = 0,
    this.myActiveConnections = 0,
  });
}

String _maskLicenseLastFour(String normalized) {
  final alnum = normalized.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (alnum.isEmpty) return '????';
  final tail = alnum.length >= 4
      ? alnum.substring(alnum.length - 4)
      : alnum.padLeft(4, '0');
  return tail.toUpperCase();
}

/// SD-FREE-XXXX / SD-PRO-XXXX / SD-PRORMM-XXXX (last four key chars).
String maskLicense(String license) {
  final normalized = license.trim();
  final upper = normalized.toUpperCase();
  if (upper.startsWith('SD-PRORMM-')) {
    final body = normalized.length > 'SD-PRORMM-'.length
        ? normalized.substring('SD-PRORMM-'.length)
        : '';
    return 'SD-PRORMM-${_maskLicenseLastFour(body)}';
  }
  if (upper.startsWith('SD-FREE-')) {
    final body = normalized.length > 'SD-FREE-'.length
        ? normalized.substring('SD-FREE-'.length)
        : '';
    return 'SD-FREE-${_maskLicenseLastFour(body)}';
  }
  if (upper.startsWith('SD-')) {
    return 'SD-PRO-${_maskLicenseLastFour(normalized)}';
  }
  if (normalized.length <= 4) return normalized;
  return 'SD-PRO-${_maskLicenseLastFour(normalized)}';
}

int _toInt(dynamic value) {
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

const Map<String, int> _kMonthNameToNumber = <String, int>{
  'jan': 1,
  'january': 1,
  'feb': 2,
  'february': 2,
  'mar': 3,
  'march': 3,
  'apr': 4,
  'april': 4,
  'may': 5,
  'jun': 6,
  'june': 6,
  'jul': 7,
  'july': 7,
  'aug': 8,
  'august': 8,
  'sep': 9,
  'sept': 9,
  'september': 9,
  'oct': 10,
  'october': 10,
  'nov': 11,
  'november': 11,
  'dec': 12,
  'december': 12,
};

DateTime? _parseHumanReadableExpiryAsLocal(String rawValue) {
  final value = rawValue.trim();
  final m = RegExp(
    r'^([A-Za-z]{3,9})\s+(\d{1,2}),?\s*(\d{4})(?:\s+(\d{1,2})(?::(\d{1,2})(?::(\d{1,2}))?)?)?$',
  ).firstMatch(value);
  if (m == null) return null;
  final monthName = (m.group(1) ?? '').toLowerCase();
  final month = _kMonthNameToNumber[monthName];
  final day = int.tryParse(m.group(2) ?? '');
  final year = int.tryParse(m.group(3) ?? '');
  if (month == null || day == null || year == null) return null;
  final hour = int.tryParse(m.group(4) ?? '') ?? 23;
  final minute = int.tryParse(m.group(5) ?? '') ?? 59;
  final second = int.tryParse(m.group(6) ?? '') ?? 59;
  try {
    return DateTime(year, month, day, hour, minute, second);
  } catch (_) {
    return null;
  }
}

DateTime? _parseFlexibleExpiryAsLocal(String rawValue,
    {bool logOnFailure = false}) {
  var value = rawValue.trim();
  if (value.isEmpty) return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    value = '${value}T23:59:59';
  }
  if (value.contains(' ') && !value.contains('T')) {
    value = value.replaceFirst(' ', 'T');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed != null) {
    return parsed.isUtc ? parsed.toLocal() : parsed;
  }
  final human = _parseHumanReadableExpiryAsLocal(rawValue);
  if (human != null) {
    return human;
  }
  if (logOnFailure && kDebugMode) {
    debugPrint('[License] Failed to parse expiry_date: "$rawValue"');
  }
  return null;
}

String _normalizeExpiryIsoUtc(String rawValue) {
  final parsed = _parseFlexibleExpiryAsLocal(rawValue, logOnFailure: true);
  if (parsed == null) return '';
  return parsed.toUtc().toIso8601String();
}

DateTime? _parseExpiryAsLocal(String rawValue) {
  return _parseFlexibleExpiryAsLocal(rawValue);
}

bool _isExpiredByDate(String expiryIsoUtc) {
  final expiry = _parseExpiryAsLocal(expiryIsoUtc);
  if (expiry == null) return false;
  return DateTime.now().isAfter(expiry);
}

bool _isExpiredFromServerData({
  required String expiryIsoUtc,
  String? status,
  String? message,
}) {
  // Renewal date wins over textual status.
  // If server provides a valid expiry date and it is in the future, license is active.
  if (expiryIsoUtc.trim().isNotEmpty) {
    return _isExpiredByDate(expiryIsoUtc);
  }
  return _isExpiredMessage(status, message);
}

bool _isExpiredMessage(String? status, String? message) {
  final statusText = (status ?? '').trim().toLowerCase();
  final messageText = (message ?? '').trim().toLowerCase();
  return statusText == 'expired' ||
      messageText == 'license expired' ||
      messageText.contains('expired');
}

bool _isLicenseMissingMessage(String? status, String? message) {
  final statusText = (status ?? '').trim().toLowerCase();
  final messageText = (message ?? '').trim().toLowerCase();
  return statusText == 'not_found' ||
      statusText == 'license_not_found' ||
      statusText == 'missing' ||
      messageText == 'license not found' ||
      messageText.contains('license not found') ||
      messageText.contains('not found');
}

bool _shouldEnterGraceMode({
  required String status,
  required String message,
  required int totalSeats,
  required int occupiedSeats,
  required int myActiveConnections,
}) {
  final missing = _isLicenseMissingMessage(status, message);
  if (!missing) return false;
  return totalSeats == 0 && occupiedSeats == 0 && myActiveConnections == 0;
}

Future<void> clearLicenseGraceMode() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(kLicenseGraceStartMsPrefsKey);
  await prefs.remove(kLicenseGraceReasonPrefsKey);
}

Future<void> markLicenseGraceMode(String reason) async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (existing <= 0) {
    await prefs.setInt(
      kLicenseGraceStartMsPrefsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }
  await prefs.setString(kLicenseGraceReasonPrefsKey, reason);
  // Grace mode should behave like free mode, not expired mode.
  await prefs.setBool(kLicenseIsExpiredPrefsKey, false);
}

Future<bool> isLicenseInGraceMode() async {
  final prefs = await SharedPreferences.getInstance();
  final startMs = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (startMs <= 0) return false;
  final elapsed = DateTime.now().millisecondsSinceEpoch - startMs;
  return elapsed < kLicenseGracePeriodMs;
}

Future<int?> getLicenseGraceRemainingMs() async {
  final prefs = await SharedPreferences.getInstance();
  final startMs = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (startMs <= 0) return null;
  final elapsed = DateTime.now().millisecondsSinceEpoch - startMs;
  final remaining = kLicenseGracePeriodMs - elapsed;
  return remaining > 0 ? remaining : 0;
}

String _extractExpiryIsoUtc(Map<String, dynamic> payload) {
  const keys = <String>[
    'expiry_date',
    'expires_at',
    'valid_until',
    'expiry',
    'expiration_date',
  ];
  for (final key in keys) {
    final value = payload[key]?.toString() ?? '';
    final normalized = _normalizeExpiryIsoUtc(value);
    if (normalized.isNotEmpty) return normalized;
  }
  return '';
}

Future<void> _appendLicenseDebugLog({
  required String endpoint,
  required String licenseKey,
  required String reason,
}) async {
  try {
    final maskedLicense = _maskLicenseDebugValue(licenseKey);
    final line =
        '[${DateTime.now().toIso8601String()}] endpoint=$endpoint license_key=$maskedLicense reason=$reason\n';
    await appendLicenseDebugLogLine(_kLicenseDebugLogFileName, line);
  } catch (_) {
    // Hidden diagnostics only.
  }
}

String _maskLicenseDebugValue(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '';
  final separator = normalized.indexOf(':');
  if (separator > 0 && !normalized.toUpperCase().startsWith('SD-')) {
    final prefix = normalized.substring(0, separator);
    final body = normalized.substring(separator + 1);
    return '$prefix:${_maskLicenseLastFour(body)}';
  }
  return maskLicense(normalized);
}

Future<void> migrateSavedLicenseKeyToSecureStorage() async {
  final prefs = await SharedPreferences.getInstance();
  final legacyKey = prefs.getString(_kLegacySavedLicenseKey)?.trim();
  if (legacyKey != null && legacyKey.isNotEmpty) {
    final secureKey =
        (await _licenseSecureStorage.read(key: _kLegacySavedLicenseKey))
            ?.trim();
    if (secureKey == null || secureKey.isEmpty) {
      await _licenseSecureStorage.write(
        key: _kLegacySavedLicenseKey,
        value: legacyKey,
      );
      await prefs.setString('masked_license', maskLicense(legacyKey));
    }
  }
  await prefs.remove(_kLegacySavedLicenseKey);
}

Future<String?> getSavedLicenseKey() async {
  await migrateSavedLicenseKeyToSecureStorage();
  final key =
      (await _licenseSecureStorage.read(key: _kLegacySavedLicenseKey))?.trim();
  return (key == null || key.isEmpty) ? null : key;
}

Future<void> _setSavedLicenseKey(String licenseKey) async {
  final key = licenseKey.trim();
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kLegacySavedLicenseKey);
  if (key.isEmpty) {
    await _licenseSecureStorage.delete(key: _kLegacySavedLicenseKey);
    return;
  }
  await _licenseSecureStorage.write(
    key: _kLegacySavedLicenseKey,
    value: key,
  );
}

Future<void> cacheHardwareId(String hardwareId) async {
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kHardwareIdPrefsKey, hwid);
}

Future<String?> releaseAllMySessionsByHardwareId(String hardwareId) async {
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) return null;
  try {
    final key = (await getSavedLicenseKey())?.trim() ?? '';
    final body = <String, dynamic>{
      'hardware_id': hwid,
    };
    if (key.isNotEmpty) {
      body['license_key'] = key;
    }
    final endpointUri =
        await _licenseUriFromDefault(kLicenseReleaseAllMySessionsEndpoint);
    final response = await _licenseApiPost(
      endpointUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        final releasedCount = _toInt(payload['released_count']);
        if (payload.containsKey('released_count') && releasedCount <= 0) {
          return payload['message']?.toString() ?? 'Session not found.';
        }
      } catch (_) {
        // Backward compatible with older server responses that return 2xx without JSON.
      }
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: 'hardware:$hwid',
        reason: 'HTTP 404 while calling release_all_my_sessions',
      );
    }
    try {
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      return payload['message']?.toString() ??
          'Failed to release all sessions (${response.statusCode}).';
    } catch (_) {
      return 'Failed to release all sessions (${response.statusCode}).';
    }
  } on TimeoutException {
    return kLicenseCommunicationErrorMessage;
  } catch (_) {
    return kLicenseCommunicationErrorMessage;
  }
}

Future<void> performStartupSessionCleanup({
  required String hardwareId,
}) async {
  if (_startupSessionCleanupTriggered) return;
  _startupSessionCleanupTriggered = true;
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) return;

  // Release only the specific stale session IDs stored locally from a previous
  // unclean shutdown — never call release_all_my_sessions which kills sessions
  // that belong to OTHER machines sharing the same floating license key.
  final staleMap = await _loadPeerSessionMap();
  for (final entry in staleMap.entries) {
    for (final sid in entry.value) {
      if (sid.trim().isEmpty) continue;
      await releaseConnectionBySessionId(sid);
    }
  }

  await _savePeerSessionMap(<String, List<String>>{});
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('session_id');
  await prefs.setInt('active_connections', 0);
  if (kDebugMode) {
    debugPrint(
        '[License] Startup cleanup: released ${staleMap.length} stale local entries');
  }
}

/// Public: same normalization as [_normalizePeerIdForLicenseMap], plus
/// `peerId##displayN` tab keys used on desktop.
String normalizePeerIdForLicenseTracking(String raw) {
  var t = raw.trim();
  final multi = RegExp(r'^(.+)##display\d+$').firstMatch(t);
  if (multi != null) {
    t = multi.group(1)!;
  }
  return _normalizePeerIdForLicenseMap(t);
}

/// One canonical peer id per remote (numeric RustDesk id, or last segment if no digits).
String _normalizePeerIdForLicenseMap(String key) {
  final trimmed = key.trim();
  if (trimmed.isEmpty) return '';
  final paren = RegExp(r'\((\d+)\)\s*$').firstMatch(trimmed);
  if (paren != null) {
    return paren.group(1)!;
  }
  final at = trimmed.indexOf('@');
  if (at > 0) {
    final beforeAt = trimmed.substring(0, at).replaceAll(' ', '');
    if (RegExp(r'^\d+$').hasMatch(beforeAt)) {
      return beforeAt;
    }
  }
  final noSpaces = trimmed.replaceAll(' ', '');
  if (RegExp(r'^\d+$').hasMatch(noSpaces)) {
    return noSpaces;
  }
  return noSpaces;
}

Map<String, List<String>> _mergePeerSessionMapByNormalizedKeys(
    Map<String, List<String>> raw) {
  final merged = <String, List<String>>{};
  raw.forEach((k, v) {
    final nk = normalizePeerIdForLicenseTracking(k);
    if (nk.isEmpty) return;
    final prev = merged[nk] ?? <String>[];
    final combined = [...prev, ...v];
    if (combined.isEmpty) {
      merged[nk] = <String>[];
    } else {
      merged[nk] = [combined.last];
    }
  });
  return merged;
}

Future<Map<String, List<String>>> loadPeerSessionMapPublic() =>
    _loadPeerSessionMap();

Future<Map<String, List<String>>> _loadPeerSessionMap() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kPeerSessionMapKey);
  if (raw == null || raw.trim().isEmpty) return <String, List<String>>{};
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final result = <String, List<String>>{};
    decoded.forEach((k, v) {
      if (v is List) {
        result[k] = v
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      } else {
        // Backward compatibility with old storage shape: { peerId: sessionId }
        final sid = v.toString().trim();
        result[k] = sid.isEmpty ? <String>[] : <String>[sid];
      }
    });
    return _mergePeerSessionMapByNormalizedKeys(result);
  } catch (_) {
    return <String, List<String>>{};
  }
}

Future<void> _savePeerSessionMap(Map<String, List<String>> value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kPeerSessionMapKey, jsonEncode(value));
}

/// Persists the peer→session map (e.g. after Rust-backed reconciliation in heartbeat).
Future<void> savePeerSessionMapPublic(Map<String, List<String>> value) =>
    _savePeerSessionMap(value);

Future<Map<String, int>> _loadPendingPeerMap() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kPendingPeerMapKey);
  if (raw == null || raw.trim().isEmpty) return <String, int>{};
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final result = <String, int>{};
    decoded.forEach((k, v) {
      final nk = normalizePeerIdForLicenseTracking(k);
      if (nk.isEmpty) return;
      final ts = int.tryParse(v.toString()) ?? 0;
      if (ts > 0) result[nk] = ts;
    });
    return result;
  } catch (_) {
    return <String, int>{};
  }
}

Future<void> _savePendingPeerMap(Map<String, int> value) async {
  final prefs = await SharedPreferences.getInstance();
  if (value.isEmpty) {
    await prefs.remove(_kPendingPeerMapKey);
    return;
  }
  await prefs.setString(_kPendingPeerMapKey, jsonEncode(value));
}

Future<Map<String, int>> _cleanupAndLoadPendingPeerMap() async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final pending = await _loadPendingPeerMap();
  final cleaned = <String, int>{};
  pending.forEach((k, v) {
    if (now - v <= _kPendingPeerTtlMs) cleaned[k] = v;
  });
  if (cleaned.length != pending.length) {
    await _savePendingPeerMap(cleaned);
  }
  return cleaned;
}

Future<void> markPendingLicenseConnectionPeer(String peerId) async {
  final nk = normalizePeerIdForLicenseTracking(peerId);
  if (nk.isEmpty) return;
  final pending = await _cleanupAndLoadPendingPeerMap();
  pending[nk] = DateTime.now().millisecondsSinceEpoch;
  await _savePendingPeerMap(pending);
}

Future<void> unmarkPendingLicenseConnectionPeer(String peerId) async {
  final nk = normalizePeerIdForLicenseTracking(peerId);
  if (nk.isEmpty) return;
  final pending = await _cleanupAndLoadPendingPeerMap();
  if (pending.remove(nk) != null) {
    await _savePendingPeerMap(pending);
  }
}

Future<void> _trackSessionLocally(String key, String sessionId) async {
  final normalizedKey = normalizePeerIdForLicenseTracking(key);
  final sid = sessionId.trim();
  if (normalizedKey.isEmpty || sid.isEmpty) return;
  final map = await _loadPeerSessionMap();
  // One license session id per peer (reconnect / duplicate UI paths replace stale id).
  map[normalizedKey] = [sid];
  await _savePeerSessionMap(map);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('session_id', sid);
  final localActive = map.values.where((v) => v.isNotEmpty).length;
  if (localActive > 0) {
    await prefs.setInt('active_connections', localActive);
  }
  await unmarkPendingLicenseConnectionPeer(normalizedKey);
}

Future<void> _untrackSessionLocally(String sessionId) async {
  final sid = sessionId.trim();
  if (sid.isEmpty) return;
  final map = await _loadPeerSessionMap();
  _removeSessionIdFromMap(map, sid);
  await _savePeerSessionMap(map);
  final prefs = await SharedPreferences.getInstance();
  if (map.isEmpty) {
    await prefs.remove('session_id');
    await prefs.setInt('active_connections', 0);
  }
}

Future<String?> getSessionIdForPeer(String peerId) async {
  final map = await _loadPeerSessionMap();
  final k = normalizePeerIdForLicenseTracking(peerId);
  final sessions = map[k];
  if (sessions == null || sessions.isEmpty) return null;
  return sessions.last;
}

/// Concurrent remote peers with an active license session (not raw session-id count).
Future<int> getActiveLicenseSessionCount() async {
  final map = await _loadPeerSessionMap();
  var n = 0;
  for (final sessions in map.values) {
    if (sessions.isNotEmpty) n += 1;
  }
  return n;
}

/// True if there is already an active license session to a different peer than [targetPeerId].
Future<bool> hasActiveLicenseSessionToOtherPeer(String targetPeerId) async {
  final target = normalizePeerIdForLicenseTracking(targetPeerId);
  if (target.isEmpty) return false;
  final pending = await _cleanupAndLoadPendingPeerMap();
  for (final entry in pending.entries) {
    if (entry.key != target) return true;
  }
  final map = await _loadPeerSessionMap();
  if (map.isEmpty) {
    // Peer map is source of truth; a non-zero active_connections with an empty
    // map is stale (crash, partial write, or older builds) and blocks all new
    // FREE/unlicensed connections until restart.
    final prefs = await SharedPreferences.getInstance();
    final stale = prefs.getInt('active_connections') ?? 0;
    if (stale > 0) {
      await prefs.setInt('active_connections', 0);
    }
    return false;
  }
  final anyActive = map.values.any((v) => v.isNotEmpty);
  // If there is an active session but target key is missing, treat it as "other peer"
  // to avoid bypasses caused by label/id formatting differences between windows.
  if (anyActive && !map.containsKey(target)) return true;
  for (final entry in map.entries) {
    if (entry.value.isEmpty) continue;
    if (entry.key != target) return true;
  }
  return false;
}

/// Peer id of an active session that is not [targetPeerId], if any (same logic as
/// [hasActiveLicenseSessionToOtherPeer]). Used for confirmation UI before switching.
Future<String?> getFirstOtherActivePeerId(String targetPeerId) async {
  final target = normalizePeerIdForLicenseTracking(targetPeerId);
  if (target.isEmpty) return null;
  final pending = await _cleanupAndLoadPendingPeerMap();
  for (final entry in pending.entries) {
    if (entry.key != target) return entry.key;
  }
  final map = await _loadPeerSessionMap();
  if (map.isEmpty) {
    final prefs = await SharedPreferences.getInstance();
    final stale = prefs.getInt('active_connections') ?? 0;
    if (stale > 0) {
      await prefs.setInt('active_connections', 0);
    }
    return null;
  }
  final anyActive = map.values.any((v) => v.isNotEmpty);
  if (anyActive && !map.containsKey(target)) {
    for (final entry in map.entries) {
      if (entry.value.isNotEmpty) return entry.key;
    }
  }
  for (final entry in map.entries) {
    if (entry.value.isEmpty) continue;
    if (entry.key != target) return entry.key;
  }
  return null;
}

String _localSyntheticSessionId(String peerId) {
  final pid = normalizePeerIdForLicenseTracking(peerId);
  return 'local-$pid-${DateTime.now().millisecondsSinceEpoch}';
}

Future<List<String>> getLocalLicenseSessionIds() async {
  final map = await _loadPeerSessionMap();
  final ids = <String>[];
  for (final sessions in map.values) {
    ids.addAll(sessions.where((s) => s.trim().isNotEmpty));
  }
  return ids;
}

/// License settings: rows from local peer/session map when the server omits session details.
Future<List<ActiveLicenseSession>>
    getLocalLicenseSessionsForSettingsDisplay() async {
  final map = await _loadPeerSessionMap();
  final hwid = await _getLocalHardwareId();
  final out = <ActiveLicenseSession>[];
  for (final e in map.entries) {
    if (e.value.isEmpty) continue;
    final id = e.key.trim();
    final sid = e.value.isNotEmpty ? e.value.last.trim() : '';
    out.add(
      ActiveLicenseSession(
        computerName: id.isEmpty ? 'Remote peer' : id,
        ip: '—',
        hardwareId: hwid,
        sessionId: sid,
      ),
    );
  }
  return out;
}

/// Merge VPS list with this machine's peer map.
/// Server rows take priority; local rows are only added if no server row
/// already covers the same remote peer (by extracted numeric peer ID).
List<ActiveLicenseSession> mergeActiveLicenseSessionDisplayRows(
  List<ActiveLicenseSession> server,
  List<ActiveLicenseSession> local,
) {
  final result = <ActiveLicenseSession>[...server];
  // Collect all peer IDs already present in the server list.
  final serverPeerIds = <String>{};
  for (final s in server) {
    final pid = _extractPeerIdFromSessionLabel(s.computerName);
    if (pid.isNotEmpty) serverPeerIds.add(pid);
  }
  // Only add local rows whose peer is not yet covered by a server row.
  for (final s in local) {
    final pid = _extractPeerIdFromSessionLabel(s.computerName);
    if (pid.isNotEmpty && serverPeerIds.contains(pid)) continue;
    result.add(s);
  }
  return result;
}

int _uiSessionRowQuality(ActiveLicenseSession s) {
  var n = 0;
  final ip = s.ip.trim().toLowerCase();
  if (ip.isNotEmpty && ip != '—' && ip != 'unknown ip') n += 200;
  n += s.computerName.length;
  if (s.computerName.contains('@')) n += 50;
  if (s.sessionId.isNotEmpty && !s.sessionId.startsWith('local-')) n += 10;
  return n;
}

/// One row per (controller workstation × remote peer). VPS may store duplicate
/// session_id rows for the same connection — collapse for UI + honest counts.
List<ActiveLicenseSession> dedupeActiveLicenseSessionsForUi(
  List<ActiveLicenseSession> rows,
) {
  final byKey = <String, ActiveLicenseSession>{};
  for (final s in rows) {
    final tgt = _extractPeerIdFromSessionLabel(s.computerName);
    final hw = s.hardwareId.trim().toLowerCase();
    final key = (hw.isNotEmpty && tgt.isNotEmpty)
        ? 'c:$hw|p:$tgt'
        : (tgt.isNotEmpty)
            ? 'p:$tgt'
            : (hw.isNotEmpty)
                ? 'h:$hw'
                : (s.sessionId.isNotEmpty)
                    ? 's:${s.sessionId}'
                    : 'r:${Object.hash(s.computerName, s.ip)}';
    final existing = byKey[key];
    if (existing == null ||
        _uiSessionRowQuality(s) > _uiSessionRowQuality(existing)) {
      byKey[key] = s;
    }
  }
  return byKey.values.toList();
}

/// Distinct controller machines among session rows (floating license seats).
int countDistinctControllerHardwareIds(List<ActiveLicenseSession> rows) {
  final set = <String>{};
  for (final s in rows) {
    final h = s.hardwareId.trim();
    if (h.isNotEmpty) set.add(h.toLowerCase());
  }
  return set.length;
}

void _removeSessionIdFromMap(Map<String, List<String>> map, String sessionId) {
  final sid = sessionId.trim();
  if (sid.isEmpty) return;
  final keysToRemove = <String>[];
  for (final entry in map.entries) {
    final updated = entry.value.where((s) => s != sid).toList();
    if (updated.isEmpty) {
      keysToRemove.add(entry.key);
    } else {
      map[entry.key] = updated;
    }
  }
  for (final key in keysToRemove) {
    map.remove(key);
  }
}

List<ActiveLicenseSession> _parseSessions(dynamic raw) {
  final sessions = <ActiveLicenseSession>[];
  if (raw is! List) return sessions;
  for (final entry in raw) {
    if (entry is! Map) continue;
    // Prefer target_pc so the list shows the remote target name/ID.
    final rawComputerName = entry['target_pc']?.toString().trim() ??
        entry['computer_name']?.toString().trim() ??
        '';
    final ip = entry['ip']?.toString().trim() ??
        entry['remote_ip']?.toString().trim() ??
        '';
    final hardwareId = entry['hardware_id']?.toString().trim() ?? '';
    final vpsSessionId = entry['session_id']?.toString().trim() ??
        entry['sessionid']?.toString().trim() ??
        '';
    final computerName = _normalizeComputerName(rawComputerName, entry);
    sessions.add(
      ActiveLicenseSession(
        computerName: computerName,
        ip: ip.isEmpty ? 'Unknown IP' : ip,
        hardwareId: hardwareId,
        sessionId: vpsSessionId,
      ),
    );
  }
  return _dedupeActiveSessions(sessions);
}

String _normalizeComputerName(String rawName, Map entry) {
  final raw = rawName.trim();
  if (raw.isEmpty) return 'Unknown computer';
  if (!raw.startsWith('{')) return raw;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      final peerId = decoded['id']?.toString().trim() ?? '';
      String hostname = '';
      final info = decoded['info'];
      if (info is Map<String, dynamic>) {
        hostname = info['hostname']?.toString().trim() ?? '';
      }
      if (hostname.isNotEmpty && peerId.isNotEmpty) {
        return '$hostname ($peerId)';
      }
      if (hostname.isNotEmpty) return hostname;
      if (peerId.isNotEmpty) return peerId;
    }
  } catch (_) {
    // Fall back to other known fields.
  }
  final fallbackId = entry['id']?.toString().trim() ?? '';
  if (fallbackId.isNotEmpty) return fallbackId;
  return 'Unknown computer';
}

String _extractPeerIdFromSessionLabel(String computerName) {
  final t = computerName.trim();
  if (t.isEmpty) return '';
  final paren = RegExp(r'\((\d+)\)\s*$').firstMatch(t);
  if (paren != null) return paren.group(1)!;
  // "380156890@relay-or-project" — same peer as bare "380156890".
  final at = t.indexOf('@');
  if (at > 0) {
    final beforeAt = t.substring(0, at).replaceAll(' ', '');
    if (RegExp(r'^\d+$').hasMatch(beforeAt)) {
      return beforeAt;
    }
  }
  final digits = t.replaceAll(' ', '');
  if (RegExp(r'^\d+$').hasMatch(digits)) return digits;
  return '';
}

String _activeSessionDedupeKey(ActiveLicenseSession s) {
  final sid = s.sessionId.trim().toLowerCase();
  if (sid.isNotEmpty) return 'sid:$sid';
  final hw = s.hardwareId.trim().toLowerCase();
  final tgt = _extractPeerIdFromSessionLabel(s.computerName);
  // Two controllers can share the same remote target id — must not collapse into one row.
  if (hw.isNotEmpty && tgt.isNotEmpty) return 'hw:$hw|tgt:$tgt';
  if (tgt.isNotEmpty) return 'tgt:$tgt';
  final ip = s.ip.trim().toLowerCase();
  if (ip.isNotEmpty && ip != 'unknown ip' && ip != '—') return 'ip:$ip';
  if (hw.isNotEmpty) return 'hw:$hw';
  return 'row:${Object.hash(s.computerName, s.ip, s.sessionId)}';
}

List<ActiveLicenseSession> _dedupeActiveSessions(
    List<ActiveLicenseSession> sessions) {
  final byKey = <String, ActiveLicenseSession>{};
  for (final s in sessions) {
    final k = _activeSessionDedupeKey(s);
    final existing = byKey[k];
    if (existing == null) {
      byKey[k] = s;
    } else if (s.computerName.length > existing.computerName.length) {
      byKey[k] = s;
    }
  }
  return byKey.values.toList();
}

dynamic _normalizeLicenseJsonValue(dynamic v) {
  if (v is Map) {
    final out = <String, dynamic>{};
    for (final e in v.entries) {
      final k = e.key is String ? (e.key as String).toLowerCase() : '${e.key}';
      out[k] = _normalizeLicenseJsonValue(e.value);
    }
    return out;
  }
  if (v is List) return v.map(_normalizeLicenseJsonValue).toList();
  return v;
}

Map<String, dynamic> _parseLicenseHttpJsonBody(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return {};
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is List) {
      return <String, dynamic>{'sessions': _normalizeLicenseJsonValue(decoded)};
    }
    if (decoded is Map) {
      final n = _normalizeLicenseJsonValue(decoded);
      if (n is Map<String, dynamic>) return n;
      if (n is Map) return Map<String, dynamic>.from(n);
    }
  } catch (_) {}
  return {};
}

Map<String, dynamic> _fieldsForLicenseSessionPayload(
    Map<String, dynamic> payload) {
  final data = payload['data'];
  if (data is Map) {
    final inner = Map<String, dynamic>.from(data);
    for (final k in <String>[
      'sessions',
      'active_sessions',
      'max_stations',
      'allowed_connections',
      'max_connections',
      'active_stations',
      'active_connections',
      'expiry_date',
      'expires_at',
      'valid_until',
      'expiry',
      'expiration_date',
    ]) {
      if (!inner.containsKey(k) && payload.containsKey(k)) {
        inner[k] = payload[k];
      }
    }
    return inner;
  }
  return payload;
}

bool _licenseStatusIndicatesOk(String? status) {
  final s = (status ?? '').trim().toLowerCase();
  return s == 'success' ||
      s == 'valid' ||
      s == 'ok' ||
      s == 'active' ||
      s == 'true' ||
      s == '1';
}

bool _licensePayloadHasSessionShape(Map<String, dynamic> fm) {
  return fm.containsKey('sessions') ||
      fm.containsKey('active_sessions') ||
      fm.containsKey('max_stations') ||
      fm.containsKey('allowed_connections') ||
      fm.containsKey('max_connections') ||
      fm.containsKey('active_stations') ||
      fm.containsKey('active_connections');
}

int _extractTotalSeats(Map<String, dynamic> payload) {
  if (payload.containsKey('allowed_connections')) {
    return _toInt(payload['allowed_connections']);
  }
  return _toInt(payload['max_connections']);
}

int _extractOccupiedSeats(Map<String, dynamic> payload) {
  if (payload.containsKey('active_stations')) {
    return _toInt(payload['active_stations']);
  }
  return _toInt(payload['active_connections']);
}

int _countMyActiveConnections(
  List<ActiveLicenseSession> sessions,
  String localHardwareId,
) {
  final hwid = localHardwareId.trim();
  if (hwid.isEmpty) return 0;
  return sessions.where((s) => s.hardwareId == hwid).length;
}

Future<String> _getLocalHardwareId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
}

Future<LicenseVerifyResult> verifyLicenseWithServer(String licenseKey) async {
  final key = licenseKey.trim();
  if (key.isEmpty) {
    return const LicenseVerifyResult(
      approved: false,
      message: 'License key is required.',
    );
  }

  try {
    final endpointUri = await _licenseUriFromDefault(kLicenseCheckEndpoint);
    final response = await _licenseApiPost(
      endpointUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'license_key': key}),
    );

    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}

    final serverMessage = payload['message']?.toString();
    final status = payload['status']?.toString().toLowerCase();
    final expiryDateIsoUtc = _extractExpiryIsoUtc(payload);
    final allowedConnections = _toInt(payload['allowed_connections']) > 0
        ? _toInt(payload['allowed_connections'])
        : _toInt(payload['max_connections']);
    final activeConnections = _toInt(payload['active_connections']);

    final approvedStatus = status == 'success' || status == 'valid';
    final isExpired = _isExpiredFromServerData(
      expiryIsoUtc: expiryDateIsoUtc,
      status: status,
      message: serverMessage,
    );
    final hasExpiry = expiryDateIsoUtc.trim().isNotEmpty;
    final approved = hasExpiry ? !isExpired : (approvedStatus && !isExpired);
    if (response.statusCode == 200 && approved) {
      return LicenseVerifyResult(
        approved: true,
        isExpired: false,
        message: serverMessage ?? 'Approved',
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
        expiryDateIsoUtc: expiryDateIsoUtc,
      );
    }

    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: key,
        reason: 'HTTP 404 while calling check_license',
      );
    }

    return LicenseVerifyResult(
      approved: false,
      isExpired: isExpired,
      message: isExpired
          ? (serverMessage ?? 'License expired')
          : (serverMessage ??
              'License verification failed (${response.statusCode}).'),
      allowedConnections: allowedConnections,
      activeConnections: activeConnections,
      expiryDateIsoUtc: expiryDateIsoUtc,
    );
  } on TimeoutException {
    return const LicenseVerifyResult(
      approved: false,
      message: kLicenseCommunicationErrorMessage,
    );
  } catch (_) {
    return const LicenseVerifyResult(
      approved: false,
      message: kLicenseCommunicationErrorMessage,
    );
  }
}

/// Resolves local PC display name for license API (hostname from Rust core).
Future<String> _resolveLocalComputerNameForLicenseApi() async {
  try {
    final raw = bind.mainGetLoginDeviceInfo();
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      final name = decoded['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) return name;
    }
  } catch (_) {}
  return 'Local PC';
}

Future<String> _appVersionLabel() async {
  try {
    return (await bind.mainGetVersion()).trim();
  } catch (_) {
    return '';
  }
}

/// Full JSON body for [POST /api/start_session] — matches WordPress "Active Sessions" fields:
/// connection time, country (filled server-side from IP), IP, target name, license association.
Future<Map<String, dynamic>> buildStartSessionVpsPayload({
  required String licenseKey,
  required String hardwareId,
  required String computerName,
  required String targetPc,
  String? peerId,
  String? remoteHostname,
  String? remoteUsername,
  String? remoteIp,
  String? connectedAtIso,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final cachedSeats = prefs.getInt('allowed_connections') ?? 0;
  return {
    'license_key': licenseKey,
    'hardware_id': hardwareId,
    'computer_name': computerName,
    'target_pc': targetPc,
    'peer_id': peerId ?? '',
    'connected_at': connectedAtIso ?? DateTime.now().toUtc().toIso8601String(),
    'remote_hostname': remoteHostname ?? '',
    'remote_username': remoteUsername ?? '',
    'remote_ip': remoteIp ?? '',
    'country': '',
    'app_version': await _appVersionLabel(),
    if (cachedSeats > 0) 'allowed_connections': cachedSeats,
  };
}

Future<void> _appendLocalSessionTelemetry(
    Map<String, dynamic> serverRow) async {
  try {
    final masked = Map<String, dynamic>.from(serverRow);
    final lk = masked['license_key']?.toString() ?? '';
    if (lk.isNotEmpty) {
      masked['license_key'] = maskLicense(lk);
    }
    final prefs = await SharedPreferences.getInstance();
    var list = <dynamic>[];
    final raw = prefs.getString(kLicenseSessionTelemetryLogKey);
    if (raw != null && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is List) list = decoded;
    }
    list.insert(0, masked);
    if (list.length > _kTelemetryMaxEntries) {
      list = list.sublist(0, _kTelemetryMaxEntries);
    }
    await prefs.setString(kLicenseSessionTelemetryLogKey, jsonEncode(list));
  } catch (_) {}
}

/// Last recorded session rows (license key masked) for local diagnostics / future UI.
Future<List<Map<String, dynamic>>> getLocalSessionTelemetryLog() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(kLicenseSessionTelemetryLogKey);
  if (raw == null || raw.trim().isEmpty) return [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  } catch (_) {
    return [];
  }
}

/// When the remote desktop stream is live (first frame), notify the VPS so dashboards
/// (e.g. Active Sessions) reflect an actually connected session. Does not block UI.
void reportEstablishedRemoteSessionToVps({
  required String targetPc,
  String? peerId,
  String? remoteHostname,
  String? remoteUsername,
  String? remoteIp,
}) {
  unawaited(_reportEstablishedRemoteSessionToVpsImpl(
    targetPc,
    peerId,
    remoteHostname: remoteHostname,
    remoteUsername: remoteUsername,
    remoteIp: remoteIp,
  ));
}

Future<void> _reportEstablishedRemoteSessionToVpsImpl(
  String targetPc,
  String? peerId, {
  String? remoteHostname,
  String? remoteUsername,
  String? remoteIp,
}) async {
  // startSession() (called before connect) already registered a VPS session
  // and stored the session_id locally. This post-connect callback only needs
  // to ensure the local tracking map is up-to-date; do NOT call start_session
  // again — that creates a duplicate row on the VPS.
  final pid = peerId?.trim() ?? '';
  if (pid.isEmpty) return;
  try {
    final existingSid = await getSessionIdForPeer(pid);
    if (existingSid != null && existingSid.isNotEmpty) {
      // Already tracked from startSession — nothing more to do.
      await LicenseHeartbeatManager.instance.start();
      return;
    }
    // Edge case: no session tracked yet (e.g. unlicensed or startSession skipped).
    final license = (await getSavedLicenseKey())?.trim() ?? '';
    final hardwareId = (await bind.mainGetUuid()).trim();
    if (hardwareId.isEmpty) return;
    final computerName = await _resolveLocalComputerNameForLicenseApi();
    final bodyMap = await buildStartSessionVpsPayload(
      licenseKey: license,
      hardwareId: hardwareId,
      computerName: computerName,
      targetPc: targetPc.trim(),
      peerId: peerId,
      remoteHostname: remoteHostname,
      remoteUsername: remoteUsername,
      remoteIp: remoteIp,
    );
    if (license.isEmpty) {
      await _postUnlicensedStartSessionAndTrack(
        bodyMap: bodyMap,
        hardwareId: hardwareId,
        peerId: peerId,
      );
      return;
    }
    final endpointUri =
        await _licenseUriFromDefault(kLicenseStartSessionEndpoint);
    http.Response? response;
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      try {
        response = await _licenseApiPost(
          endpointUri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap),
        );
        break;
      } catch (_) {
        if (i >= _kReconnectBackoffSeconds.length) return;
        await Future.delayed(Duration(seconds: _kReconnectBackoffSeconds[i]));
      }
    }
    if (response == null) return;
    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}
    final sessionId = payload['session_id']?.toString().trim() ?? '';
    if (response.statusCode == 200 && sessionId.isNotEmpty) {
      await _appendLocalSessionTelemetry(bodyMap);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHardwareIdPrefsKey, hardwareId);
      await prefs.setString('session_id', sessionId);
      if (pid.isNotEmpty) {
        await _trackSessionLocally(pid, sessionId);
      }
      await LicenseHeartbeatManager.instance.start();
    }
  } catch (_) {
    // Silent — connection UX must not depend on license telemetry.
  }
}

/// No [saved_license]: same telemetry payload with empty `license_key`.
/// Tries `POST /api/start_unlicensed_session`, then falls back to `start_session`.
Future<void> _postUnlicensedStartSessionAndTrack({
  required Map<String, dynamic> bodyMap,
  required String hardwareId,
  String? peerId,
}) async {
  Future<http.Response?> postWithRetry(Uri uri) async {
    http.Response? last;
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      try {
        last = await _licenseApiPost(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap),
        );
        return last;
      } catch (_) {
        if (i >= _kReconnectBackoffSeconds.length) return null;
        await Future.delayed(Duration(seconds: _kReconnectBackoffSeconds[i]));
      }
    }
    return null;
  }

  http.Response? response;
  try {
    final primary =
        await _licenseUriFromDefault(kLicenseStartUnlicensedSessionEndpoint);
    response = await postWithRetry(primary);
    if (response != null && response.statusCode == 404) {
      final fallback =
          await _licenseUriFromDefault(kLicenseStartSessionEndpoint);
      response = await postWithRetry(fallback);
    }
  } catch (_) {
    return;
  }
  if (response == null) return;
  Map<String, dynamic> payload = {};
  try {
    payload = jsonDecode(response.body) as Map<String, dynamic>;
  } catch (_) {}
  final sessionId = payload['session_id']?.toString().trim() ?? '';
  final st = payload['status']?.toString().toLowerCase() ?? '';
  final ok = response.statusCode == 200 &&
      sessionId.isNotEmpty &&
      (st == 'success' || st == 'valid' || st.isEmpty);
  if (!ok) return;
  await _appendLocalSessionTelemetry(bodyMap);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kHardwareIdPrefsKey, hardwareId);
  await prefs.setString('session_id', sessionId);
  final pid = peerId?.trim();
  if (pid != null && pid.isNotEmpty) {
    await _trackSessionLocally(pid, sessionId);
  }
  await prefs.setBool(kLicenseVpsUnlicensedTelemetryKey, true);
  await LicenseHeartbeatManager.instance.start();
}

Future<LicenseSessionResult> startSession(
  String licenseKey, {
  required String hardwareId,
  required String targetPc,
  String? peerId,
}) async {
  final key = licenseKey.trim();
  if (key.isEmpty) {
    return const LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: 'License key is required.',
    );
  }
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) {
    return const LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: 'Hardware ID is required.',
    );
  }

  try {
    http.Response? response;
    Object? lastError;
    final endpointUri =
        await _licenseUriFromDefault(kLicenseStartSessionEndpoint);
    final computerName = await _resolveLocalComputerNameForLicenseApi();
    final preBody = await buildStartSessionVpsPayload(
      licenseKey: key,
      hardwareId: hwid,
      computerName: computerName,
      targetPc: targetPc,
      peerId: peerId,
    );
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      try {
        response = await _licenseApiPost(
          endpointUri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(preBody),
        );
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
        if (i >= _kReconnectBackoffSeconds.length) rethrow;
        await Future.delayed(Duration(seconds: _kReconnectBackoffSeconds[i]));
      }
    }
    if (lastError != null || response == null) {
      return const LicenseSessionResult(
        approved: false,
        limitReached: false,
        message: kLicenseCommunicationErrorMessage,
      );
    }

    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}

    final status = payload['status']?.toString().toLowerCase();
    final message = payload['message']?.toString() ?? '';
    final sessionId = payload['session_id']?.toString().trim() ?? '';
    final allowedConnections = _toInt(payload['allowed_connections']) > 0
        ? _toInt(payload['allowed_connections'])
        : _toInt(payload['max_connections']);
    final activeConnections = _toInt(payload['active_connections']);

    final approved = response.statusCode == 200 &&
        (status == 'success' || status == 'valid');
    if (approved) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHardwareIdPrefsKey, hwid);
      var trackedSid = sessionId;
      final pid = peerId?.trim() ?? '';
      if (trackedSid.isEmpty && pid.isNotEmpty) {
        // Fallback for servers that approve without returning session_id.
        trackedSid = _localSyntheticSessionId(pid);
      }
      if (sessionId.isNotEmpty) {
        await prefs.setString('session_id', sessionId);
      }
      if (pid.isNotEmpty && trackedSid.isNotEmpty) {
        await _trackSessionLocally(pid, trackedSid);
      }
      await LicenseHeartbeatManager.instance.start();
      return LicenseSessionResult(
        approved: true,
        limitReached: false,
        message: message.isEmpty ? 'Session started.' : message,
        sessionId: sessionId,
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
      );
    }

    if (response.statusCode == 403) {
      return LicenseSessionResult(
        approved: false,
        limitReached: true,
        message: message.isEmpty ? 'Connection limit reached.' : message,
        sessionId: sessionId,
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
      );
    }

    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: key,
        reason: 'HTTP 404 while calling start_session',
      );
    }

    return LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: message.isEmpty
          ? 'Failed to start session (${response.statusCode}).'
          : message,
      sessionId: sessionId,
      allowedConnections: allowedConnections,
      activeConnections: activeConnections,
    );
  } on TimeoutException {
    return const LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: kLicenseCommunicationErrorMessage,
    );
  } catch (_) {
    return const LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: kLicenseCommunicationErrorMessage,
    );
  }
}

Future<LicenseSessionResult> startSessionFromPrefs({
  required String hardwareId,
  required String targetPc,
  String? peerId,
}) async {
  final license = await getSavedLicenseKey();
  if (license == null || license.trim().isEmpty) {
    return const LicenseSessionResult(
      approved: true,
      limitReached: false,
      message: 'No saved license.',
    );
  }
  return startSession(
    license,
    hardwareId: hardwareId,
    targetPc: targetPc,
    peerId: peerId,
  );
}

Future<ActiveSessionsResult> _fetchLicenseInfoAsActiveSessions(
    String key) async {
  final endpointUri =
      await _licenseUriFromDefault(kLicenseGetLicenseInfoEndpoint);
  final response = await _licenseApiPost(
    endpointUri,
    headers: const {'Content-Type': 'application/json'},
    body: jsonEncode({'license_key': key}),
  );

  Map<String, dynamic> payload = {};
  try {
    payload = jsonDecode(response.body) as Map<String, dynamic>;
  } catch (_) {}

  if (response.statusCode == 404) {
    await _appendLicenseDebugLog(
      endpoint: endpointUri.toString(),
      licenseKey: key,
      reason: 'HTTP 404 while calling get_license_info',
    );
  }

  final status = payload['status']?.toString().toLowerCase();
  final message = payload['message']?.toString() ?? '';
  final sessions =
      _parseSessions(payload['sessions'] ?? payload['active_sessions']);
  final totalSeats = _extractTotalSeats(payload);
  final occupiedSeats = _extractOccupiedSeats(payload);
  final expiryDateIsoUtc = _extractExpiryIsoUtc(payload);
  final localHardwareId = await _getLocalHardwareId();
  final myActiveConnections =
      _countMyActiveConnections(sessions, localHardwareId);
  final ok = response.statusCode == 200 &&
      (status == 'success' || status == 'valid' || payload.isNotEmpty);
  final isExpired = _isExpiredFromServerData(
    expiryIsoUtc: expiryDateIsoUtc,
    status: status,
    message: message,
  );
  final graceMode = _shouldEnterGraceMode(
    status: status ?? '',
    message: message,
    totalSeats: totalSeats,
    occupiedSeats: occupiedSeats,
    myActiveConnections: myActiveConnections,
  );
  if (graceMode) {
    await markLicenseGraceMode('license_not_found:get_license_info');
  } else if (ok) {
    await clearLicenseGraceMode();
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('allowed_connections', totalSeats);
  await prefs.setInt('max_connections', totalSeats);
  await prefs.setInt('active_connections', occupiedSeats);
  await prefs.setBool(kLicenseIsExpiredPrefsKey, graceMode ? false : isExpired);
  if (expiryDateIsoUtc.isNotEmpty) {
    await prefs.setString(kLicenseExpiryIsoPrefsKey, expiryDateIsoUtc);
  }

  return ActiveSessionsResult(
    success: ok,
    message: ok
        ? (message.isEmpty
            ? 'Active sessions fetched from license info.'
            : message)
        : (message.isEmpty
            ? 'Failed to load license info (${response.statusCode}).'
            : message),
    sessions: sessions,
    totalSeats: totalSeats,
    occupiedSeats: occupiedSeats,
    myActiveConnections: myActiveConnections,
  );
}

Future<ActiveSessionsResult> fetchActiveSessions(String licenseKey) async {
  final key = licenseKey.trim();
  if (key.isEmpty) {
    return const ActiveSessionsResult(
      success: false,
      message: 'License key is required.',
    );
  }

  try {
    final endpointUri =
        await _licenseUriFromDefault(kLicenseGetActiveSessionsEndpoint);
    final prefs = await SharedPreferences.getInstance();
    final cachedSeats = prefs.getInt('allowed_connections') ?? 0;
    final hwid = prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
    final response = await _licenseApiPost(
      endpointUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'license_key': key,
        if (hwid.isNotEmpty) 'hardware_id': hwid,
        if (cachedSeats > 0) 'allowed_connections': cachedSeats,
      }),
    );

    final payload = _parseLicenseHttpJsonBody(response.body);

    final status = payload['status']?.toString().toLowerCase();
    final message = payload['message']?.toString() ?? '';
    final fieldMap = _fieldsForLicenseSessionPayload(payload);
    final sessions =
        _parseSessions(fieldMap['sessions'] ?? fieldMap['active_sessions']);
    final totalSeats = _extractTotalSeats(fieldMap);
    final occupiedSeats = _extractOccupiedSeats(fieldMap);
    final expiryDateIsoUtc = _extractExpiryIsoUtc(payload);
    final localHardwareId = await _getLocalHardwareId();
    final myActiveConnections =
        _countMyActiveConnections(sessions, localHardwareId);
    final hasSessionShape = _licensePayloadHasSessionShape(fieldMap);
    final treatAsOk = response.statusCode == 200 &&
        (_licenseStatusIndicatesOk(status) || hasSessionShape);
    final isExpired = _isExpiredFromServerData(
      expiryIsoUtc: expiryDateIsoUtc,
      status: status,
      message: message,
    );
    final graceMode = _shouldEnterGraceMode(
      status: status ?? '',
      message: message,
      totalSeats: totalSeats,
      occupiedSeats: occupiedSeats,
      myActiveConnections: myActiveConnections,
    );
    if (graceMode) {
      await markLicenseGraceMode('license_not_found:get_active_sessions');
    } else if (treatAsOk) {
      await clearLicenseGraceMode();
    }
    if (treatAsOk) {
      if (kDebugMode) {
        debugPrint(
            '[License] get_active_sessions OK: total=$totalSeats activeStations=$occupiedSeats my=$myActiveConnections sessions=${sessions.length}');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('allowed_connections', totalSeats);
      await prefs.setInt('max_connections', totalSeats);
      await prefs.setInt('active_connections', occupiedSeats);
      await prefs.setBool(
          kLicenseIsExpiredPrefsKey, graceMode ? false : isExpired);
      if (expiryDateIsoUtc.isNotEmpty) {
        await prefs.setString(kLicenseExpiryIsoPrefsKey, expiryDateIsoUtc);
      }
      return ActiveSessionsResult(
        success: true,
        message: message.isEmpty ? 'Active sessions fetched.' : message,
        sessions: sessions,
        totalSeats: totalSeats,
        occupiedSeats: occupiedSeats,
        myActiveConnections: myActiveConnections,
      );
    }

    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: key,
        reason: 'HTTP 404 while calling get_active_sessions',
      );
      return _fetchLicenseInfoAsActiveSessions(key);
    }

    if (isExpired) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kLicenseIsExpiredPrefsKey, true);
      if (expiryDateIsoUtc.isNotEmpty) {
        await prefs.setString(kLicenseExpiryIsoPrefsKey, expiryDateIsoUtc);
      }
    }
    if (graceMode) {
      return ActiveSessionsResult(
        success: false,
        message:
            'License not found on server. Running in temporary Free mode (up to 36 hours).',
        sessions: const [],
        totalSeats: 0,
        occupiedSeats: 0,
        myActiveConnections: 0,
      );
    }

    if (kDebugMode) {
      debugPrint(
          '[License] get_active_sessions FAIL: http=${response.statusCode} status=$status message=$message');
    }
    return ActiveSessionsResult(
      success: false,
      message: message.isEmpty
          ? 'Failed to load active sessions (${response.statusCode}).'
          : message,
      sessions: sessions,
      totalSeats: totalSeats,
      occupiedSeats: occupiedSeats,
      myActiveConnections: myActiveConnections,
    );
  } on TimeoutException {
    return const ActiveSessionsResult(
      success: false,
      message: kLicenseCommunicationErrorMessage,
    );
  } catch (_) {
    return const ActiveSessionsResult(
      success: false,
      message: kLicenseCommunicationErrorMessage,
    );
  }
}

Future<ActiveSessionsResult> fetchActiveSessionsFromPrefs() async {
  final license = await getSavedLicenseKey();
  if (license == null || license.trim().isEmpty) {
    return const ActiveSessionsResult(
      success: false,
      message: 'No saved license.',
    );
  }
  return fetchActiveSessions(license);
}

/// Remove license map entries (and notify VPS) for peers that have no live UI session.
/// Desktop only: pass the set of normalized peer ids from open remote-related windows.
Future<void> pruneStaleLicensePeerSessionsNotLive(
    Set<String> liveNormalizedPeerIds) async {
  final map = await _loadPeerSessionMap();
  if (map.isEmpty) {
    await _cleanupPendingNotInLive(liveNormalizedPeerIds);
    return;
  }
  // Empty live set usually means we could not enumerate remote windows (IPC timing,
  // or settings not running on the engine that owns the window list) — not "user
  // closed everything". Pruning here mass-releases VPS seats and empties the UI.
  if (liveNormalizedPeerIds.isEmpty) {
    return;
  }
  final staleKeys = <String>[];
  for (final entry in map.entries) {
    if (entry.value.isEmpty) continue;
    final k = entry.key.trim();
    if (k.isEmpty) continue;
    if (!liveNormalizedPeerIds.contains(k)) {
      staleKeys.add(k);
    }
  }
  for (final key in staleKeys) {
    await releaseConnectionForPeer(key);
  }
  await _cleanupPendingNotInLive(liveNormalizedPeerIds);
}

Future<void> _cleanupPendingNotInLive(Set<String> liveNormalizedPeerIds) async {
  final pending = await _cleanupAndLoadPendingPeerMap();
  var changed = false;
  pending.removeWhere((k, _) {
    if (liveNormalizedPeerIds.contains(k)) return false;
    changed = true;
    return true;
  });
  if (changed) await _savePendingPeerMap(pending);
}

Future<void> refreshLicenseStatusFromServer() async {
  final license = (await getSavedLicenseKey())?.trim() ?? '';
  if (license.isEmpty) return;

  final isFreeTier = license.toUpperCase().startsWith('SD-FREE-');
  if (isFreeTier) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLicenseIsExpiredPrefsKey, false);
    return;
  }

  final verify = await verifyLicenseWithServer(license);
  if (verify.approved) {
    await clearLicenseGraceMode();
    await saveLicenseToPrefs(
      license,
      allowedConnections: verify.allowedConnections,
      activeConnections: verify.activeConnections,
      expiryDateIsoUtc: verify.expiryDateIsoUtc,
      isExpired: false,
    );
    return;
  }

  final hasFreshFutureExpiry = verify.expiryDateIsoUtc.isNotEmpty &&
      !_isExpiredByDate(verify.expiryDateIsoUtc);
  if (hasFreshFutureExpiry) {
    await clearLicenseGraceMode();
    await saveLicenseToPrefs(
      license,
      allowedConnections:
          verify.allowedConnections > 0 ? verify.allowedConnections : null,
      activeConnections: verify.activeConnections,
      expiryDateIsoUtc: verify.expiryDateIsoUtc,
      isExpired: false,
    );
    return;
  }

  if (verify.isExpired) {
    await clearLicenseGraceMode();
    await saveLicenseToPrefs(
      license,
      allowedConnections: 1,
      activeConnections: verify.activeConnections,
      expiryDateIsoUtc: verify.expiryDateIsoUtc,
      isExpired: true,
    );
    return;
  }

  // Fallback for servers that report expiry only in active/license-info endpoints.
  await fetchActiveSessions(license);
}

Future<void> refreshLicenseStatus() async {
  await refreshLicenseStatusFromServer();
}

/// Before binding a real license, release anonymous VPS sessions so dashboards do not double-count.
Future<void> _releaseUnlicensedVpsSessionsBeforeBindingLicense() async {
  final ids = await getLocalLicenseSessionIds();
  try {
    for (final sid in ids) {
      await releaseConnectionBySessionId(sid);
    }
  } finally {
    await _savePeerSessionMap({});
    final p = await SharedPreferences.getInstance();
    await p.remove('session_id');
    await p.setInt('active_connections', 0);
    await p.remove(kLicenseVpsUnlicensedTelemetryKey);
  }
}

Future<void> saveLicenseToPrefs(
  String licenseKey, {
  int? allowedConnections,
  int? activeConnections,
  int? maxConnections,
  String? expiryDateIsoUtc,
  bool? isExpired,
}) async {
  final previousKey = (await getSavedLicenseKey())?.trim() ?? '';
  final nextKey = licenseKey.trim();
  if (nextKey.isNotEmpty && previousKey.isEmpty) {
    await _releaseUnlicensedVpsSessionsBeforeBindingLicense();
  }
  final prefs = await SharedPreferences.getInstance();
  await _setSavedLicenseKey(licenseKey);
  await prefs.setString('masked_license', maskLicense(licenseKey));
  final normalizedExpiry = _normalizeExpiryIsoUtc(expiryDateIsoUtc ?? '');
  final effectiveExpired = isExpired ?? _isExpiredByDate(normalizedExpiry);
  await prefs.setBool(kLicenseIsExpiredPrefsKey, effectiveExpired);
  if (normalizedExpiry.isNotEmpty) {
    await prefs.setString(kLicenseExpiryIsoPrefsKey, normalizedExpiry);
  } else {
    await prefs.remove(kLicenseExpiryIsoPrefsKey);
  }
  final effectiveAllowed = allowedConnections ?? maxConnections;
  if (effectiveAllowed != null) {
    await prefs.setInt('allowed_connections', effectiveAllowed);
    await prefs.setInt('max_connections', effectiveAllowed);
  }
  if (activeConnections != null) {
    await prefs.setInt('active_connections', activeConnections);
  }
  await clearLicenseGraceMode();
  await recordSdFreeKeyOnLicenseSave(previousKey, nextKey);
}

Future<void> clearLicensePrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kLegacySavedLicenseKey);
  await _licenseSecureStorage.delete(key: _kLegacySavedLicenseKey);
  await prefs.remove('masked_license');
  await prefs.remove(kLicenseExpiryIsoPrefsKey);
  await prefs.remove(kLicenseIsExpiredPrefsKey);
  await prefs.remove('session_id');
  await prefs.remove(_kHardwareIdPrefsKey);
  await prefs.remove(_kPeerSessionMapKey);
  await prefs.remove('allowed_connections');
  await prefs.remove('active_connections');
  await prefs.remove('max_connections');
  await prefs.remove(kLicenseGraceStartMsPrefsKey);
  await prefs.remove(kLicenseGraceReasonPrefsKey);
  await prefs.remove(kLicenseVpsUnlicensedTelemetryKey);
  await clearSdFreeAccountTrialPrefs();
}

/// Full license logout: stop heartbeat, release server-side sessions, notify
/// license server, then clear all local license prefs. Use for "Release" /
/// "Logout" so new remote connections read an empty [saved_license].
Future<String?> releaseLicenseFullLogout() async {
  LicenseHeartbeatManager.instance.stop();
  LicenseHeartbeatManager.instance.resetAfterLogout();

  final key = (await getSavedLicenseKey())?.trim() ?? '';
  String? combinedErr;

  final errFromPrefs = await releaseConnectionFromPrefs(force: true);
  if (errFromPrefs != null) {
    combinedErr = errFromPrefs;
  }

  if (key.isNotEmpty) {
    final errRelease = await releaseConnection(key);
    if (errRelease != null && combinedErr == null) {
      combinedErr = errRelease;
    }
  }

  await clearLicensePrefs();

  await restartSeeDesktopAfterLicenseChange();
  await LicenseHeartbeatManager.instance.start();
  return combinedErr;
}

Future<String?> sendLicenseHeartbeat({
  required String licenseKey,
  required String hardwareId,
}) async {
  final key = licenseKey.trim();
  final hwid = hardwareId.trim();
  if (key.isEmpty || hwid.isEmpty) return null;

  try {
    final prefs = await SharedPreferences.getInstance();
    final cachedSeats = prefs.getInt('allowed_connections') ?? 0;
    final endpointUri = await _licenseUriFromDefault(kLicenseHeartbeatEndpoint);
    final response = await _licenseApiPost(
      endpointUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'license_key': key,
        'hardware_id': hwid,
        if (cachedSeats > 0) 'allowed_connections': cachedSeats,
      }),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: key,
        reason: 'HTTP 404 while calling heartbeat',
      );
    }
    return 'Heartbeat failed (${response.statusCode}).';
  } on TimeoutException {
    return kLicenseCommunicationErrorMessage;
  } catch (_) {
    return kLicenseCommunicationErrorMessage;
  }
}

/// Heartbeat for unlicensed / anonymous sessions (`license_key` empty). VPS keeps last_seen.
Future<String?> sendUnlicensedSessionHeartbeat(String hardwareId) async {
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) return null;
  try {
    final endpointUri = await _licenseUriFromDefault(kLicenseHeartbeatEndpoint);
    final response = await _licenseApiPost(
      endpointUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'license_key': '',
        'hardware_id': hwid,
        'unlicensed': true,
      }),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }
    return 'Unlicensed heartbeat failed (${response.statusCode}).';
  } on TimeoutException {
    return kLicenseCommunicationErrorMessage;
  } catch (_) {
    return kLicenseCommunicationErrorMessage;
  }
}

class LicenseHeartbeatManager {
  LicenseHeartbeatManager._();
  static final LicenseHeartbeatManager instance = LicenseHeartbeatManager._();

  Timer? _timer;
  int _failedHeartbeats = 0;
  bool _shownLostServerNotice = false;
  final ValueNotifier<LicenseServerStatus> status =
      ValueNotifier<LicenseServerStatus>(LicenseServerStatus.unknown);

  Future<void> start() async {
    _timer ??= Timer.periodic(const Duration(seconds: 60), (_) {
      // Guard against any unexpected throw inside tick() — an unhandled
      // Future from Timer.periodic can bubble up and crash Flutter desktop.
      tick().catchError((Object e) {
        if (kDebugMode) debugPrint('[License] tick error: $e');
      });
    });
    try {
      await tick();
    } catch (e) {
      if (kDebugMode) debugPrint('[License] initial tick error: $e');
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Clears reconnect/backoff UI state after local license prefs were removed.
  void resetAfterLogout() {
    _failedHeartbeats = 0;
    _shownLostServerNotice = false;
    status.value = LicenseServerStatus.unknown;
  }

  Future<String?> _sendHeartbeatWithBackoff({
    required String licenseKey,
    required String hardwareId,
  }) async {
    String? lastErr;
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      lastErr = await sendLicenseHeartbeat(
        licenseKey: licenseKey,
        hardwareId: hardwareId,
      );
      if (lastErr == null) return null;
      if (i >= _kReconnectBackoffSeconds.length) break;
      await Future.delayed(Duration(seconds: _kReconnectBackoffSeconds[i]));
    }
    return lastErr;
  }

  Future<String?> _sendUnlicensedHeartbeatWithBackoff({
    required String hardwareId,
  }) async {
    String? lastErr;
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      lastErr = await sendUnlicensedSessionHeartbeat(hardwareId);
      if (lastErr == null) return null;
      if (i >= _kReconnectBackoffSeconds.length) break;
      await Future.delayed(Duration(seconds: _kReconnectBackoffSeconds[i]));
    }
    return lastErr;
  }

  Future<void> tick() async {
    final license = await getSavedLicenseKey();
    final localActiveSessions = await getActiveLicenseSessionCount();
    final isLicensed = license != null && license.trim().isNotEmpty;
    if (!isLicensed && localActiveSessions <= 0) return;

    final prefs = await SharedPreferences.getInstance();
    var hardwareId = prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
    if (hardwareId.isEmpty) {
      hardwareId = (await bind.mainGetUuid()).trim();
    }
    if (hardwareId.isEmpty) return;

    if (!isLicensed) {
      if (localActiveSessions <= 0) return;
      status.value = LicenseServerStatus.online;
      if (kDebugMode) {
        debugPrint(
            '[License] unlicensed heartbeat: sessions=$localActiveSessions');
      }
      final err = await _sendUnlicensedHeartbeatWithBackoff(
        hardwareId: hardwareId,
      );
      if (err == null) {
        _failedHeartbeats = 0;
        _shownLostServerNotice = false;
        return;
      }
      _failedHeartbeats += 1;
      if (_failedHeartbeats >= 3 && !_shownLostServerNotice) {
        _shownLostServerNotice = true;
        BotToast.showText(
          text:
              'Lost connection to the license server. Active seats may not be synchronized until connectivity is restored.',
        );
      }
      return;
    }

    if (prefs.getString(_kHardwareIdPrefsKey)?.trim().isEmpty ?? true) {
      status.value = LicenseServerStatus.reconnecting;
      return;
    }

    // Heartbeat only sends last_seen update — no fetchActiveSessions here
    // (the settings page polls separately every 5 s). Calling get_active_sessions
    // from the heartbeat triggered server-side cleanup_sessions() which killed
    // sessions of OTHER machines sharing the same floating license key.

    if (localActiveSessions <= 0) {
      status.value = LicenseServerStatus.online;
      return;
    }
    if (kDebugMode) {
      debugPrint(
          '[License] heartbeat running: localActiveSessions=$localActiveSessions');
    }

    final licensedHw = prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
    final err = await _sendHeartbeatWithBackoff(
      licenseKey: license,
      hardwareId: licensedHw,
    );
    if (err == null) {
      _failedHeartbeats = 0;
      _shownLostServerNotice = false;
      return;
    }

    _failedHeartbeats += 1;
    if (_failedHeartbeats >= 3 && !_shownLostServerNotice) {
      _shownLostServerNotice = true;
      BotToast.showText(
        text:
            'Lost connection to the license server. Active seats may not be synchronized until connectivity is restored.',
      );
    }
  }
}

Future<String?> releaseConnectionBySessionId(String? sessionId) async {
  final sid = sessionId?.trim();
  if (sid == null || sid.isEmpty) return null;

  try {
    final key = (await getSavedLicenseKey())?.trim() ?? '';
    http.Response? response;
    Object? lastError;
    final endpointUri =
        await _licenseUriFromDefault(kLicenseReleaseConnectionEndpoint);
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      try {
        response = await _licenseApiPost(
          endpointUri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'license_key': key,
            'session_id': sid,
            if (key.isEmpty) 'unlicensed': true,
          }),
        );
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
        if (i >= _kReconnectBackoffSeconds.length) rethrow;
        await Future.delayed(Duration(seconds: _kReconnectBackoffSeconds[i]));
      }
    }
    if (lastError != null || response == null) {
      return kLicenseCommunicationErrorMessage;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        if (payload.containsKey('released_count')) {
          final releasedCount = _toInt(payload['released_count']);
          if (releasedCount <= 0) {
            return payload['message']?.toString() ?? 'Session not found.';
          }
        }
      } catch (_) {
        // Backward compatible with older server responses that return 2xx without JSON.
      }
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: 'session:$sid',
        reason: 'HTTP 404 while calling release_connection (session mode)',
      );
    }

    try {
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      return payload['message']?.toString() ??
          'Failed to release connection (${response.statusCode}).';
    } catch (_) {
      return 'Failed to release connection (${response.statusCode}).';
    }
  } on TimeoutException {
    return kLicenseCommunicationErrorMessage;
  } catch (_) {
    return kLicenseCommunicationErrorMessage;
  }
}

Future<String?> _releaseByHardwareAndPeer(
    String hardwareId, String peerId) async {
  if (hardwareId.isEmpty || peerId.isEmpty) {
    return 'Missing hw/peer for release.';
  }
  try {
    final key = (await getSavedLicenseKey())?.trim() ?? '';
    final endpointUri =
        await _licenseUriFromDefault(kLicenseReleaseConnectionEndpoint);
    final response = await _licenseApiPost(
      endpointUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'license_key': key,
        'hardware_id': hardwareId,
        'peer_id': peerId,
        if (key.isEmpty) 'unlicensed': true,
      }),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        final count = _toInt(payload['released_count']);
        if (count <= 0) {
          return payload['message']?.toString() ?? 'Session not found.';
        }
      } catch (_) {}
      return null;
    }
    return 'Release failed (${response.statusCode}).';
  } on TimeoutException {
    return kLicenseCommunicationErrorMessage;
  } catch (_) {
    return kLicenseCommunicationErrorMessage;
  }
}

Future<String?> releaseConnectionForPeer(
  String peerId, {
  String? sessionIdHint,
}) async {
  final normPeer = normalizePeerIdForLicenseTracking(peerId);
  await unmarkPendingLicenseConnectionPeer(normPeer);
  final map = await _loadPeerSessionMap();

  // Prefer hw+peer disconnect (new server logic).
  String? hardwareId;
  try {
    final prefs = await SharedPreferences.getInstance();
    hardwareId = prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
    if (hardwareId.isEmpty) hardwareId = (await bind.mainGetUuid()).trim();
  } catch (_) {
    hardwareId = '';
  }

  String? firstError;
  if (normPeer.isNotEmpty && hardwareId.isNotEmpty) {
    firstError = await _releaseByHardwareAndPeer(hardwareId, normPeer);
  }

  // Fallback: session_id based release for legacy servers.
  if (firstError != null) {
    final candidates = <String>[];
    if (normPeer.isNotEmpty) {
      final sessions = List<String>.from(map[normPeer] ?? const <String>[]);
      for (final s in sessions) {
        final t = s.trim();
        if (t.isNotEmpty && !candidates.contains(t)) candidates.add(t);
      }
    }
    final hinted = sessionIdHint?.trim() ?? '';
    if (hinted.isNotEmpty && !candidates.contains(hinted)) {
      candidates.add(hinted);
    }
    for (final candidate in candidates) {
      final err = await releaseConnectionBySessionId(candidate);
      final notFound = (err ?? '').toLowerCase().contains('not found');
      if (err == null || notFound) {
        firstError = null;
        break;
      }
      firstError ??= err;
    }
  }

  // Always free the local slot.
  final cleaned = await _loadPeerSessionMap();
  if (normPeer.isNotEmpty) cleaned.remove(normPeer);
  await _savePeerSessionMap(cleaned);

  final prefs = await SharedPreferences.getInstance();
  if (cleaned.isEmpty) {
    await prefs.remove('session_id');
    await prefs.setInt('active_connections', 0);
  } else {
    final remainingIds = cleaned.values
        .expand((x) => x)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (remainingIds.isNotEmpty) {
      await prefs.setString('session_id', remainingIds.last);
    }
  }

  return firstError;
}

Future<String?> releaseConnection(String? licenseKey) async {
  final map = await _loadPeerSessionMap();
  if (map.isNotEmpty) {
    return releaseConnectionFromPrefs(force: true);
  }

  final key = licenseKey?.trim();
  if (key == null || key.isEmpty) return null;

  try {
    final endpointUri =
        await _licenseUriFromDefault(kLicenseReleaseConnectionEndpoint);
    final response = await _licenseApiPost(
      endpointUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'license_key': key}),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: key,
        reason: 'HTTP 404 while calling release_connection (license mode)',
      );
    }

    try {
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      return payload['message']?.toString() ??
          'Failed to release connection (${response.statusCode}).';
    } catch (_) {
      return 'Failed to release connection (${response.statusCode}).';
    }
  } on TimeoutException {
    return kLicenseCommunicationErrorMessage;
  } catch (_) {
    return kLicenseCommunicationErrorMessage;
  }
}

Future<String?> releaseConnectionByLicense(String? licenseKey) async {
  return releaseConnection(licenseKey);
}

Future<String?> releaseConnectionFromPrefs({bool force = false}) async {
  final map = await _loadPeerSessionMap();
  if (map.isEmpty && !force) return null;

  String? firstError;
  final remained = <String, List<String>>{};
  for (final entry in map.entries) {
    final peerId = entry.key;
    final failedForPeer = <String>[];
    for (final sessionId in entry.value) {
      final err = await releaseConnectionBySessionId(sessionId);
      final notFound = (err ?? '').toLowerCase().contains('not found');
      if (err != null && !notFound) {
        firstError ??= err;
        failedForPeer.add(sessionId);
      }
    }
    if (failedForPeer.isNotEmpty) {
      remained[peerId] = failedForPeer;
    }
  }
  await _savePeerSessionMap(remained);
  final prefs = await SharedPreferences.getInstance();
  if (remained.isEmpty) {
    await prefs.remove('session_id');
    await prefs.setInt('active_connections', 0);
  } else {
    final firstRemaining =
        remained.values.firstWhere((v) => v.isNotEmpty, orElse: () => const []);
    if (firstRemaining.isNotEmpty) {
      await prefs.setString('session_id', firstRemaining.last);
    }
  }
  return firstError;
}

/// Pay-as-you-go Jumbo Mail credits (keyed by WordPress / cloud account email).
class JumboCreditsResult {
  const JumboCreditsResult({
    required this.success,
    required this.balance,
    this.message = '',
  });

  final bool success;
  final int balance;
  final String message;
}

int _parseJumboCreditsBalance(Map<String, dynamic> payload) {
  final raw =
      payload['jumbo_credits'] ?? payload['balance'] ?? payload['credits'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

/// `GET /api/get_jumbo_credits?user_email=...`
Future<JumboCreditsResult> fetchJumboCreditsBalance({
  required String userEmail,
}) async {
  final email = userEmail.trim();
  if (email.isEmpty) {
    return const JumboCreditsResult(
      success: false,
      balance: 0,
      message: 'user_email is required.',
    );
  }

  final endpointUri = await _licenseUriFromDefault(kJumboCreditsGetEndpoint);
  final getUri = endpointUri.replace(
    queryParameters: <String, String>{'user_email': email},
  );

  try {
    final response = await http.get(getUri).timeout(
          const Duration(seconds: 12),
        );
    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}

    if (response.statusCode == 200) {
      final status = payload['status']?.toString().toLowerCase();
      if (status == 'success' || status == 'valid' || payload.isNotEmpty) {
        return JumboCreditsResult(
          success: true,
          balance: _parseJumboCreditsBalance(payload),
          message: payload['message']?.toString() ?? '',
        );
      }
    }

    return JumboCreditsResult(
      success: false,
      balance: _parseJumboCreditsBalance(payload),
      message: payload['message']?.toString() ??
          'Failed to fetch Jumbo credits (${response.statusCode}).',
    );
  } on TimeoutException {
    return const JumboCreditsResult(
      success: false,
      balance: 0,
      message: kLicenseCommunicationErrorMessage,
    );
  } catch (_) {
    return const JumboCreditsResult(
      success: false,
      balance: 0,
      message: kLicenseCommunicationErrorMessage,
    );
  }
}

/// `POST /api/consume_jumbo_credit` with `{ "user_email": "..." }`.
Future<JumboCreditsResult> consumeJumboCreditOnServer({
  required String userEmail,
}) async {
  final email = userEmail.trim();
  if (email.isEmpty) {
    return const JumboCreditsResult(
      success: false,
      balance: 0,
      message: 'user_email is required.',
    );
  }

  final endpointUri =
      await _licenseUriFromDefault(kJumboCreditsConsumeEndpoint);
  try {
    final response = await _licenseApiPost(
      endpointUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'user_email': email}),
    );
    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}

    final balance = _parseJumboCreditsBalance(payload);
    final status = payload['status']?.toString().toLowerCase();
    final ok = response.statusCode == 200 && status == 'success';
    return JumboCreditsResult(
      success: ok,
      balance: balance,
      message: payload['message']?.toString() ??
          (ok ? 'Credit consumed.' : 'Could not consume credit.'),
    );
  } on TimeoutException {
    return const JumboCreditsResult(
      success: false,
      balance: 0,
      message: kLicenseCommunicationErrorMessage,
    );
  } catch (_) {
    return const JumboCreditsResult(
      success: false,
      balance: 0,
      message: kLicenseCommunicationErrorMessage,
    );
  }
}
