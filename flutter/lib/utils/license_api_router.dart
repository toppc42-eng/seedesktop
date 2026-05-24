import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'license_connectivity.dart';

/// Production license / VPS API hosts (HA pair).
const String kLicenseApiPrimaryHost = 'api.seedesktop.com';
const String kLicenseApiBackupHost = 'api2.seedesktop.com';

/// Primary-call timeout before switching to [kLicenseApiBackupHost].
const Duration kLicenseApiPrimaryTimeout = Duration(seconds: 7);

/// Default timeout for requests once host is chosen (backup leg uses [requestTimeout] if passed).
const Duration kLicenseApiDefaultRequestTimeout = Duration(seconds: 7);

/// High-availability router: sticky backup until process exit, transparent failover.
class LicenseApiRouter {
  LicenseApiRouter._();

  static bool _stickyBackup = false;

  /// Short label for UI: `api` (primary) or `api2` (backup).
  static final ValueNotifier<String> hostLabelNotifier =
      ValueNotifier<String>('api');

  static bool _eligible(Uri u) =>
      u.host.toLowerCase() == kLicenseApiPrimaryHost;

  static bool _needsFailoverHttp(http.Response r) {
    final c = r.statusCode;
    return c == 502 || c == 503 || c == 504;
  }

  static void _activateBackup() {
    _stickyBackup = true;
    hostLabelNotifier.value = 'api2';
    if (kDebugMode) {
      debugPrint('[LicenseApiRouter] sticky failover → $kLicenseApiBackupHost');
    }
  }

  /// POST with HA rules. [requestTimeout] applies to backup leg (and to non-eligible URIs);
  /// primary leg always uses [kLicenseApiPrimaryTimeout] when failover is eligible.
  static Future<http.Response> post(
    Uri resolvedUri, {
    Map<String, String>? headers,
    Object? body,
    Duration? requestTimeout,
  }) async {
    final h = headers ?? const {'Content-Type': 'application/json'};
    final Duration backupTimeout =
        requestTimeout ?? kLicenseApiDefaultRequestTimeout;

    if (!_eligible(resolvedUri)) {
      return await http
          .post(resolvedUri, headers: h, body: body)
          .timeout(backupTimeout);
    }

    if (_stickyBackup) {
      final bu = resolvedUri.replace(host: kLicenseApiBackupHost);
      return await http.post(bu, headers: h, body: body).timeout(backupTimeout);
    }

    http.Response? resp;
    Object? caught;
    try {
      resp = await http
          .post(resolvedUri, headers: h, body: body)
          .timeout(kLicenseApiPrimaryTimeout);
    } catch (e) {
      caught = e;
    }

    if (resp != null && !_needsFailoverHttp(resp)) {
      return resp;
    }

    if (resp != null && _needsFailoverHttp(resp)) {
      if (!await licenseHasInternetConnectivity()) {
        return resp;
      }
      _activateBackup();
      final bu = resolvedUri.replace(host: kLicenseApiBackupHost);
      return await http.post(bu, headers: h, body: body).timeout(backupTimeout);
    }

    // Timeout or connection failure on primary.
    if (!await licenseHasInternetConnectivity()) {
      if (caught != null) throw caught;
      throw TimeoutException('License API primary', kLicenseApiPrimaryTimeout);
    }

    _activateBackup();
    final bu = resolvedUri.replace(host: kLicenseApiBackupHost);
    return await http.post(bu, headers: h, body: body).timeout(backupTimeout);
  }

  /// GET with the same HA / sticky-backup rules as [post].
  static Future<http.Response> get(
    Uri resolvedUri, {
    Map<String, String>? headers,
    Duration? requestTimeout,
  }) async {
    return _requestWithFailover(
      resolvedUri,
      headers: headers,
      requestTimeout: requestTimeout,
      send: (uri, h, timeout) =>
          http.get(uri, headers: h).timeout(timeout),
    );
  }

  /// DELETE with JSON body (same HA rules as [post]).
  static Future<http.Response> delete(
    Uri resolvedUri, {
    Map<String, String>? headers,
    Object? body,
    Duration? requestTimeout,
  }) async {
    final h = headers ?? const {'Content-Type': 'application/json'};
    return _requestWithFailover(
      resolvedUri,
      headers: h,
      requestTimeout: requestTimeout,
      send: (uri, hdrs, timeout) async {
        final req = http.Request('DELETE', uri);
        req.headers.addAll(hdrs);
        if (body != null) {
          req.body = body is String ? body : body.toString();
        }
        final streamed = await req.send().timeout(timeout);
        return http.Response.fromStream(streamed);
      },
    );
  }

  static Future<http.Response> _requestWithFailover(
    Uri resolvedUri, {
    Map<String, String>? headers,
    Duration? requestTimeout,
    required Future<http.Response> Function(
      Uri uri,
      Map<String, String> hdrs,
      Duration timeout,
    )
        send,
  }) async {
    final h = headers ?? const <String, String>{};
    final Duration backupTimeout =
        requestTimeout ?? kLicenseApiDefaultRequestTimeout;

    if (!_eligible(resolvedUri)) {
      return await send(resolvedUri, h, backupTimeout);
    }

    if (_stickyBackup) {
      final bu = resolvedUri.replace(host: kLicenseApiBackupHost);
      return await send(bu, h, backupTimeout);
    }

    http.Response? resp;
    Object? caught;
    try {
      resp = await send(resolvedUri, h, kLicenseApiPrimaryTimeout);
    } catch (e) {
      caught = e;
    }

    if (resp != null && !_needsFailoverHttp(resp)) {
      return resp;
    }

    if (resp != null && _needsFailoverHttp(resp)) {
      if (!await licenseHasInternetConnectivity()) {
        return resp;
      }
      _activateBackup();
      final bu = resolvedUri.replace(host: kLicenseApiBackupHost);
      return await send(bu, h, backupTimeout);
    }

    if (!await licenseHasInternetConnectivity()) {
      if (caught != null) throw caught;
      throw TimeoutException('License API primary', kLicenseApiPrimaryTimeout);
    }

    _activateBackup();
    final bu = resolvedUri.replace(host: kLicenseApiBackupHost);
    return await send(bu, h, backupTimeout);
  }
}
