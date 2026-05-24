import 'dart:convert';

import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/user_model.dart';
import 'package:flutter_hbb/utils/cloud_sync_service.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';
import 'package:flutter_hbb/utils/favorite_groups.dart';
import 'package:flutter_hbb/utils/license_api_router.dart';

/// Cloud-synced contact row from VPS `GET /api/contacts`.
class CloudContact {
  CloudContact({
    required this.remoteId,
    required this.aliasName,
    List<String>? groups,
    this.os = '',
    this.hostname = '',
    this.createdAtEpoch,
    this.updatedAtEpoch,
  }) : groups = _normalizeGroups(groups ?? const []);

  final String remoteId;
  final String aliasName;
  /// Client / folder labels; empty means ungrouped in the UI.
  final List<String> groups;
  final String os;
  final String hostname;
  final double? createdAtEpoch;
  final double? updatedAtEpoch;

  bool get isUngrouped => groups.isEmpty;

  String get groupsDisplayLabel => groups.join(', ');

  static List<String> _normalizeGroups(List<String> raw) {
    final out = <String>[];
    for (final item in raw) {
      final g = item.trim();
      if (g.isNotEmpty && !out.contains(g)) {
        out.add(g);
      }
    }
    return out;
  }

  static List<String> _parseGroupsFromJson(Map<String, dynamic> json) {
    final raw = json['groups'];
    if (raw is List) {
      return _normalizeGroups(
        raw.map((e) => e.toString()).toList(growable: false),
      );
    }
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return _normalizeGroups(
            decoded.map((e) => e.toString()).toList(growable: false),
          );
        }
      } catch (_) {}
    }
    final legacy =
        (json['group_name'] ?? json['groupName'] ?? '').toString().trim();
    if (legacy.isEmpty) return const [];
    return _normalizeGroups(
      legacy.replaceAll(';', ',').split(',').map((e) => e.trim()).toList(),
    );
  }

  factory CloudContact.fromJson(Map<String, dynamic> json) {
    double? parseNum(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return CloudContact(
      remoteId: (json['remote_id'] ?? json['remoteId'] ?? '').toString().trim(),
      aliasName:
          (json['alias_name'] ?? json['aliasName'] ?? '').toString().trim(),
      groups: _parseGroupsFromJson(json),
      os: (json['os'] ?? json['platform'] ?? '').toString().trim(),
      hostname: (json['hostname'] ?? '').toString().trim(),
      createdAtEpoch: parseNum(json['created_at'] ?? json['createdAt']),
      updatedAtEpoch: parseNum(json['updated_at'] ?? json['updatedAt']),
    );
  }

  Map<String, dynamic> toUpsertJson({
    required String userEmail,
    required String authToken,
  }) {
    return {
      'user_email': userEmail,
      'remote_id': remoteId,
      'alias_name': aliasName,
      'groups': groups,
      'os': os,
      'hostname': hostname,
      'auth_token': authToken,
    };
  }

  Map<String, dynamic> toRecentPeerMeta() {
    final parsed = CloudContactsService.parseHostnameField(hostname);
    return {
      'id': remoteId,
      'alias': aliasName,
      'hostname': parsed.hostname,
      'username': parsed.username,
      'platform': os,
    };
  }
}

/// Clears legacy local favorites-folder mapping so only cloud `groups` show on cards.
Future<void> clearLegacyLocalGroupForPeer(String remoteId) async {
  final id = remoteId.trim();
  if (id.isEmpty) return;
  await FavoriteGroupsStore.removePeer(id);
  await bind.mainSetPeerOption(id: id, key: 'group', value: '');
}

/// VPS cloud contacts API (HA via [LicenseApiRouter]).
class CloudContactsService {
  CloudContactsService._();

  static final Uri _contactsUri =
      Uri.parse('https://$kLicenseApiPrimaryHost/api/contacts');

  static Map<String, List<String>> _groupsByRemoteId = {};
  static Future<void>? _warmGroupsFuture;

  static void _updateGroupsCache(List<CloudContact> contacts) {
    final next = <String, List<String>>{};
    for (final c in contacts) {
      next[c.remoteId] = List<String>.from(c.groups);
    }
    _groupsByRemoteId = next;
  }

  static String groupsLabelFor(String remoteId) {
    final groups = _groupsByRemoteId[remoteId.trim()];
    if (groups == null || groups.isEmpty) return '';
    return groups.join(', ');
  }

  static Future<void> warmGroupsCache() async {
    if (resolveAuthToken() == null) return;
    if (!await canUseCloudContactsLocal()) return;
    if (_warmGroupsFuture != null) {
      await _warmGroupsFuture;
      return;
    }
    final future = fetchContacts(injectIntoRecent: false).then((_) {});
    _warmGroupsFuture = future;
    try {
      await future;
    } catch (_) {
    } finally {
      if (identical(_warmGroupsFuture, future)) {
        _warmGroupsFuture = null;
      }
    }
  }

  static String? _messageFromBody(String body) {
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

  static String? resolveAuthToken() {
    final token =
        bind.mainGetLocalOption(key: CloudSyncService.cloudAuthTokenKey).trim();
    if (token.isNotEmpty) return token;
    final cached = CloudSyncService.savedToken;
    return cached.isEmpty ? null : cached;
  }

  static String? resolveUserEmail() {
    final token = resolveAuthToken();
    if (token == null) return null;
    final cloud = CloudSyncService.savedEmail.trim().toLowerCase();
    if (cloud.isNotEmpty) return cloud;
    final info = UserModel.getLocalUserInfo();
    if (info != null) {
      final e = (info['email'] ?? '').toString().trim().toLowerCase();
      if (e.isNotEmpty) return e;
    }
    return null;
  }

  static Map<String, String> _authHeaders(String token) {
    return <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      'auth_token': token,
      'X-Auth-Token': token,
    };
  }

  static String _requireToken() {
    final token = resolveAuthToken();
    if (token == null || token.isEmpty) {
      throw CloudContactsException(
        'Authentication required. Connect to Cloud in Settings → Account.',
      );
    }
    return token;
  }

  static Future<void> _requireProLicense() async {
    if (!await canUseCloudContactsLocal()) {
      throw CloudContactsException(
        'PRO license required for Cloud Contacts.',
      );
    }
  }

  static CloudContactsException _authOrHttpError(
    int statusCode,
    String body,
    String fallback,
  ) {
    if (statusCode == 401 || statusCode == 403) {
      return CloudContactsException(
        _messageFromBody(body) ??
            'Authentication failed. Connect to Cloud in Settings → Account.',
      );
    }
    return CloudContactsException(
      _messageFromBody(body) ?? '$fallback ($statusCode)',
    );
  }

  static String formatHostnameField(Peer peer) {
    final u = peer.username.trim();
    final h = peer.hostname.trim();
    if (u.isNotEmpty && h.isNotEmpty) return '$u@$h';
    if (h.isNotEmpty) return h;
    if (u.isNotEmpty) return u;
    return '';
  }

  static ({String username, String hostname}) parseHostnameField(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return (username: '', hostname: '');
    final at = line.indexOf('@');
    if (at > 0 && at < line.length - 1) {
      return (
        username: line.substring(0, at).trim(),
        hostname: line.substring(at + 1).trim(),
      );
    }
    return (username: '', hostname: line);
  }

  static ({String os, String hostname}) richFieldsFromPeer(Peer peer) {
    return (
      os: peer.platform.trim(),
      hostname: formatHostnameField(peer),
    );
  }

  static Future<List<CloudContact>> fetchContacts({
    String? userEmail,
    bool injectIntoRecent = true,
  }) async {
    await _requireProLicense();
    final token = _requireToken();
    final email = (userEmail ?? resolveUserEmail())?.trim().toLowerCase();
    if (email == null || email.isEmpty) {
      throw CloudContactsException('user_email is required');
    }
    final uri = _contactsUri.replace(
      queryParameters: <String, String>{
        'user_email': email,
        'auth_token': token,
      },
    );
    final response = await LicenseApiRouter.get(
      uri,
      headers: _authHeaders(token),
      requestTimeout: const Duration(seconds: 20),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _authOrHttpError(
        response.statusCode,
        response.body,
        'Failed to load contacts',
      );
    }
    final list = _parseList(response.body);
    _updateGroupsCache(list);
    for (final c in list) {
      await clearLegacyLocalGroupForPeer(c.remoteId);
    }
    if (injectIntoRecent && list.isNotEmpty) {
      await injectMissingIntoRecent(list);
    }
    return list;
  }

  static Future<void> injectMissingIntoRecent(List<CloudContact> contacts) async {
    if (contacts.isEmpty) return;
    try {
      final exportRaw = await bind.mainExportRecentPeerIdsForSync();
      final decoded = jsonDecode(exportRaw);
      if (decoded is! Map<String, dynamic>) return;

      final existingIds = <String>{};
      final existingMeta = <Map<String, dynamic>>[];
      final rawIds = decoded['recent_peer_ids'];
      if (rawIds is List) {
        for (final id in rawIds) {
          final s = id.toString().trim();
          if (s.isNotEmpty) existingIds.add(s);
        }
      }
      final rawMeta = decoded['recent_peers_meta'];
      if (rawMeta is List) {
        for (final m in rawMeta) {
          if (m is Map) {
            existingMeta.add(Map<String, dynamic>.from(m));
          }
        }
      }

      final missing =
          contacts.where((c) => !existingIds.contains(c.remoteId)).toList();
      if (missing.isEmpty) return;

      final newMeta = missing.map((c) => c.toRecentPeerMeta()).toList();
      final orderedIds = [
        ...missing.map((c) => c.remoteId),
        ...existingIds,
      ];
      final mergedMeta = [...newMeta, ...existingMeta];

      bind.mainApplyRecentPeerIdsFromCloud(
        json: jsonEncode({
          'recent_peer_ids': orderedIds,
          'recent_peers_meta': mergedMeta,
        }),
      );
      await bind.mainLoadRecentPeers();
    } catch (_) {}
  }

  static Future<List<String>> fetchGroupNames({String? userEmail}) async {
    final contacts =
        await fetchContacts(userEmail: userEmail, injectIntoRecent: false);
    final names = <String>{};
    for (final c in contacts) {
      names.addAll(c.groups);
    }
    final sorted = names.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  static Future<void> upsertContact({
    required String remoteId,
    required String aliasName,
    List<String> groups = const [],
    String os = '',
    String hostname = '',
    String? userEmail,
    Peer? sourcePeer,
  }) async {
    await _requireProLicense();
    final token = _requireToken();
    final email = (userEmail ?? resolveUserEmail())?.trim().toLowerCase();
    if (email == null || email.isEmpty) {
      throw CloudContactsException('user_email is required');
    }
    final rid = remoteId.trim();
    final alias = aliasName.trim();
    if (rid.isEmpty || alias.isEmpty) {
      throw CloudContactsException('remote_id and alias_name are required');
    }

    var osValue = os.trim();
    var hostValue = hostname.trim();
    if (sourcePeer != null) {
      final rich = richFieldsFromPeer(sourcePeer);
      if (osValue.isEmpty) osValue = rich.os;
      if (hostValue.isEmpty) hostValue = rich.hostname;
    }

    final normalizedGroups = CloudContact._normalizeGroups(groups);
    final response = await LicenseApiRouter.post(
      _contactsUri,
      headers: _authHeaders(token),
      body: jsonEncode({
        'user_email': email,
        'remote_id': rid,
        'alias_name': alias,
        'groups': normalizedGroups,
        'os': osValue,
        'hostname': hostValue,
        'auth_token': token,
      }),
      requestTimeout: const Duration(seconds: 20),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _authOrHttpError(
        response.statusCode,
        response.body,
        'Failed to save contact',
      );
    }
    _groupsByRemoteId[rid] = normalizedGroups;
    await clearLegacyLocalGroupForPeer(rid);
  }

  static Future<void> deleteContact({
    required String remoteId,
    String? userEmail,
  }) async {
    await _requireProLicense();
    final token = _requireToken();
    final email = (userEmail ?? resolveUserEmail())?.trim().toLowerCase();
    if (email == null || email.isEmpty) {
      throw CloudContactsException('user_email is required');
    }
    final rid = remoteId.trim();
    if (rid.isEmpty) {
      throw CloudContactsException('remote_id is required');
    }
    final response = await LicenseApiRouter.delete(
      _contactsUri,
      headers: _authHeaders(token),
      body: jsonEncode({
        'user_email': email,
        'remote_id': rid,
        'auth_token': token,
      }),
      requestTimeout: const Duration(seconds: 20),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _authOrHttpError(
        response.statusCode,
        response.body,
        'Failed to delete contact',
      );
    }
    _groupsByRemoteId.remove(rid);
  }

  static Future<CloudContact?> findByRemoteId(String remoteId) async {
    final rid = remoteId.trim();
    if (rid.isEmpty) return null;
    if (resolveAuthToken() == null) return null;
    try {
      final list = await fetchContacts(injectIntoRecent: false);
      for (final c in list) {
        if (c.remoteId == rid) return c;
      }
    } on CloudContactsException {
      rethrow;
    }
    return null;
  }

  static List<CloudContact> _parseList(String body) {
    if (body.trim().isEmpty) return [];
    final decoded = jsonDecode(body);
    List<dynamic>? raw;
    if (decoded is List) {
      raw = decoded;
    } else if (decoded is Map<String, dynamic>) {
      if (decoded['contacts'] is List) {
        raw = decoded['contacts'] as List<dynamic>;
      } else if (decoded['data'] is Map &&
          (decoded['data'] as Map)['contacts'] is List) {
        raw = (decoded['data'] as Map)['contacts'] as List<dynamic>;
      }
    }
    raw ??= [];
    final out = <CloudContact>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final row = CloudContact.fromJson(Map<String, dynamic>.from(e));
      if (row.remoteId.isEmpty) continue;
      out.add(row);
    }
    return out;
  }
}

class CloudContactsException implements Exception {
  CloudContactsException(this.message);
  final String message;
  @override
  String toString() => message;
}
