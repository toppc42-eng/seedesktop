import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/rmm_pro_gate_dialog.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/desktop/widgets/ps_command_dialogs.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/agent_heartbeat_manager.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';
import 'package:flutter_hbb/utils/license_manager.dart';
import 'package:flutter_hbb/utils/ps_commands_catalogue.dart';
import 'package:flutter_hbb/utils/rmm_custom_scripts_store.dart';
/// Pro-only: PowerShell catalogue, admin tasks (Chkdsk/MemTest), and CRUD for
/// custom scripts — target device is chosen here (not from My Devices ⋮).
class ScriptManagerPage extends StatefulWidget {
  const ScriptManagerPage({super.key});

  @override
  State<ScriptManagerPage> createState() => _ScriptManagerPageState();
}

class _ScriptManagerPageState extends State<ScriptManagerPage>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late final TabController _tabController;

  List<AgentInfo> _remoteAgents = [];
  AgentInfo? _localMyDeviceRow;
  AgentInfo? _selectedAgent;
  bool _loading = false;
  String? _error;
  bool? _hasRmmLicense;
  List<RmmCustomScript> _customScripts = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    gFFI.recentPeersModel.addListener(_onPeersChanged);
    gFFI.favoritePeersModel.addListener(_onPeersChanged);
    gFFI.lanPeersModel.addListener(_onPeersChanged);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _tabController.dispose();
    gFFI.recentPeersModel.removeListener(_onPeersChanged);
    gFFI.favoritePeersModel.removeListener(_onPeersChanged);
    gFFI.lanPeersModel.removeListener(_onPeersChanged);
    super.dispose();
  }

  void _onPeersChanged() {
    if (!mounted) return;
    setState(_sortRemotesByOnline);
  }

  Future<void> _bootstrap() async {
    await _updateRmmLicense();
    if (!mounted) return;
    if (_hasRmmLicense == true) {
      await Future.wait([_fetch(), _reloadCustomScripts()]);
    }
  }

  Future<void> _updateRmmLicense() async {
    final v = await hasRmmLicenseLocal();
    if (mounted) setState(() => _hasRmmLicense = v);
  }

  Future<void> _reloadCustomScripts() async {
    final list = await RmmCustomScriptsStore.load();
    if (mounted) setState(() => _customScripts = list);
  }

  static void _addRmmMatchingKeys(Set<String> set, String rawPeerId) {
    final s = normalizeSeeDesktopId(rawPeerId);
    if (s.isNotEmpty) set.add(s);
    final n = normalizePeerIdForLicenseTracking(rawPeerId);
    if (n.isNotEmpty) set.add(n);
  }

  Set<String> _recentOnlineNormalizedKeys() {
    final set = <String>{};
    void absorb(Peers model) {
      for (final p in model.peers) {
        if (!p.online) continue;
        _addRmmMatchingKeys(set, p.id);
      }
    }

    absorb(gFFI.recentPeersModel);
    absorb(gFFI.favoritePeersModel);
    absorb(gFFI.lanPeersModel);
    return set;
  }

  bool _inRecentOnlineSet(AgentInfo a, Set<String> keys) {
    final k1 = normalizeSeeDesktopId(a.agentId);
    final k2 = normalizePeerIdForLicenseTracking(a.agentId);
    return (k1.isNotEmpty && keys.contains(k1)) ||
        (k2.isNotEmpty && keys.contains(k2));
  }

  bool _rmmEffectiveOnline(AgentInfo a, Set<String> recentOnlineKeys) {
    if (_inRecentOnlineSet(a, recentOnlineKeys)) return true;
    if (a.isOnline) return true;
    final st = a.status.toLowerCase().trim();
    return st == 'online' || st == 'in_session';
  }

  void _sortRemotesByOnline() {
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

      if (!mounted) return;
      AgentInfo? sel = _selectedAgent;
      final merged = _mergeAgentsForDropdown(localRow, remotes);
      if (merged.isEmpty) {
        sel = null;
      } else if (sel == null ||
          !merged.any((x) => x.agentId.trim() == sel!.agentId.trim())) {
        sel = merged.first;
      }

      setState(() {
        _remoteAgents = remotes;
        _localMyDeviceRow = localRow;
        _loading = false;
        _selectedAgent = sel;
      });
      unawaited(_updateRmmLicense());
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

  List<AgentInfo> _mergeAgentsForDropdown(
      AgentInfo? local, List<AgentInfo> remotes) {
    if (local == null) return List<AgentInfo>.from(remotes);
    return [local, ...remotes];
  }

  Future<void> _openTerminalWithPsCommand(AgentInfo agent) async {
    if (!await hasRmmLicenseLocal()) {
      if (mounted) await showRmmProGateDialog(context);
      return;
    }
    final peerId = agent.agentId.trim();
    if (peerId.isEmpty) return;
    if (!_rmmEffectiveOnline(agent, _recentOnlineNormalizedKeys())) {
      BotToast.showText(text: translate('script-manager-offline'));
      return;
    }
    try {
      if (!mounted) return;
      clearEnvTerminalAdmin();
      unawaited(connect(context, peerId, isTerminal: true));
    } catch (e) {
      if (mounted) BotToast.showText(text: '$e');
    }
  }

  Future<void> _onAdminTaskSelected(AgentInfo a, String taskName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(translate('Confirmation')),
        content: Text(translate('script-manager-admin-confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(translate('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(translate('OK')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await setAgentTaskRemote(agentId: a.agentId, taskName: taskName);
      if (!mounted) return;
      BotToast.showText(text: translate('script-manager-task-sent'));
      await _fetch();
    } catch (e) {
      if (mounted) BotToast.showText(text: '$e');
    }
  }

  Future<void> _showEditScriptDialog({RmmCustomScript? existing}) async {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final bodyCtrl = TextEditingController(text: existing?.body ?? '');
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(existing == null
              ? translate('script-manager-add-script')
              : translate('script-manager-edit-script')),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: InputDecoration(
                    labelText: translate('script-manager-script-title'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bodyCtrl,
                  minLines: 6,
                  maxLines: 16,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    labelText: translate('script-manager-script-body'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(translate('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(translate('OK')),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final t = titleCtrl.text.trim();
      final b = bodyCtrl.text;
      if (t.isEmpty || b.trim().isEmpty) {
        BotToast.showText(text: translate('script-manager-fill-both'));
        return;
      }
      if (existing == null) {
        await RmmCustomScriptsStore.add(t, b);
      } else {
        await RmmCustomScriptsStore.update(RmmCustomScript(
          id: existing.id,
          title: t,
          body: b,
          createdAtMs: existing.createdAtMs,
          updatedAtMs: existing.updatedAtMs,
        ));
      }
      await _reloadCustomScripts();
    } finally {
      titleCtrl.dispose();
      bodyCtrl.dispose();
    }
  }

  Future<void> _confirmDelete(RmmCustomScript s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(translate('Confirm Delete')),
        content: Text('${translate('Delete')} "${s.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(translate('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(translate('OK')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await RmmCustomScriptsStore.deleteById(s.id);
      await _reloadCustomScripts();
    }
  }

  void _runCustomScript(RmmCustomScript s) {
    final a = _selectedAgent;
    if (a == null) return;
    unawaited(showRemotePsTerminalCommandDialog(
      context,
      cmd: PsCmd(s.title, s.body.trim(), hint: translate('script-manager-custom')),
      computerName: a.computerName,
      agentId: a.agentId.trim(),
      onRun: (_) => _openTerminalWithPsCommand(a),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_hasRmmLicense != true) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(translate('rmm-pro-gate-body'),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  await _updateRmmLicense();
                  if (_hasRmmLicense == true) await _fetch();
                  setState(() {});
                },
                child: Text(translate('Refresh')),
              ),
            ],
          ),
        ),
      );
    }

    if (_loading && _remoteAgents.isEmpty && _localMyDeviceRow == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null &&
        _remoteAgents.isEmpty &&
        _localMyDeviceRow == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _fetch,
                child: Text(translate('Refresh')),
              ),
            ],
          ),
        ),
      );
    }

    final merged = _mergeAgentsForDropdown(_localMyDeviceRow, _remoteAgents);
    final agent = _selectedAgent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  translate('script-manager-subtitle'),
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: translate('Refresh'),
                onPressed: _loading ? null : _fetch,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: translate('script-manager-target-device'),
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<AgentInfo>(
                isExpanded: true,
                value: agent != null &&
                        merged.any((x) =>
                            x.agentId.trim() == agent.agentId.trim())
                    ? agent
                    : null,
                hint: Text(translate('script-manager-no-device')),
                items: [
                  for (final a in merged)
                    DropdownMenuItem(
                      value: a,
                      child: Text(
                        a.computerName.isNotEmpty
                            ? a.computerName
                            : a.agentId,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _selectedAgent = v),
              ),
            ),
          ),
        ),
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            controller: _tabController,
            tabs: [
              Tab(text: translate('script-manager-tab-catalog')),
              Tab(text: translate('script-manager-tab-admin')),
              Tab(text: translate('script-manager-tab-custom')),
            ],
          ),
        ),
        Expanded(
          child: agent == null
              ? Center(child: Text(translate('script-manager-no-device')))
              : TabBarView(
                  controller: _tabController,
                  children: [
                    PsCommandsCatalogPanel(
                      key: ValueKey('ps_cat_${agent.agentId}'),
                      hostContext: context,
                      computerName: agent.computerName,
                      peerId: agent.agentId.trim(),
                      enableGlobalCatalogAdmin: true,
                      onRun: (_) => _openTerminalWithPsCommand(agent),
                    ),
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text(
                          translate('script-manager-admin-hint'),
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          icon: const Icon(Icons.storage_outlined),
                          label: Text(translate('script-manager-chkdsk')),
                          onPressed: () =>
                              _onAdminTaskSelected(agent, 'chkdsk'),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          icon: const Icon(Icons.memory_outlined),
                          label: Text(translate('script-manager-memtest')),
                          onPressed: () =>
                              _onAdminTaskSelected(agent, 'memtest'),
                        ),
                      ],
                    ),
                    _customScriptsTab(),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _customScriptsTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: Text(translate('script-manager-add-script')),
                onPressed: () => unawaited(_showEditScriptDialog()),
              ),
            ],
          ),
        ),
        Expanded(
          child: _customScripts.isEmpty
              ? Center(child: Text(translate('script-manager-no-custom')))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _customScripts.length,
                  itemBuilder: (ctx, i) {
                    final s = _customScripts[i];
                    return Card(
                      child: ListTile(
                        title: Text(s.title),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.play_arrow),
                              tooltip: translate('script-manager-tooltip-run'),
                              onPressed: () => _runCustomScript(s),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: translate('script-manager-tooltip-edit'),
                              onPressed: () =>
                                  unawaited(_showEditScriptDialog(existing: s)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: translate('script-manager-tooltip-delete'),
                              onPressed: () => unawaited(_confirmDelete(s)),
                            ),
                          ],
                        ),
                        onTap: () => _runCustomScript(s),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
