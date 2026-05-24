import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/common/widgets/rmm_pro_gate_dialog.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/agent_heartbeat_manager.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';
import 'package:flutter_hbb/utils/license_manager.dart';
import 'package:url_launcher/url_launcher.dart';

enum _RmmListFilter { all, online, offline }

class MyDevicesPage extends StatefulWidget {
  const MyDevicesPage({super.key});

  @override
  State<MyDevicesPage> createState() => _MyDevicesPageState();
}

class _MyDevicesPageState extends State<MyDevicesPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// Rows for the main table: VPS pull response minus this machine (local row added separately).
  List<AgentInfo> _remoteAgents = [];
  /// Live telemetry row for this workstation (top of table).
  AgentInfo? _localMyDeviceRow;
  String _localAgentId = '';
  bool _loading = false;
  String? _error;
  DateTime? _lastRefreshed;

  /// Highlighted row in the main table.
  String? _selectedAgentId;

  /// `true` only for active PRO-RMM; `null` until first license check completes.
  bool? _hasRmmLicense;

  /// Normalized keys for peers that show **green** in Recent / Favorites / LAN (rebuilt each [build]).
  Set<String> _rmmRecentOnlineKeysCache = {};

  final TextEditingController _searchController = TextEditingController();
  _RmmListFilter _listFilter = _RmmListFilter.all;

  Future<void> _updateRmmLicense() async {
    final v = await hasRmmLicenseLocal();
    if (mounted) setState(() => _hasRmmLicense = v);
  }

  @override
  void initState() {
    super.initState();
    gFFI.recentPeersModel.addListener(_onRecentPeersChanged);
    gFFI.favoritePeersModel.addListener(_onRecentPeersChanged);
    gFFI.lanPeersModel.addListener(_onRecentPeersChanged);
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await _updateRmmLicense();
    if (!mounted) return;
    if (_hasRmmLicense == true) {
      await _fetch();
    }
  }

  Future<void> _reloadRmmPage() async {
    await _updateRmmLicense();
    if (!mounted) return;
    if (_hasRmmLicense == true) {
      await _fetch();
    } else {
      setState(() {});
    }
  }

  String _localizedRmmError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('license_key') && lower.contains('requested_ids')) {
      return translate('err-rmm-license-required');
    }
    if (raw.contains('נדרש') &&
        (raw.contains('license') || raw.contains('רישיון'))) {
      return translate('err-rmm-license-required');
    }
    return raw;
  }

  @override
  void dispose() {
    _searchController.dispose();
    gFFI.recentPeersModel.removeListener(_onRecentPeersChanged);
    gFFI.favoritePeersModel.removeListener(_onRecentPeersChanged);
    gFFI.lanPeersModel.removeListener(_onRecentPeersChanged);
    super.dispose();
  }

  void _onRecentPeersChanged() {
    if (!mounted) return;
    setState(() {
      _sortRemoteAgentsByRmmOnline();
    });
  }

  /// Keys used to match [AgentInfo.agentId] to “green” peers (spaces stripped + license-style id).
  static void _addRmmMatchingKeys(Set<String> set, String rawPeerId) {
    final s = normalizeSeeDesktopId(rawPeerId);
    if (s.isNotEmpty) set.add(s);
    final n = normalizePeerIdForLicenseTracking(rawPeerId);
    if (n.isNotEmpty) set.add(n);
  }

  /// Recent / Favorites / LAN peers with rendezvous [Peer.online] == true (same source as green dots).
  Set<String> _recentOnlineNormalizedKeys() {
    final set = <String>{};
    void absorb(Peer p) {
      if (!p.online) return;
      _addRmmMatchingKeys(set, p.id);
    }
    for (final p in gFFI.recentPeersModel.peers) {
      absorb(p);
    }
    for (final p in gFFI.favoritePeersModel.peers) {
      absorb(p);
    }
    for (final p in gFFI.lanPeersModel.peers) {
      absorb(p);
    }
    return set;
  }

  bool _inRecentOnlineSet(AgentInfo a, Set<String> keys) {
    final k1 = normalizeSeeDesktopId(a.agentId);
    final k2 = normalizePeerIdForLicenseTracking(a.agentId);
    return (k1.isNotEmpty && keys.contains(k1)) ||
        (k2.isNotEmpty && keys.contains(k2));
  }

  /// True if: id is online in Recent/Fav/LAN, **or** server [AgentInfo.isOnline], **or** VPS status online/in_session.
  bool _rmmEffectiveOnline(AgentInfo a, Set<String> recentOnlineKeys) {
    if (_inRecentOnlineSet(a, recentOnlineKeys)) return true;
    if (a.isOnline) return true;
    final st = a.status.toLowerCase().trim();
    return st == 'online' || st == 'in_session';
  }

  /// Effective status chip: [in_session] only when also “alive” per [_rmmEffectiveOnline].
  String _rmmEffectiveStatusLabel(AgentInfo a, Set<String> recentOnlineKeys) {
    if (!_rmmEffectiveOnline(a, recentOnlineKeys)) return 'offline';
    final st = a.status.toLowerCase().trim();
    if (st == 'in_session') return 'in_session';
    return 'online';
  }

  void _sortRemoteAgentsByRmmOnline() {
    final keys = _recentOnlineNormalizedKeys();
    _remoteAgents.sort((a, b) {
      final oa = _rmmEffectiveOnline(a, keys);
      final ob = _rmmEffectiveOnline(b, keys);
      if (oa != ob) return oa ? -1 : 1;
      return a.computerName
          .toLowerCase()
          .compareTo(b.computerName.toLowerCase());
    });
  }

  bool _agentMatchesSearch(AgentInfo a, String queryLower) {
    if (queryLower.isEmpty) return true;
    if (a.computerName.toLowerCase().contains(queryLower)) return true;
    if (a.agentId.toLowerCase().contains(queryLower)) return true;
    if (a.osVersion.toLowerCase().contains(queryLower)) return true;
    final rawId = a.agentId.trim();
    final forFmt = trimID(rawId);
    if (forFmt.toLowerCase().contains(queryLower)) return true;
    if (int.tryParse(forFmt) != null) {
      try {
        if (formatID(forFmt).toLowerCase().contains(queryLower)) return true;
      } catch (_) {}
    }
    return false;
  }

  /// Remote agents only — filter + search (no local row).
  List<AgentInfo> _visibleRemoteAgentsOnly() {
    final keys = _rmmRecentOnlineKeysCache;
    final q = _searchController.text.trim().toLowerCase();
    Iterable<AgentInfo> it = _remoteAgents;
    switch (_listFilter) {
      case _RmmListFilter.online:
        it = it.where((a) => _rmmEffectiveOnline(a, keys));
        break;
      case _RmmListFilter.offline:
        it = it.where((a) => !_rmmEffectiveOnline(a, keys));
        break;
      case _RmmListFilter.all:
        break;
    }
    if (q.isNotEmpty) {
      it = it.where((a) => _agentMatchesSearch(a, q));
    }
    return it.toList();
  }

  /// Table rows: **this device** first (when shown), then filtered remotes.
  List<AgentInfo> _visibleTableAgents() {
    final keys = _rmmRecentOnlineKeysCache;
    final q = _searchController.text.trim().toLowerCase();
    final rest = _visibleRemoteAgentsOnly();
    final local = _localMyDeviceRow;
    if (local == null) return rest;

    var includeLocal = true;
    switch (_listFilter) {
      case _RmmListFilter.online:
        includeLocal = _rmmEffectiveOnline(local, keys);
        break;
      case _RmmListFilter.offline:
        includeLocal = !_rmmEffectiveOnline(local, keys);
        break;
      case _RmmListFilter.all:
        break;
    }
    if (q.isNotEmpty) {
      includeLocal = includeLocal && _agentMatchesSearch(local, q);
    }
    if (!includeLocal) return rest;
    return [local, ...rest];
  }

  bool _hasMyDevicesTableContent() =>
      _remoteAgents.isNotEmpty || _localMyDeviceRow != null;

  bool _isThisDeviceRow(AgentInfo a) {
    final local = _localMyDeviceRow;
    if (local == null) return false;
    return normalizePeerIdForLicenseTracking(a.agentId) ==
        normalizePeerIdForLicenseTracking(local.agentId);
  }

  Future<void> _fetch() async {
    if (_loading) return;
    if (_hasRmmLicense != true) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    AgentInfo? localRow;
    try {
      localRow = await buildLocalAgentInfoForMyDevicesTable();
    } catch (_) {}
    try {
      final agents = await fetchAllAgentsForMyDevicesTable();
      final localId = (await bind.mainGetMyId()).trim();
      final normLocal = normalizePeerIdForLicenseTracking(localId);

      final remotes = agents.where((a) {
        final aid = normalizePeerIdForLicenseTracking(a.agentId);
        return normLocal.isEmpty || aid != normLocal;
      }).toList();
      final sortKeys = _recentOnlineNormalizedKeys();
      remotes.sort((a, b) {
        final oa = _rmmEffectiveOnline(a, sortKeys);
        final ob = _rmmEffectiveOnline(b, sortKeys);
        if (oa != ob) return oa ? -1 : 1;
        return a.computerName
            .toLowerCase()
            .compareTo(b.computerName.toLowerCase());
      });

      if (mounted) {
        setState(() {
          _localAgentId = localId;
          _remoteAgents = remotes;
          _localMyDeviceRow = localRow;
          _loading = false;
          _lastRefreshed = DateTime.now();
        });
        _syncSelectionAfterFetch(remotes, localRow);
        unawaited(_updateRmmLicense());
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _localizedRmmError(e.toString());
          _localMyDeviceRow = localRow;
        });
      }
    }
  }

  void _syncSelectionAfterFetch(List<AgentInfo> remotes, AgentInfo? localRow) {
    final id = _selectedAgentId;
    if (id == null) return;
    final idTrim = id.trim();
    if (remotes.any((x) => x.agentId.trim() == idTrim)) return;
    if (localRow != null && localRow.agentId.trim() == idTrim) return;
    setState(() => _selectedAgentId = null);
  }

  void _showLastLogDialog(AgentInfo a) {
    final text = a.lastLog ?? '';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('לוג: ${a.computerName}'),
        content: SizedBox(
          width: 480,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              BotToast.showText(text: 'הועתק ללוח');
            },
            child: const Text('Copy to Clipboard'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _rmmRecentOnlineKeysCache = _recentOnlineNormalizedKeys();
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.bodySmall
        ?.copyWith(fontWeight: FontWeight.w700, fontSize: 12);

    if (_hasRmmLicense == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _headerRow(theme, enableRefresh: false),
            const Divider(height: 16),
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        ),
      );
    }
    if (_hasRmmLicense != true) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _headerRow(theme),
            const Divider(height: 16),
            Expanded(child: _rmmProRequiredBody(theme)),
          ],
        ),
      );
    }

    final visibleAgents = _visibleTableAgents();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _headerRow(theme),
          const Divider(height: 16),
          if (!_loading && _error == null && _hasMyDevicesTableContent()) ...[
            _searchBar(),
            const SizedBox(height: 8),
            _filterStrip(),
            const SizedBox(height: 8),
            _extraSummaryStrip(),
          ],
          if (_localAgentId.isNotEmpty) _localIdBanner(),
          if (_error != null) _errorBanner(),
          if (!_loading && _error == null && !_hasMyDevicesTableContent())
            _emptyState(),
          if (_hasMyDevicesTableContent() && visibleAgents.isEmpty)
            _noFilterMatchesState(),
          if (_hasMyDevicesTableContent() && visibleAgents.isNotEmpty)
            _table(headerStyle, visibleAgents),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-widgets
  // ---------------------------------------------------------------------------

  Widget _headerRow(ThemeData theme, {bool enableRefresh = true}) {
    return Row(
      children: [
        const Icon(Icons.devices, size: 18, color: Colors.blueGrey),
        const SizedBox(width: 8),
        Text(
          'My Devices',
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        const Spacer(),
        if (_lastRefreshed != null) ...[
          Text(
            'עודכן: ${_fmtHms(_lastRefreshed!)}',
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
          const SizedBox(width: 6),
        ],
        IconButton(
          icon: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh, size: 18),
          tooltip: 'רענן',
          onPressed: !enableRefresh || _loading ? null : _reloadRmmPage,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Widget _rmmProRequiredBody(ThemeData theme) {
    final rtl = bind.mainGetLocalOption(key: kCommConfKeyLang) == 'he';
    final muted = theme.textTheme.bodyMedium?.copyWith(
      height: 1.45,
      color: theme.brightness == Brightness.dark
          ? Colors.white70
          : const Color(0xFF4B5563),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.workspace_premium_outlined,
                size: 56,
                color: theme.colorScheme.primary.withOpacity(0.9),
              ),
              const SizedBox(height: 16),
              Text(
                translate('rmm-pro-gate-title'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                translate('rmm-pro-gate-body'),
                textAlign: rtl ? TextAlign.right : TextAlign.start,
                style: muted,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                onPressed: () async {
                  final uri = Uri.parse(kSeeDesktopProPurchaseUrl);
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                },
                icon: const Icon(Icons.shopping_bag_outlined, size: 20),
                label: Text(
                  translate('rmm-pro-gate-buy'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => showRmmProGateDialog(context),
                child: Text(translate('rmm-pro-gate-details')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _localIdBanner() {
    final trimmed = trimID(_localAgentId);
    final display = int.tryParse(trimmed) != null ? formatID(trimmed) : trimmed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.badge_outlined, size: 16, color: Colors.blueGrey.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'מזהה סוכן מקומי (SeeDesktop): $display',
              style: TextStyle(
                fontSize: 11,
                color: Colors.blueGrey.shade800,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Tooltip(
            message: 'מזהה מלא: $trimmed',
            child: IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: 'העתק מזהה',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: trimmed));
                BotToast.showText(text: 'המזהה הועתק');
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return TextField(
      controller: _searchController,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'חיפוש: שם מחשב, מזהה SeeDesktop, מערכת הפעלה…',
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 18),
                tooltip: 'נקה',
                onPressed: () {
                  _searchController.clear();
                  setState(() {});
                },
              ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  Widget _filterStrip() {
    final keys = _rmmRecentOnlineKeysCache;
    var total = _remoteAgents.length;
    var online =
        _remoteAgents.where((a) => _rmmEffectiveOnline(a, keys)).length;
    final loc = _localMyDeviceRow;
    if (loc != null) {
      total += 1;
      if (_rmmEffectiveOnline(loc, keys)) online += 1;
    }
    final offline = total - online;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _filterPill(
          label: 'מכשירים $total',
          selected: _listFilter == _RmmListFilter.all,
          onTap: () => setState(() => _listFilter = _RmmListFilter.all),
          accent: Colors.blueGrey.shade700,
        ),
        _filterPill(
          label: '$online Online',
          selected: _listFilter == _RmmListFilter.online,
          onTap: () => setState(() => _listFilter = _RmmListFilter.online),
          accent: const Color(0xFF16A34A),
        ),
        _filterPill(
          label: '$offline Offline',
          selected: _listFilter == _RmmListFilter.offline,
          onTap: () => setState(() => _listFilter = _RmmListFilter.offline),
          accent: Colors.grey.shade700,
        ),
      ],
    );
  }

  Widget _filterPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required Color accent,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? accent.withOpacity(0.14) : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? accent : Colors.grey.shade400,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? accent : Colors.blueGrey.shade800,
            ),
          ),
        ),
      ),
    );
  }

  /// סשן / משימות — בנפרד מכפתורי הסינון הראשיים.
  Widget _extraSummaryStrip() {
    final keys = _rmmRecentOnlineKeysCache;
    final agentsForSummary = <AgentInfo>[
      ..._remoteAgents,
      if (_localMyDeviceRow != null) _localMyDeviceRow!,
    ];
    final inSession = agentsForSummary
        .where((a) => _rmmEffectiveStatusLabel(a, keys) == 'in_session')
        .length;
    final pending =
        agentsForSummary.where((a) => a.hasPendingTask).length;
    if (inSession == 0 && pending == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withOpacity(0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (inSession > 0) _badge('$inSession בסשן', Colors.blueAccent),
          if (inSession > 0 && pending > 0) const SizedBox(width: 8),
          if (pending > 0) _badge('$pending ממתינים', Colors.orange),
        ],
      ),
    );
  }

  Widget _noFilterMatchesState() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, size: 42, color: Colors.grey.shade400),
              const SizedBox(height: 10),
              Text(
                'אין מכשירים התואמים לסינון או לחיפוש',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'ברשימה המלאה יש ${_remoteAgents.length + (_localMyDeviceRow != null ? 1 : 0)} מכשירים',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _listFilter = _RmmListFilter.all;
                    _searchController.clear();
                  });
                },
                icon: const Icon(Icons.filter_alt_off, size: 18),
                label: const Text('נקה סינון וחיפוש'),
              ),
            ],
          ),
        ),
      );

  Widget _errorBanner() {
    final rtl = bind.mainGetLocalOption(key: kCommConfKeyLang) == 'he';
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
      ),
      child: Row(children: [
        const Icon(Icons.error_outline, color: Colors.red, size: 16),
        const SizedBox(width: 8),
        Flexible(
          child: Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: Text(
              _error!,
              textAlign: rtl ? TextAlign.right : TextAlign.left,
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: _fetch,
          icon: const Icon(Icons.refresh, size: 14),
          label: Text(
            translate('rmm-try-again'),
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ]),
    );
  }

  Widget _emptyState() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 40),
            Icon(Icons.devices_outlined,
                size: 48, color: Colors.grey.withOpacity(0.5)),
            const SizedBox(height: 12),
            const Text('אין מכשירים מרוחקים להצגה.',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 6),
            const Text(
              'מוצגים כל המזהים שנאספו מ־Recent, פנקס, קבוצה וכו׳; לכל אחד יש שורה. נתוני חומרה/סטטוס מלאים מגיעים מהשרת כשהסוכן רשום ב־VPS.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _fetch,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('רענן'),
            ),
          ],
        ),
      );

  Widget _table(TextStyle? headerStyle, List<AgentInfo> visibleAgents) =>
      Expanded(
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 36,
              dataRowMinHeight: 44,
              dataRowMaxHeight: 140,
              columnSpacing: 18,
              columns: [
                DataColumn(label: Text('מצב', style: headerStyle)),
                DataColumn(label: Text('שם מחשב', style: headerStyle)),
                DataColumn(label: Text('מערכת הפעלה', style: headerStyle)),
                DataColumn(label: Text('מעבד', style: headerStyle)),
                DataColumn(label: Text('זיכרון', style: headerStyle)),
                DataColumn(label: Text('דיסק C:', style: headerStyle)),
                DataColumn(label: Text('S.M.A.R.T', style: headerStyle)),
                DataColumn(label: Text('נראה לאחרונה', style: headerStyle)),
                DataColumn(label: Text('סטטוס', style: headerStyle)),
                DataColumn(label: Text('מזהה SeeDesktop', style: headerStyle)),
                DataColumn(label: Text('פעולות', style: headerStyle)),
              ],
              rows: visibleAgents.map(_buildRow).toList(),
            ),
          ),
        ),
      );

  DataRow _buildRow(AgentInfo a) {
    final keys = _rmmRecentOnlineKeysCache;
    final effLabel = _rmmEffectiveStatusLabel(a, keys);
    final showOnline = effLabel != 'offline';
    final dotColor =
        showOnline ? const Color(0xFF16A34A) : Colors.grey;
    final stateText = effLabel == 'in_session'
        ? 'In session'
        : (showOnline ? 'Online' : 'Offline');

    return DataRow(
      selected:
          _selectedAgentId != null && a.agentId.trim() == _selectedAgentId,
      onSelectChanged: (selected) {
        if (selected != true) return;
        setState(() => _selectedAgentId = a.agentId.trim());
      },
      cells: [
        DataCell(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration:
                  BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              stateText,
              style: TextStyle(
                  fontSize: 11, color: dotColor, fontWeight: FontWeight.w600),
            ),
          ],
        )),
        DataCell(_nameCell(a)),
        DataCell(Tooltip(
          message: a.osVersion,
          child: SizedBox(
            width: 170,
            child: Text(a.osVersion,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11)),
          ),
        )),
        DataCell(_cpuCell(a)),
        DataCell(_memoryCell(a)),
        DataCell(_diskCell(a)),
        DataCell(_dashOrValue(a.smartStatus)),
        DataCell(Text(
          _formatLastSeenDisplay(a),
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        )),
        DataCell(_statusChip(_rmmEffectiveStatusLabel(a, keys))),
        DataCell(_seedesktopIdCell(a.agentId)),
        DataCell(_actionsCell(a)),
      ],
    );
  }

  Widget _dashOrValue(String? v) {
    final s = v?.trim() ?? '';
    final text = s.isEmpty ? '—' : s;
    return Text(text, style: const TextStyle(fontSize: 11));
  }

  /// מעבד: שורה 1 `cpu_model`, שורה 2 אחוזי שימוש (גיבוי לסוכנים ישנים).
  Widget _cpuCell(AgentInfo a) {
    const maxW = 200.0;
    final model = a.cpuModel?.trim() ?? '';
    final usage = a.cpuUsage?.trim() ?? '';
    final usageLine = usage.isNotEmpty ? usage : '—';

    if (model.isEmpty ||
        model.toLowerCase() == 'null' ||
        model.toLowerCase() == 'unknown') {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxW),
        child: _dashOrValue(a.cpuUsage),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxW),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            model,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            usageLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: Colors.blueGrey.shade700,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  String _ramSlotsText(AgentInfo a) {
    final u = a.ramSlotsUsage?.trim();
    if (u != null && u.isNotEmpty && u.toLowerCase() != 'null') return u;
    if (a.ramSlotsUsed != null && a.ramSlotsTotal != null) {
      return '${a.ramSlotsUsed}/${a.ramSlotsTotal}';
    }
    if (a.ramSlotsUsed != null) return '${a.ramSlotsUsed}';
    return '—';
  }

  String _hwLabelOrDash(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty ||
        s.toLowerCase() == 'null' ||
        s.toLowerCase() == 'unknown') {
      return '—';
    }
    return s;
  }

  static String _normDriveId(String raw) {
    var s = raw.trim().replaceAll('\\', '').replaceAll('/', '');
    if (s.isEmpty) return '';
    s = s.toUpperCase();
    if (s.length == 1) return '$s:';
    if (s.length >= 2 && s[1] == ':') return s.substring(0, 2);
    return s;
  }

  String _displayDriveId(String raw) {
    final n = _normDriveId(raw);
    return n.isNotEmpty ? n : (raw.trim().isEmpty ? '—' : raw.trim());
  }

  /// רק כונן C: — עמודת הטבלה מיועדת ל־C:.
  LogicalDiskSpec? _logicalSpecForC(AgentInfo a) {
    for (final s in a.logicalDiskSpecs) {
      if (_normDriveId(s.id) == 'C:') return s;
    }
    return null;
  }

  HwHealthDiskVolume? _volumeForC(AgentInfo a) {
    for (final v in a.hwVolumes) {
      if (_normDriveId(v.id) == 'C:') return v;
    }
    return null;
  }

  String _logicalDiskLine1(LogicalDiskSpec s) {
    final idDisp = _displayDriveId(s.id);
    var t = s.diskType.trim();
    var m = s.diskModel.trim();
    if (t.isEmpty || t.toLowerCase() == 'unknown') t = 'Unknown';
    if (m.isEmpty || m.toLowerCase() == 'unknown') m = 'Unknown';
    return '$idDisp $t - $m';
  }

  String _fmtGbVal(double? g) {
    if (g == null) return '—';
    if ((g - g.roundToDouble()).abs() < 0.05) return g.round().toString();
    return g.toStringAsFixed(1);
  }

  String _diskTypeModelLineDiskVolume(HwHealthDiskVolume v) {
    var t = v.diskType.trim();
    var m = v.diskModel.trim();
    if (t.isEmpty || t.toLowerCase() == 'unknown') t = 'Unknown';
    if (m.isEmpty || m.toLowerCase() == 'unknown') m = 'Unknown';
    return '$t - $m';
  }

  /// זיכרון: שורה 1 מ־`hw_health`, שורה 2 שימוש ב-RAM (לרוב אחוזים).
  Widget _memoryCell(AgentInfo a) {
    const maxW = 200.0;
    final rt = a.ramType?.trim() ?? '';
    final rs = a.ramSpeed?.trim() ?? '';
    final hasRamHw = (rt.isNotEmpty && rt.toLowerCase() != 'null') ||
        (rs.isNotEmpty && rs.toLowerCase() != 'null') ||
        (a.ramSlotsUsage?.trim().isNotEmpty == true) ||
        a.ramSlotsUsed != null ||
        a.ramSlotsTotal != null;

    final usage = a.ramUsage?.trim() ?? '';
    final usageLine = usage.isNotEmpty ? usage : '—';

    if (!hasRamHw) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxW),
        child: _dashOrValue(a.ramUsage),
      );
    }

    final t2 = _hwLabelOrDash(a.ramType);
    final s2 = _hwLabelOrDash(a.ramSpeed);
    final sl = _ramSlotsText(a);
    final line1 = '$t2 @ $s2 (Slots: $sl)';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxW),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            line1,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            usageLine,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: Colors.blueGrey.shade700,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  /// דיסק C:: שורה 1 מ־`logical_disk_specs` (או `disks` / `disk_info`), שורה 2 נפח חופשי/כולל.
  Widget _diskCell(AgentInfo a) {
    const maxW = 220.0;
    final freeFallback =
        (a.diskFree?.trim().isEmpty ?? true) ? '—' : a.diskFree!.trim();

    final specC = _logicalSpecForC(a);
    final volC = _volumeForC(a);

    String? line1;
    if (specC != null) {
      line1 = _logicalDiskLine1(specC);
    } else if (volC != null) {
      final idDisp = _displayDriveId(volC.id);
      final body = _diskTypeModelLineDiskVolume(volC);
      line1 = idDisp != '—' ? '$idDisp $body' : body;
    }

    final String line2;
    if (volC != null && (volC.freeGb != null || volC.totalGb != null)) {
      line2 =
          '${_fmtGbVal(volC.freeGb)} GB free / ${_fmtGbVal(volC.totalGb)} GB';
    } else {
      line2 = freeFallback;
    }

    if (line1 != null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxW),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              line1,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              line2,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: Colors.blueGrey.shade700,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      );
    }

    final di = a.diskInfo.isNotEmpty ? a.diskInfo.first : null;
    final fallbackLine1 = di != null
        ? '${di.diskType.trim().isEmpty || di.diskType.toLowerCase() == 'unknown' ? 'Unknown' : di.diskType} - ${di.model.trim().isEmpty || di.model.toLowerCase() == 'unknown' ? 'Unknown' : di.model}'
        : null;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxW),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fallbackLine1 != null)
            Text(
              fallbackLine1,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          Text(
            freeFallback,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: Colors.blueGrey.shade700,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  Widget _seedesktopIdCell(String rawId) {
    final trimmed = trimID(rawId);
    if (trimmed.isEmpty) {
      return const Text(
        '—',
        style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
      );
    }
    final display = int.tryParse(trimmed) != null ? formatID(trimmed) : trimmed;
    return Tooltip(
      message: 'מזהה מלא (agent_id): $trimmed',
      child: SelectableText(
        display,
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
      ),
    );
  }

  String _telemetryOrDash(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? '—' : t;
  }

  Widget _nameCell(AgentInfo a) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 280),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  a.computerName,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              if (_isThisDeviceRow(a)) ...[
                const SizedBox(width: 6),
                _badge(
                  translate('rmm-this-device-badge'),
                  const Color(0xFF0D9488),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          _nameCellTelemetryRow(
            Icons.memory,
            'מעבד',
            _telemetryOrDash(a.cpuUsage),
          ),
          const SizedBox(height: 3),
          _nameCellTelemetryRow(
            Icons.storage,
            'זיכרון',
            _telemetryOrDash(a.ramUsage),
          ),
          const SizedBox(height: 3),
          _nameCellTelemetryRow(
            Icons.sd_storage,
            'דיסק',
            _telemetryOrDash(a.diskFree),
          ),
          if (a.hasPendingTask) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.hourglass_empty,
                    size: 13, color: Colors.orange.shade800),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'ממתין לביצוע...',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.orange.shade900,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _nameCellTelemetryRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: Colors.grey),
        const SizedBox(width: 5),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: const TextStyle(fontSize: 11, color: Colors.black87),
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.blueGrey,
                  ),
                ),
                TextSpan(text: value),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// Peer ID for SeeDesktop sessions — the same value as heartbeat/RMM `agent_id`.
  /// [connect] strips spaces; we pass the raw ID (no display formatting).
  String _peerIdForSession(AgentInfo a) => a.agentId.trim();

  void _connectRemoteDesktop(AgentInfo a) {
    final peerId = _peerIdForSession(a);
    if (peerId.isEmpty) return;
    // Desktop: opens a Remote Desktop sub-window via connectMainDesktop (see common.dart).
    unawaited(connect(context, peerId, isTerminal: false));
  }

  Future<void> _connectLiveTerminal(AgentInfo a) async {
    if (!await hasRmmLicenseLocal()) {
      if (mounted) await showRmmProGateDialog(context);
      return;
    }
    final peerId = _peerIdForSession(a);
    if (peerId.isEmpty) return;
    clearEnvTerminalAdmin();
    // Desktop: opens a Terminal window for this peer id (rustDeskWinManager.newTerminal).
    unawaited(connect(context, peerId, isTerminal: true));
  }

  Widget _actionsCell(AgentInfo a) {
    final canQuickConnect =
        _rmmEffectiveOnline(a, _rmmRecentOnlineKeysCache) &&
            a.agentId.trim().isNotEmpty;
    final rmm = _hasRmmLicense == true;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (a.hasLastLog)
          IconButton(
            icon: const Icon(Icons.description_outlined, size: 18),
            tooltip: 'צפה בלוג אחרון',
            onPressed: () => _showLastLogDialog(a),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        IconButton(
          icon: Icon(
            Icons.desktop_windows_outlined,
            size: 18,
            color: (canQuickConnect && !_isThisDeviceRow(a))
                ? null
                : Colors.grey,
          ),
          tooltip: _isThisDeviceRow(a)
              ? translate('rmm-no-self-remote-desktop')
              : 'השתלטות מרחוק',
          onPressed: (canQuickConnect && !_isThisDeviceRow(a))
              ? () => _connectRemoteDesktop(a)
              : null,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        IconButton(
          icon: Icon(
            Icons.terminal,
            size: 18,
            color: canQuickConnect && !rmm ? Colors.grey : null,
          ),
          tooltip: rmm
              ? translate('rmm-live-terminal')
              : translate('rmm-live-terminal-pro'),
          onPressed:
              canQuickConnect ? () => unawaited(_connectLiveTerminal(a)) : null,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      );

  Widget _statusChip(String status) {
    Color color;
    switch (status.toLowerCase()) {
      case 'in_session':
        color = Colors.blueAccent;
        break;
      case 'online':
        color = const Color(0xFF16A34A);
        break;
      default:
        color = Colors.grey;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(status,
          style: TextStyle(
              fontSize: 10, color: color, fontWeight: FontWeight.w600)),
    );
  }

  String _formatLastSeenDisplay(AgentInfo a) {
    final ts = a.lastSeenUnix;
    if (ts != null && ts > 0) {
      final ms = (ts * 1000).toInt();
      final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
      return _fmtDdMmYyyyHhMm(dt);
    }
    return _fmtLastSeen(a.lastSeen);
  }

  /// `dd/MM/yyyy HH:mm` in local time (avoids extra dependency on `intl`).
  String _fmtDdMmYyyyHhMm(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final y = dt.year;
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m/$y $h:$min';
  }

  String _fmtHms(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _fmtLastSeen(String raw) {
    if (raw.isEmpty || raw == '—') return '—';
    try {
      final dt = DateTime.parse(raw).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inSeconds < 60) return 'לפני ${diff.inSeconds}ש׳';
      if (diff.inMinutes < 60) return 'לפני ${diff.inMinutes}ד׳';
      if (diff.inHours < 24) return 'לפני ${diff.inHours}ש׳';
      return 'לפני ${diff.inDays} ימים';
    } catch (_) {
      return raw;
    }
  }
}
