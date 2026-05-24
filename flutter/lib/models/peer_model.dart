import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'platform_model.dart';
// ignore: depend_on_referenced_packages
import 'package:collection/collection.dart';

class Peer {
  final String id;
  String hash; // personal ab hash password
  String password; // shared ab password
  String username; // pc username
  String hostname;
  String platform;
  String alias;
  List<dynamic> tags;
  bool forceAlwaysRelay = false;
  String rdpPort;
  String rdpUsername;
  bool online = false;
  String loginName; //login username
  String device_group_name;
  String note;
  String previewPath;
  bool? sameServer;

  String getId() {
    if (alias != '') {
      return alias;
    }
    return id;
  }

  Peer.fromJson(Map<String, dynamic> json)
      : id = json['id'] ?? '',
        hash = json['hash'] ?? '',
        password = json['password'] ?? '',
        username = json['username'] ?? '',
        hostname = json['hostname'] ?? '',
        platform = json['platform'] ?? '',
        alias = json['alias'] ?? '',
        tags = json['tags'] ?? [],
        forceAlwaysRelay = json['forceAlwaysRelay'] == 'true',
        rdpPort = json['rdpPort'] ?? '',
        rdpUsername = json['rdpUsername'] ?? '',
        loginName = json['loginName'] ?? '',
        device_group_name = json['device_group_name'] ?? '',
        note = json['note'] is String ? json['note'] : '',
        previewPath =
            json['preview_path'] is String ? json['preview_path'] : '',
        sameServer = json['same_server'],
        online = _parseOnline(json['online']);

  static bool _parseOnline(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final s = (value ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'y' || s == 'yes' || s == 'online';
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "id": id,
      "hash": hash,
      "password": password,
      "username": username,
      "hostname": hostname,
      "platform": platform,
      "alias": alias,
      "tags": tags,
      "forceAlwaysRelay": forceAlwaysRelay.toString(),
      "rdpPort": rdpPort,
      "rdpUsername": rdpUsername,
      'loginName': loginName,
      'device_group_name': device_group_name,
      'note': note,
      'preview_path': previewPath,
      'same_server': sameServer,
    };
  }

  Map<String, dynamic> toCustomJson({required bool includingHash}) {
    var res = <String, dynamic>{
      "id": id,
      "username": username,
      "hostname": hostname,
      "platform": platform,
      "alias": alias,
      "tags": tags,
    };
    if (includingHash) {
      res['hash'] = hash;
    }
    return res;
  }

  Map<String, dynamic> toGroupCacheJson() {
    return <String, dynamic>{
      "id": id,
      "username": username,
      "hostname": hostname,
      "platform": platform,
      "login_name": loginName,
      "device_group_name": device_group_name,
    };
  }

  Peer({
    required this.id,
    required this.hash,
    required this.password,
    required this.username,
    required this.hostname,
    required this.platform,
    required this.alias,
    required this.tags,
    required this.forceAlwaysRelay,
    required this.rdpPort,
    required this.rdpUsername,
    required this.loginName,
    required this.device_group_name,
    required this.note,
    required this.previewPath,
    this.sameServer,
  });

  Peer.loading()
      : this(
          id: '...',
          hash: '',
          password: '',
          username: '...',
          hostname: '...',
          platform: '...',
          alias: '',
          tags: [],
          forceAlwaysRelay: false,
          rdpPort: '',
          rdpUsername: '',
          loginName: '',
          device_group_name: '',
          note: '',
          previewPath: '',
        );
  bool equal(Peer other) {
    return id == other.id &&
        hash == other.hash &&
        password == other.password &&
        username == other.username &&
        hostname == other.hostname &&
        platform == other.platform &&
        alias == other.alias &&
        tags.equals(other.tags) &&
        forceAlwaysRelay == other.forceAlwaysRelay &&
        rdpPort == other.rdpPort &&
        rdpUsername == other.rdpUsername &&
        device_group_name == other.device_group_name &&
        loginName == other.loginName &&
        note == other.note &&
        previewPath == other.previewPath;
  }

  Peer.copy(Peer other)
      : this(
            id: other.id,
            hash: other.hash,
            password: other.password,
            username: other.username,
            hostname: other.hostname,
            platform: other.platform,
            alias: other.alias,
            tags: other.tags.toList(),
            forceAlwaysRelay: other.forceAlwaysRelay,
            rdpPort: other.rdpPort,
            rdpUsername: other.rdpUsername,
            loginName: other.loginName,
            device_group_name: other.device_group_name,
            note: other.note,
            previewPath: other.previewPath,
            sameServer: other.sameServer);
}

enum UpdateEvent { online, load }

typedef GetInitPeers = RxList<Peer> Function();

class Peers extends ChangeNotifier {
  final String name;
  final String loadEvent;
  List<Peer> peers = List.empty(growable: true);
  // Part of the peers that are not in the rest peers list.
  // When there're too many peers, we may want to load the front 100 peers first,
  // so we can see peers in UI quickly. `restPeerIds` is the rest peers' ids.
  // And then load all peers later.
  List<String> restPeerIds = List.empty(growable: true);
  final GetInitPeers? getInitPeers;
  UpdateEvent event = UpdateEvent.load;
  static const _cbQueryOnlines = 'callback_query_onlines';

  Peers(
      {required this.name,
      required this.getInitPeers,
      required this.loadEvent}) {
    peers = getInitPeers?.call() ?? [];
    platformFFI.registerEventHandler(_cbQueryOnlines, name, (evt) async {
      _updateOnlineState(evt);
    });
    platformFFI.registerEventHandler(loadEvent, name, (evt) async {
      _updatePeers(evt);
    });
  }

  @override
  void dispose() {
    platformFFI.unregisterEventHandler(_cbQueryOnlines, name);
    platformFFI.unregisterEventHandler(loadEvent, name);
    super.dispose();
  }

  Peer getByIndex(int index) {
    if (index < peers.length) {
      return peers[index];
    } else {
      return Peer.loading();
    }
  }

  int getPeersCount() {
    return peers.length;
  }

  void _updateOnlineState(Map<String, dynamic> evt) {
    final indexById = <String, Set<int>>{};
    for (var i = 0; i < peers.length; i++) {
      final raw = peers[i].id.trim();
      if (raw.isEmpty) continue;
      indexById.putIfAbsent(raw, () => <int>{}).add(i);
      final normalized = _normalizePeerId(raw);
      if (normalized.isNotEmpty && normalized != raw) {
        indexById.putIfAbsent(normalized, () => <int>{}).add(i);
      }
    }

    Set<int> indexesForIncomingId(String id) {
      final result = <int>{};
      final raw = id.trim();
      if (raw.isEmpty) return result;
      result.addAll(indexById[raw] ?? const <int>{});
      final normalized = _normalizePeerId(raw);
      if (normalized.isNotEmpty && normalized != raw) {
        result.addAll(indexById[normalized] ?? const <int>{});
      }
      return result;
    }

    int changedCount = 0;
    _splitPeerIds(evt['onlines']).forEach((online) {
      for (final i in indexesForIncomingId(online)) {
        if (!peers[i].online) {
          changedCount += 1;
          peers[i].online = true;
        }
      }
    });

    _splitPeerIds(evt['offlines']).forEach((offline) {
      for (final i in indexesForIncomingId(offline)) {
        if (peers[i].online) {
          changedCount += 1;
          peers[i].online = false;
        }
      }
    });

    if (changedCount > 0) {
      event = UpdateEvent.online;
      notifyListeners();
    }
  }

  void _updatePeers(Map<String, dynamic> evt) {
    final onlineStates = _getOnlineStates();
    if (getInitPeers != null) {
      peers = getInitPeers?.call() ?? [];
    } else {
      peers = _decodePeers(evt['peers']);
    }

    restPeerIds = [];
    if (evt['ids'] != null) {
      restPeerIds = (evt['ids'] as String).split(',');
    }

    for (var peer in peers) {
      final state =
          onlineStates[peer.id] ?? onlineStates[_normalizePeerId(peer.id)];
      if (state != null) {
        peer.online = state;
      }
    }
    event = UpdateEvent.load;
    notifyListeners();
  }

  Map<String, bool> _getOnlineStates() {
    var onlineStates = <String, bool>{};
    for (var peer in peers) {
      final raw = peer.id.trim();
      if (raw.isEmpty) continue;
      onlineStates[raw] = peer.online;
      final normalized = _normalizePeerId(raw);
      if (normalized.isNotEmpty) {
        onlineStates[normalized] = peer.online;
      }
    }
    return onlineStates;
  }

  Iterable<String> _splitPeerIds(dynamic value) {
    if (value == null) return const <String>[];
    return value
        .toString()
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
  }

  String _normalizePeerId(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  }

  List<Peer> _decodePeers(String peersStr) {
    try {
      if (peersStr == "") return [];
      List<dynamic> peers = json.decode(peersStr);
      return peers.map((peer) {
        return Peer.fromJson(peer as Map<String, dynamic>);
      }).toList();
    } catch (e) {
      debugPrint('peers(): $e');
    }
    return [];
  }

  void updateAlias(String id, String alias) {
    var changed = false;
    for (final peer in peers) {
      if (peer.id == id && peer.alias != alias) {
        peer.alias = alias;
        changed = true;
      }
    }
    if (changed) {
      event = UpdateEvent.load;
      notifyListeners();
    }
  }
}
