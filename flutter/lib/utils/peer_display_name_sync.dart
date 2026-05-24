import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/cloud_contacts_service.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';

/// Keeps the display name (alias) in sync across Recent, Favorites, LAN, local
/// peer options, and cloud contacts — regardless of where the user edits it.
Future<bool> applyPeerDisplayNameEverywhere({
  required String remoteId,
  required String alias,
  List<String>? cloudGroups,
  Peer? peer,
  /// When true (e.g. Edit Contact dialog), always upsert cloud row.
  bool forceCloudUpsert = false,
  /// When true, refresh Recent/Favorites/LAN lists after local save.
  bool reloadPeerLists = true,
}) async {
  final id = remoteId.trim();
  final name = alias.trim();
  if (id.isEmpty || name.isEmpty) return false;

  await bind.mainSetPeerOption(id: id, key: 'alias', value: name);
  await bind.mainSetPeerAlias(id: id, alias: name);

  gFFI.favoritePeersModel.updateAlias(id, name);
  gFFI.recentPeersModel.updateAlias(id, name);
  gFFI.lanPeersModel.updateAlias(id, name);
  gFFI.groupModel.peersModel.updateAlias(id, name);

  if (reloadPeerLists) {
    await bind.mainLoadRecentPeers();
    await bind.mainLoadFavPeers();
    await bind.mainLoadLanPeers();
  }

  Peer? sourcePeer = peer;
  if (sourcePeer == null) {
    for (final p in gFFI.recentPeersModel.peers) {
      if (p.id == id) {
        sourcePeer = p;
        break;
      }
    }
    sourcePeer ??= () {
      for (final p in gFFI.favoritePeersModel.peers) {
        if (p.id == id) return p;
      }
      return null;
    }();
  }

  if (await canUseCloudContactsLocal() &&
      CloudContactsService.resolveAuthToken() != null) {
    try {
      CloudContact? existing;
      if (!forceCloudUpsert) {
        existing = await CloudContactsService.findByRemoteId(id);
        if (existing == null) {
          return true;
        }
      } else {
        try {
          existing = await CloudContactsService.findByRemoteId(id);
        } catch (_) {}
      }

      final groups = cloudGroups ??
          (existing != null
              ? List<String>.from(existing.groups)
              : const <String>[]);
      await CloudContactsService.upsertContact(
        remoteId: id,
        aliasName: name,
        groups: groups,
        os: existing?.os ?? '',
        hostname: existing?.hostname ?? '',
        sourcePeer: sourcePeer,
      );
    } on CloudContactsException {
      // Local rename still applied; cloud sync is best-effort.
    }
  }

  return true;
}
