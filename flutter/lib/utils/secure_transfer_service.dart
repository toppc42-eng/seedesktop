import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_hbb/utils/secure_transfer_contacts.dart';

/// WordPress REST API for SeeDesktop secure file transfer (GCS signed URLs).
///
/// Base: `https://seedesktop.com/wp-json/sd-transfer/v1`
class SecureTransferException implements Exception {
  SecureTransferException(this.message);
  final String message;

  @override
  String toString() => message;
}

class SecureTransferInitResult {
  SecureTransferInitResult({
    required this.signedUrl,
    required this.fileKey,
  });

  final String signedUrl;
  final String fileKey;
}

/// Row from `GET /history` (cloud sync).
class SecureTransferHistoryItem {
  SecureTransferHistoryItem({
    required this.atIso,
    required this.fileName,
    required this.recipientEmail,
    required this.recipientName,
    required this.ok,
    this.message = '',
    this.downloadUrl,
  });

  final String atIso;
  final String fileName;
  final String recipientEmail;
  final String recipientName;
  final bool ok;
  final String message;
  final String? downloadUrl;

  static SecureTransferHistoryItem? fromJson(Map<String, dynamic> m) {
    final fileName = _pickStr(m, const [
      'file_name',
      'filename',
      'file',
    ]);
    if (fileName.isEmpty) return null;
    final recipientEmail = _pickStr(m, const [
      'recipient_email',
      'to_email',
      'email',
    ]);
    final recipientName = _pickStr(m, const [
      'recipient_name',
      'to_name',
    ]);
    final atIso = _pickStr(m, const [
      'at',
      'created_at',
      'date',
      'timestamp',
      'time',
    ]);
    final ok = _pickBool(m);
    final message = _pickStr(m, const ['message', 'note', 'status_text']);
    final downloadUrl = _pickStr(m, const [
      'download_url',
      'download_link',
      'url',
      'link',
      'signed_url',
      'file_url',
    ]);
    return SecureTransferHistoryItem(
      atIso: atIso.isNotEmpty
          ? atIso
          : DateTime.now().toIso8601String(),
      fileName: fileName,
      recipientEmail: recipientEmail,
      recipientName: recipientName,
      ok: ok,
      message: message,
      downloadUrl: downloadUrl.isNotEmpty ? downloadUrl : null,
    );
  }

  static String _pickStr(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v != null) {
        final s = v.toString().trim();
        if (s.isNotEmpty) return s;
      }
    }
    return '';
  }

  static bool _pickBool(Map<String, dynamic> m) {
    final v = m['ok'] ?? m['success'] ?? m['status'];
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v?.toString().toLowerCase() ?? '';
    if (s == 'ok' || s == 'success' || s == '1' || s == 'true') {
      return true;
    }
    if (s == 'error' || s == 'failed' || s == '0' || s == 'false') {
      return false;
    }
    return true;
  }
}

class SecureTransferService {
  SecureTransferService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 45),
                receiveTimeout: const Duration(seconds: 90),
                sendTimeout: const Duration(seconds: 90),
              ),
            );

  static const String baseUrl =
      'https://seedesktop.com/wp-json/sd-transfer/v1';

  final Dio _dio;

  /// Contacts synced per sender account (`GET /contacts`).
  Future<List<SecureTransferContact>> fetchContacts({
    required String email,
  }) async {
    try {
      final res = await _dio.get<dynamic>(
        '$baseUrl/contacts',
        queryParameters: <String, dynamic>{'email': email},
        options: Options(
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) {
        final parsed = _tryParseServerError(res.data);
        if (parsed != null) {
          throw SecureTransferException(parsed);
        }
        throw SecureTransferException(
          'Contacts failed (${res.statusCode})',
        );
      }
      final data = res.data;
      if (data == null) {
        return [];
      }
      List<dynamic>? rawList;
      if (data is List) {
        rawList = data;
      } else if (data is Map) {
        final map = Map<String, dynamic>.from(data);
        if (map['success'] == false) {
          final err = _tryParseServerError(map) ?? 'Contacts rejected';
          throw SecureTransferException(err);
        }
        if (map['contacts'] is List) {
          rawList = map['contacts'] as List<dynamic>;
        } else if (map['items'] is List) {
          rawList = map['items'] as List<dynamic>;
        }
      }
      rawList ??= [];
      final out = <SecureTransferContact>[];
      for (final e in rawList) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final row = SecureTransferContact.fromJson(m);
        if (row.email.trim().isEmpty) continue;
        out.add(row);
      }
      return out;
    } on SecureTransferException {
      rethrow;
    } on DioException catch (e) {
      final fromBody = _tryParseServerError(e.response?.data);
      if (fromBody != null) {
        throw SecureTransferException(fromBody);
      }
      throw SecureTransferException(_describeDio(e));
    }
  }

  /// Full replace on server for this sender (`POST /contacts/sync`).
  Future<void> syncContacts({
    required String senderEmail,
    required List<SecureTransferContact> contacts,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '$baseUrl/contacts/sync',
        data: <String, dynamic>{
          'sender_email': senderEmail,
          'contacts': contacts.map((e) => e.toJson()).toList(),
        },
        options: Options(
          contentType: Headers.jsonContentType,
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) {
        final parsed = _tryParseServerError(res.data);
        if (parsed != null) {
          throw SecureTransferException(parsed);
        }
        throw SecureTransferException(
          'Contacts sync failed (${res.statusCode})',
        );
      }
      final data = res.data;
      if (data == null) {
        throw SecureTransferException('Empty response from server');
      }
      if (data['success'] != true) {
        throw SecureTransferException(
          data['error']?.toString() ??
              data['message']?.toString() ??
              'Contacts sync rejected',
        );
      }
    } on SecureTransferException {
      rethrow;
    } on DioException catch (e) {
      final fromBody = _tryParseServerError(e.response?.data);
      if (fromBody != null) {
        throw SecureTransferException(fromBody);
      }
      throw SecureTransferException(_describeDio(e));
    }
  }

  /// Cloud history for the current account email.
  Future<List<SecureTransferHistoryItem>> fetchHistory({
    required String email,
  }) async {
    try {
      final res = await _dio.get<dynamic>(
        '$baseUrl/history',
        queryParameters: <String, dynamic>{'email': email},
        options: Options(
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) {
        final parsed = _tryParseServerError(res.data);
        if (parsed != null) {
          throw SecureTransferException(parsed);
        }
        throw SecureTransferException(
          'History failed (${res.statusCode})',
        );
      }
      final data = res.data;
      if (data == null) {
        return [];
      }
      List<dynamic>? rawList;
      if (data is List) {
        rawList = data;
      } else if (data is Map) {
        final map = Map<String, dynamic>.from(data);
        if (map['success'] == false) {
          final err = _tryParseServerError(map) ?? 'History rejected';
          throw SecureTransferException(err);
        }
        if (map['items'] is List) {
          rawList = map['items'] as List<dynamic>;
        } else if (map['history'] is List) {
          rawList = map['history'] as List<dynamic>;
        } else if (map['data'] is List) {
          rawList = map['data'] as List<dynamic>;
        }
      }
      rawList ??= [];
      final out = <SecureTransferHistoryItem>[];
      for (final e in rawList) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final item = SecureTransferHistoryItem.fromJson(m);
        if (item != null) out.add(item);
      }
      return out;
    } on SecureTransferException {
      rethrow;
    } on DioException catch (e) {
      final fromBody = _tryParseServerError(e.response?.data);
      if (fromBody != null) {
        throw SecureTransferException(fromBody);
      }
      throw SecureTransferException(_describeDio(e));
    }
  }

  /// Step 1: POST `/init` → signed URL + file_key.
  Future<SecureTransferInitResult> init({
    required String fileName,
    required int fileSizeBytes,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '$baseUrl/init',
        data: <String, dynamic>{
          'file_name': fileName,
          'file_size_bytes': fileSizeBytes,
        },
        options: Options(
          contentType: Headers.jsonContentType,
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) {
        final parsed = _tryParseServerError(res.data);
        if (parsed != null) {
          throw SecureTransferException(parsed);
        }
        throw SecureTransferException(
          'Init failed (${res.statusCode})',
        );
      }
      final data = res.data;
      if (data == null) {
        throw SecureTransferException('Empty response from server');
      }
      if (data['success'] != true) {
        throw SecureTransferException(
          data['error']?.toString() ??
              data['message']?.toString() ??
              'Init rejected',
        );
      }
      final signedUrl = data['signed_url'] as String?;
      final fileKey = data['file_key'] as String?;
      if (signedUrl == null ||
          signedUrl.isEmpty ||
          fileKey == null ||
          fileKey.isEmpty) {
        throw SecureTransferException('Invalid init response');
      }
      return SecureTransferInitResult(
        signedUrl: signedUrl,
        fileKey: fileKey,
      );
    } on SecureTransferException {
      rethrow;
    } on DioException catch (e) {
      final fromBody = _tryParseServerError(e.response?.data);
      if (fromBody != null) {
        throw SecureTransferException(fromBody);
      }
      throw SecureTransferException(_describeDio(e));
    }
  }

  /// Step 2: PUT file bytes to [signedUrl] with upload progress [0..1].
  Future<void> uploadToSignedUrl({
    required String signedUrl,
    required String filePath,
    required void Function(double progress01) onProgress,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw SecureTransferException('File not found');
    }
    final length = await file.length();
    if (length == 0) {
      throw SecureTransferException('File is empty');
    }

    final uploadDio = Dio(
      BaseOptions(
        connectTimeout: const Duration(minutes: 10),
        sendTimeout: const Duration(minutes: 60),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );

    try {
      final response = await uploadDio.put<void>(
        signedUrl,
        data: file.openRead(),
        options: Options(
          headers: <String, String>{
            Headers.contentTypeHeader: 'application/octet-stream',
            Headers.contentLengthHeader: length.toString(),
          },
          validateStatus: (code) => code != null && code >= 200 && code < 300,
        ),
        onSendProgress: (sent, total) {
          if (total > 0) {
            onProgress((sent / total).clamp(0.0, 1.0));
          }
        },
      );
      final code = response.statusCode;
      if (code == null || code < 200 || code >= 300) {
        throw SecureTransferException(
          'Upload failed (HTTP ${code ?? "?"})',
        );
      }
      onProgress(1);
    } on DioException catch (e) {
      throw SecureTransferException(_describeDio(e));
    }
  }

  /// Step 3: POST `/complete` → notify recipient.
  Future<String> complete({
    required String senderEmail,
    required String recipientName,
    required String recipientEmail,
    required String fileKey,
    required String messageBody,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '$baseUrl/complete',
        data: <String, dynamic>{
          'sender_email': senderEmail,
          'recipient_name': recipientName,
          'recipient_email': recipientEmail,
          'file_key': fileKey,
          'message_body': messageBody,
        },
        options: Options(
          contentType: Headers.jsonContentType,
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) {
        final parsed = _tryParseServerError(res.data);
        if (parsed != null) {
          throw SecureTransferException(parsed);
        }
        throw SecureTransferException(
          'Complete failed (${res.statusCode})',
        );
      }
      final data = res.data;
      if (data == null) {
        throw SecureTransferException('Empty response from server');
      }
      if (data['success'] != true) {
        throw SecureTransferException(
          data['error']?.toString() ??
              data['message']?.toString() ??
              'Complete rejected',
        );
      }
      return data['message']?.toString() ?? '';
    } on SecureTransferException {
      rethrow;
    } on DioException catch (e) {
      final fromBody = _tryParseServerError(e.response?.data);
      if (fromBody != null) {
        throw SecureTransferException(fromBody);
      }
      throw SecureTransferException(_describeDio(e));
    }
  }

  /// WordPress may return `{"success":false,"error":"..."}` (and optional `message`).
  static String? _tryParseServerError(Object? body) {
    Map<String, dynamic>? m;
    if (body is Map<String, dynamic>) {
      m = body;
    } else if (body is Map) {
      m = Map<String, dynamic>.from(body);
    } else if (body is String) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          m = decoded;
        } else if (decoded is Map) {
          m = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    if (m == null) return null;
    if (m.containsKey('error')) {
      final s = m['error']?.toString().trim() ?? '';
      if (s.isNotEmpty) return s;
    }
    final msg = m['message']?.toString().trim() ?? '';
    if (msg.isNotEmpty) return msg;
    return null;
  }

  static String _describeDio(DioException e) {
    final fromBody = _tryParseServerError(e.response?.data);
    if (fromBody != null) return fromBody;

    final msg = e.message;
    final sc = e.response?.statusCode;
    final buf = StringBuffer();
    if (sc != null) buf.write('HTTP $sc');
    if (msg != null && msg.isNotEmpty) {
      if (buf.isNotEmpty) buf.write(': ');
      buf.write(msg);
    }
    if (buf.isEmpty) buf.write('Network error');
    return buf.toString();
  }
}
