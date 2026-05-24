import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:flutter_hbb/utils/cloud_sync_service.dart';
import 'package:flutter_hbb/utils/license_manager.dart' show getSavedLicenseKey;

class CrmNote {
  final int id;
  final String complaint;
  final String actionTaken;
  final String furtherNotes;
  final String userEmail;
  final DateTime? createdAt;
  final bool isManual;

  const CrmNote({
    required this.id,
    required this.complaint,
    required this.actionTaken,
    required this.furtherNotes,
    required this.userEmail,
    this.createdAt,
    required this.isManual,
  });

  factory CrmNote.fromJson(Map<String, dynamic> json) {
    var complaint = (json['complaint'] ?? '').toString();
    var actionTaken = (json['action_taken'] ?? '').toString();
    var furtherNotes = (json['further_notes'] ?? '').toString();
    if (complaint.trim().isEmpty &&
        actionTaken.trim().isEmpty &&
        furtherNotes.trim().isEmpty) {
      final legacy =
          (json['note_text'] ?? json['note'] ?? json['text'] ?? '').toString();
      if (legacy.trim().isNotEmpty) complaint = legacy;
    }
    return CrmNote(
      id: _parseInt(json['id'] ?? json['note_id'] ?? json['crm_note_id']),
      complaint: complaint,
      actionTaken: actionTaken,
      furtherNotes: furtherNotes,
      userEmail: (json['user_email'] ?? json['email'] ?? '').toString(),
      createdAt: _parseDate(json['created_at'] ?? json['date']),
      isManual: _parseBool01(json['is_manual']),
    );
  }
}

class CrmService {
  CrmService._();

  static const String _baseUrl =
      'https://seedesktop.com/wp-json/seedesktop/v1/crm';

  static Future<void> addNote({
    required String peerId,
    required String complaint,
    required String actionTaken,
    required String furtherNotes,
    bool isManual = false,
  }) async {
    if (peerId.trim().isEmpty) return;
    final c = complaint.trim();
    final a = actionTaken.trim();
    final f = furtherNotes.trim();
    if (c.isEmpty && a.isEmpty && f.isEmpty) return;
    await _post('add_note', {
      'peer_id': peerId.trim(),
      'complaint': c,
      'action_taken': a,
      'further_notes': f,
      'is_manual': isManual ? 1 : 0,
    });
  }

  static Future<List<CrmNote>> getNotes({required String peerId}) async {
    final data = await _post('get_notes', {'peer_id': peerId.trim()});
    return _extractList(data)
        .whereType<Map>()
        .map((e) => CrmNote.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<void> editNote({
    required int noteId,
    required String complaint,
    required String actionTaken,
    required String furtherNotes,
  }) async {
    if (noteId <= 0) return;
    final c = complaint.trim();
    final a = actionTaken.trim();
    final f = furtherNotes.trim();
    if (c.isEmpty && a.isEmpty && f.isEmpty) return;
    await _post('edit_note', {
      'note_id': noteId,
      'complaint': c,
      'action_taken': a,
      'further_notes': f,
    });
  }

  static Future<void> deleteNote({
    required int noteId,
  }) async {
    if (noteId <= 0) return;
    await _post('delete_note', {
      'note_id': noteId,
    });
  }

  static Future<void> addLog({
    required String peerId,
    required String peerName,
    required DateTime startTime,
    required DateTime endTime,
    required int durationSeconds,
  }) async {
    await _post('add_log', {
      'peer_id': peerId.trim(),
      'peer_name': peerName.trim(),
      'start_time': startTime.toUtc().toIso8601String(),
      'end_time': endTime.toUtc().toIso8601String(),
      'duration_seconds': durationSeconds,
    });
  }

  static Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final auth = await _authPayload();
    final body = jsonEncode(<String, dynamic>{
      ...auth,
      ...payload,
    });
    final response = await http
        .post(
          Uri.parse('$_baseUrl/$path'),
          headers: const {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('CRM HTTP ${response.statusCode}: ${response.body}');
    }
    if (response.body.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    if (decoded is List) return <String, dynamic>{'data': decoded};
    return <String, dynamic>{};
  }

  static Future<Map<String, dynamic>> _authPayload() async {
    final licenseKey = (await getSavedLicenseKey())?.trim() ?? '';
    final userEmail = CloudSyncService.savedEmail.trim();
    return <String, dynamic>{
      'license_key': licenseKey,
      'user_email': userEmail,
    };
  }

  static List<dynamic> _extractList(Map<String, dynamic> data) {
    final direct =
        data['data'] ?? data['notes'] ?? data['logs'] ?? data['items'];
    if (direct is List) return List<dynamic>.from(direct);
    return <dynamic>[];
  }
}

DateTime? _parseDate(dynamic value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

int _parseInt(dynamic value) {
  if (value is int) return value;
  return int.tryParse(value?.toString().trim() ?? '') ?? 0;
}

bool _parseBool01(dynamic value) {
  if (value is bool) return value;
  final raw = value?.toString().trim().toLowerCase() ?? '';
  return raw == '1' || raw == 'true' || raw == 'yes';
}
