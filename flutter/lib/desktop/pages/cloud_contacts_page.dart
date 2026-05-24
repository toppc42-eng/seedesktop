import 'dart:async';

import 'package:dynamic_layouts/dynamic_layouts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:flutter_hbb/common/widgets/premium_paywall_dialog.dart';
import 'package:flutter_hbb/utils/cloud_contact_peer.dart';
import 'package:flutter_hbb/utils/cloud_contacts_service.dart';
import 'package:flutter_hbb/utils/cloud_sync_service.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';

enum CloudContactsSort {
  nameAz,
  nameZa,
  dateAddedNewest,
  dateAddedOldest,
}

const String _kUngroupedKey = '';

TextDirection _pageTextDirection() {
  return localeName.toLowerCase().startsWith('he')
      ? TextDirection.rtl
      : TextDirection.ltr;
}

Alignment _pageAlignStart() {
  return _pageTextDirection() == TextDirection.rtl
      ? Alignment.centerRight
      : Alignment.centerLeft;
}

/// Cloud contacts: client/group sidebar + peer grid (same cards as Recent).
class CloudContactsPage extends StatefulWidget {
  const CloudContactsPage({super.key});

  @override
  CloudContactsPageState createState() => CloudContactsPageState();
}

class CloudContactsPageState extends State<CloudContactsPage> {
  Future<void> reloadCloudContacts() => _reload();
  static const double _sidebarWidth = 250;
  static const double _space = 12;
  static const String _onlineCb = 'callback_query_onlines';
  static const String _onlineHandlerName = 'cloud_contacts_page';

  final TextEditingController _searchController = TextEditingController();
  List<CloudContact> _contacts = [];
  Map<String, CloudContact> _contactById = {};
  Map<String, List<Peer>> _peersByGroup = {};
  String? _selectedGroupKey;
  CloudContactsSort _sort = CloudContactsSort.nameAz;
  bool _loading = false;
  String? _error;
  String? _userEmail;

  final Set<String> _visiblePeerIds = {};
  Set<String> _lastQueryPeerIds = {};
  DateTime _lastVisibilityChange = DateTime.now();
  DateTime _lastQueryTime = DateTime.now();
  var _onlinePollExit = false;
  var _queryCount = 0;
  Duration _queryInterval = const Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    () async {
      if (!await canUseCloudContactsLocal()) return;
      bind.mainLoadRecentPeers();
      bind.mainLoadFavPeers();
      platformFFI.registerEventHandler(_onlineCb, _onlineHandlerName, (evt) async {
        _onOnlineQueryResult(evt);
      });
      _startOnlinePolling();
      await _reload();
    }();
  }

  @override
  void dispose() {
    _onlinePollExit = true;
    platformFFI.unregisterEventHandler(_onlineCb, _onlineHandlerName);
    _searchController.dispose();
    super.dispose();
  }

  CloudContact? _contactFor(String remoteId) => _contactById[remoteId];

  void _onOnlineQueryResult(Map<String, dynamic> evt) {
    if (!mounted) return;
    final changed = _applyOnlineEvent(evt);
    if (changed) setState(() {});
  }

  bool _applyOnlineEvent(Map<String, dynamic> evt) {
    final onlines = _splitPeerIds(evt['onlines']);
    final offlines = _splitPeerIds(evt['offlines']);
    if (onlines.isEmpty && offlines.isEmpty) return false;

    var changed = false;
    for (final list in _peersByGroup.values) {
      for (final peer in list) {
        final id = peer.id.trim();
        if (onlines.contains(id) && !peer.online) {
          peer.online = true;
          changed = true;
        }
        if (offlines.contains(id) && peer.online) {
          peer.online = false;
          changed = true;
        }
      }
    }
    return changed;
  }

  Iterable<String> _splitPeerIds(dynamic value) {
    if (value is List) {
      return value.map((e) => e.toString().trim()).where((e) => e.isNotEmpty);
    }
    if (value is String) {
      return value
          .split(RegExp(r'[,\s]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
    }
    return const [];
  }

  void _startOnlinePolling() {
    () async {
      final publicServer = await bind.mainIsUsingPublicServer();
      if (!publicServer) {
        _queryInterval = const Duration(seconds: 6);
      }
      while (!_onlinePollExit) {
        final now = DateTime.now();
        if (!setEquals(_visiblePeerIds, _lastQueryPeerIds)) {
          if (now.difference(_lastVisibilityChange) >
              const Duration(seconds: 1)) {
            _queryVisibleOnlines();
          }
        } else if (_visiblePeerIds.isNotEmpty &&
            now.difference(_lastQueryTime) >= _queryInterval) {
          if (_queryCount < 3 || !publicServer) {
            bind.queryOnlines(ids: _visiblePeerIds.toList(growable: false));
            _lastQueryTime = now;
            _queryCount += 1;
          }
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }();
  }

  void _queryVisibleOnlines() {
    if (_visiblePeerIds.isEmpty) return;
    bind.queryOnlines(ids: _visiblePeerIds.toList(growable: false));
    _lastQueryPeerIds = Set<String>.from(_visiblePeerIds);
    _lastQueryTime = DateTime.now().subtract(_queryInterval);
    _queryCount = 0;
  }

  void _onCardVisibilityChanged(String peerId, VisibilityInfo info) {
    if (info.visibleFraction > 0.00001) {
      _visiblePeerIds.add(peerId);
    } else {
      _visiblePeerIds.remove(peerId);
    }
    _lastVisibilityChange = DateTime.now();
  }

  Widget _wrapOnlineCard(String peerId, Widget child) {
    return VisibilityDetector(
      key: ValueKey('cloud_contact_$peerId'),
      onVisibilityChanged: (info) => _onCardVisibilityChanged(peerId, info),
      child: child,
    );
  }

  Widget _contactCard(Peer peer) {
    final contact = _contactFor(peer.id);
    return _wrapOnlineCard(
      peer.id,
      CloudContactPeerCard(
        peer: peer,
        cloudSubtitle: contact?.hostname ?? '',
        cloudGroupsLabel: contact?.groupsDisplayLabel ?? '',
      ),
    );
  }

  Future<void> _reload() async {
    if (!await canUseCloudContactsLocal()) {
      if (!mounted) return;
      setState(() {
        _userEmail = null;
        _contacts = [];
        _contactById = {};
        _peersByGroup = {};
        _selectedGroupKey = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    if (CloudContactsService.resolveAuthToken() == null) {
      setState(() {
        _userEmail = null;
        _contacts = [];
        _contactById = {};
        _peersByGroup = {};
        _selectedGroupKey = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    final email = CloudContactsService.resolveUserEmail();
    if (email == null || email.isEmpty) {
      setState(() {
        _userEmail = null;
        _contacts = [];
        _contactById = {};
        _peersByGroup = {};
        _selectedGroupKey = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _userEmail = email;
    });
    try {
      final list = await CloudContactsService.fetchContacts(userEmail: email);
      final peersById = <String, Peer>{};
      for (final c in list) {
        peersById[c.remoteId] = await peerFromCloudContact(c);
      }
      final groupKeys = <String>{};
      for (final c in list) {
        if (c.isUngrouped) {
          groupKeys.add(_kUngroupedKey);
        } else {
          groupKeys.addAll(c.groups);
        }
      }
      final peersMap = <String, List<Peer>>{};
      for (final key in groupKeys) {
        final peers = <Peer>[];
        for (final c in list) {
          final inGroup = key == _kUngroupedKey
              ? c.isUngrouped
              : c.groups.contains(key);
          if (!inGroup) continue;
          final p = peersById[c.remoteId];
          if (p != null) peers.add(p);
        }
        _sortPeers(peers);
        peersMap[key] = peers;
      }
      if (!mounted) return;
      final keys = peersMap.keys.toList()..sort(_compareGroupKeys);
      setState(() {
        _contacts = list;
        _contactById = {for (final c in list) c.remoteId: c};
        _peersByGroup = peersMap;
        _loading = false;
        if (keys.isEmpty) {
          _selectedGroupKey = null;
        } else if (_selectedGroupKey == null ||
            !keys.contains(_selectedGroupKey)) {
          _selectedGroupKey = keys.first;
        }
      });
    } on CloudContactsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = translate('Operation failed');
        _loading = false;
      });
    }
  }

  int _compareGroupKeys(String a, String b) {
    if (a == _kUngroupedKey) return 1;
    if (b == _kUngroupedKey) return -1;
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  String _groupTitle(String key) {
    if (key == _kUngroupedKey) return translate('Cloud Contacts Ungrouped');
    return key;
  }

  List<CloudContact> _filteredContacts() {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _contacts;
    return _contacts
        .where((c) =>
            c.aliasName.toLowerCase().contains(q) ||
            c.remoteId.toLowerCase().contains(q) ||
            c.groups.any((g) => g.toLowerCase().contains(q)))
        .toList();
  }

  Map<String, List<Peer>> _filteredPeersByGroup() {
    final filteredIds = _filteredContacts().map((c) => c.remoteId).toSet();
    final out = <String, List<Peer>>{};
    for (final entry in _peersByGroup.entries) {
      final peers =
          entry.value.where((p) => filteredIds.contains(p.id)).toList();
      if (peers.isEmpty) continue;
      _sortPeers(peers);
      out[entry.key] = peers;
    }
    return out;
  }

  void _sortPeers(List<Peer> list) {
    final byId = {for (final c in _contacts) c.remoteId: c};
    double ts(Peer p) {
      final c = byId[p.id];
      return c?.createdAtEpoch ?? c?.updatedAtEpoch ?? 0;
    }

    int cmpName(Peer a, Peer b) {
      final na = (a.alias.isNotEmpty ? a.alias : a.id).toLowerCase();
      final nb = (b.alias.isNotEmpty ? b.alias : b.id).toLowerCase();
      return na.compareTo(nb);
    }

    switch (_sort) {
      case CloudContactsSort.nameAz:
        list.sort(cmpName);
        break;
      case CloudContactsSort.nameZa:
        list.sort((a, b) => cmpName(b, a));
        break;
      case CloudContactsSort.dateAddedNewest:
        list.sort((a, b) => ts(b).compareTo(ts(a)));
        break;
      case CloudContactsSort.dateAddedOldest:
        list.sort((a, b) => ts(a).compareTo(ts(b)));
        break;
    }
  }

  Widget _proLicenseLocked() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 48,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.7),
            ),
            const SizedBox(height: 16),
            Text(
              translate('Cloud Contacts PRO required'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              translate('Cloud Contacts PRO hint'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => showPremiumPaywallDialog(context),
              child: Text(translate('paywall-upgrade-cta')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loginPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.contacts_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.6),
            ),
            const SizedBox(height: 16),
            Text(
              translate('Cloud Contacts login required'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              translate('Cloud Contacts login hint'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Peer> _selectedPeers() {
    final key = _selectedGroupKey;
    if (key == null) return [];
    final peers = List<Peer>.from(_peersByGroup[key] ?? const []);
    final filteredIds = _filteredContacts().map((c) => c.remoteId).toSet();
    peers.retainWhere((p) => filteredIds.contains(p.id));
    _sortPeers(peers);
    return peers;
  }

  Widget _sidebar(Map<String, List<Peer>> grouped, ColorScheme cs) {
    final keys = grouped.keys.toList()..sort(_compareGroupKeys);
    final alignStart = _pageAlignStart();

    return Container(
      width: _sidebarWidth,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: alignStart,
            child: Text(
              translate('Client Group Name'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: keys.isEmpty
                ? Center(
                    child: Text(
                      translate('Cloud Contacts empty'),
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.separated(
                    itemCount: keys.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final key = keys[index];
                      final selected = key == _selectedGroupKey;
                      final count = grouped[key]?.length ?? 0;
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => setState(() => _selectedGroupKey = key),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? cs.primary.withOpacity(0.12)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                key == _kUngroupedKey
                                    ? Icons.folder_off_outlined
                                    : Icons.folder_outlined,
                                size: 20,
                                color: selected ? cs.primary : null,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _groupTitle(key),
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              Text(
                                '$count',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _peersGrid(List<Peer> peers) {
    if (peers.isEmpty) {
      return Center(
        child: Text(
          translate('search_no_results'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Obx(() {
      if (stateGlobal.isPortrait.isTrue) {
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: peers.length,
          itemBuilder: (_, i) =>
              _contactCard(peers[i]).marginOnly(bottom: _space / 2),
        );
      }

      if (peerCardUiType.value == PeerUiType.list) {
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: peers.length,
          itemBuilder: (_, i) =>
              _contactCard(peers[i]).marginOnly(bottom: _space / 2),
        );
      }

      if (peerCardUiType.value == PeerUiType.grid) {
        return DynamicGridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithWrapping(
            mainAxisSpacing: _space / 2,
            crossAxisSpacing: _space,
          ),
          itemCount: peers.length,
          itemBuilder: (_, i) => peerGridCell(_contactCard(peers[i])),
        );
      }

      return SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: _space,
          runSpacing: _space / 2,
          children: peers
              .map((p) => SizedBox(
                    width: kPeerGridCardWidth,
                    child: _contactCard(p),
                  ))
              .toList(),
        ),
      );
    });
  }

  Widget _mainPanel(Map<String, List<Peer>> grouped) {
    final alignStart = _pageAlignStart();
    final peers = _selectedPeers();
    final groupLabel = _selectedGroupKey != null
        ? _groupTitle(_selectedGroupKey!)
        : '';

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Align(
              alignment: alignStart,
              child: Text(
                groupLabel,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Expanded(child: _peersGrid(peers)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: canUseCloudContactsLocal(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.data != true) {
          return Directionality(
            textDirection: _pageTextDirection(),
            child: _proLicenseLocked(),
          );
        }
        return _buildLicensedBody(context);
      },
    );
  }

  Widget _buildLicensedBody(BuildContext context) {
    final dir = _pageTextDirection();
    final alignStart = _pageAlignStart();
    final cs = Theme.of(context).colorScheme;

    if (_userEmail == null || _userEmail!.isEmpty) {
      return Directionality(
        textDirection: dir,
        child: _loginPrompt(),
      );
    }

    final grouped = _filteredPeersByGroup();
    final hasAny = grouped.values.any((l) => l.isNotEmpty);

    return Directionality(
      textDirection: dir,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    textDirection: dir,
                    decoration: InputDecoration(
                      hintText: translate('Search Contacts'),
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: translate('Refresh'),
                  onPressed: _loading ? null : _reload,
                  icon: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: alignStart,
                    child: Text(
                      translate('Cloud Contacts'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                DropdownButton<CloudContactsSort>(
                  value: _sort,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(
                      value: CloudContactsSort.nameAz,
                      child: Text(translate('Sort A-Z')),
                    ),
                    DropdownMenuItem(
                      value: CloudContactsSort.nameZa,
                      child: Text(translate('Sort Z-A')),
                    ),
                    DropdownMenuItem(
                      value: CloudContactsSort.dateAddedNewest,
                      child: Text(translate('Sort by date added (newest)')),
                    ),
                    DropdownMenuItem(
                      value: CloudContactsSort.dateAddedOldest,
                      child: Text(translate('Sort by date added (oldest)')),
                    ),
                  ],
                  onChanged: _loading
                      ? null
                      : (v) {
                          if (v != null) setState(() => _sort = v);
                        },
                ),
              ],
            ),
          ),
          if (CloudSyncService.hasToken)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: alignStart,
                child: Text(
                  _userEmail!,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(color: cs.error, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: _loading && _contacts.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : !hasAny
                    ? Center(
                        child: Text(
                          translate('Cloud Contacts empty'),
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _sidebar(grouped, cs),
                            const SizedBox(width: 12),
                            _mainPanel(grouped),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
