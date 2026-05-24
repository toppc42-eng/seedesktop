import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/cloud_contacts_service.dart';
/// Apply cloud `os` / `hostname` onto a [Peer] for cards (platform icon + subtitle).
void applyCloudFieldsToPeer(Peer peer, CloudContact contact) {
  final os = contact.os.trim();
  if (os.isNotEmpty) {
    peer.platform = os;
  }
  final parsed = CloudContactsService.parseHostnameField(contact.hostname);
  if (parsed.username.isNotEmpty) {
    peer.username = parsed.username;
  }
  if (parsed.hostname.isNotEmpty) {
    peer.hostname = parsed.hostname;
  } else if (contact.hostname.trim().isNotEmpty) {
    peer.hostname = contact.hostname.trim();
  }
}

/// Build a [Peer] for grid cards (preview/online) from a cloud contact row.
Future<Peer> peerFromCloudContact(CloudContact contact) async {
  final id = contact.remoteId;
  Peer? base;
  for (final p in gFFI.recentPeersModel.peers) {
    if (p.id == id) {
      base = Peer.copy(p);
      break;
    }
  }
  if (base == null) {
    for (final p in gFFI.favoritePeersModel.peers) {
      if (p.id == id) {
        base = Peer.copy(p);
        break;
      }
    }
  }

  final savedAlias = await bind.mainGetPeerOption(id: id, key: 'alias');
  final previewPath =
      await bind.mainGetPeerOption(id: id, key: 'preview_path');
  final platform = await bind.mainGetPeerOption(id: id, key: 'platform');
  final username = await bind.mainGetPeerOption(id: id, key: 'username');
  final hostname = await bind.mainGetPeerOption(id: id, key: 'hostname');

  final alias = contact.aliasName.isNotEmpty
      ? contact.aliasName
      : (savedAlias.isNotEmpty
          ? savedAlias
          : (base?.alias ?? ''));

  if (base != null) {
    base.alias = alias;
    if (previewPath.isNotEmpty) base.previewPath = previewPath;
    applyCloudFieldsToPeer(base, contact);
    await clearLegacyLocalGroupForPeer(id);
    return base;
  }

  final parsed = CloudContactsService.parseHostnameField(contact.hostname);
  final peer = Peer(
    id: id,
    hash: '',
    password: '',
    username: parsed.username.isNotEmpty
        ? parsed.username
        : username,
    hostname: parsed.hostname.isNotEmpty
        ? parsed.hostname
        : (contact.hostname.isNotEmpty ? contact.hostname : hostname),
    platform: contact.os.isNotEmpty
        ? contact.os
        : (platform.isNotEmpty ? platform : 'Windows'),
    alias: alias,
    tags: [],
    forceAlwaysRelay: false,
    rdpPort: '',
    rdpUsername: '',
    loginName: '',
    device_group_name: '',
    note: '',
    previewPath: previewPath,
  );
  applyCloudFieldsToPeer(peer, contact);
  await clearLegacyLocalGroupForPeer(id);
  return peer;
}
