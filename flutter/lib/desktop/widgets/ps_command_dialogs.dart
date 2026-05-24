import 'dart:async' show unawaited;

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/utils/global_ps_catalog_admin.dart';
import 'package:flutter_hbb/utils/global_ps_catalog_store.dart';
import 'package:flutter_hbb/utils/ps_commands_catalogue.dart';

/// Resolves [cmd] to a runnable string. No UI if [cmd.params] is empty.
/// Otherwise shows a dialog for each placeholder; returns null if cancelled.
Future<String?> showPsCommandResolveDialog(BuildContext context, PsCmd cmd) async {
  if (cmd.params.isEmpty) return cmd.cmd;

  final ctrls = <String, TextEditingController>{
    for (final p in cmd.params) p: TextEditingController(),
  };

  try {
    final resolved = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(psCmdDisplayTitle(cmd)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (psCmdDisplayHint(cmd) != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      psCmdDisplayHint(cmd)!,
                      style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
                    ),
                  ),
                for (final p in cmd.params)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: ctrls[p],
                      decoration: InputDecoration(
                        labelText: '$p?',
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ביטול'),
            ),
            FilledButton(
              onPressed: () {
                final map = {
                  for (final p in cmd.params) p: ctrls[p]!.text,
                };
                if (!psCommandParamsSatisfied(cmd, map)) {
                  BotToast.showText(text: 'מלא את כל השדות');
                  return;
                }
                Navigator.pop(ctx, resolvePsCommand(cmd, map));
              },
              child: const Text('הרצה'),
            ),
          ],
        );
      },
    );
    return resolved;
  } finally {
    for (final c in ctrls.values) {
      c.dispose();
    }
  }
}

/// Searchable PowerShell catalogue (sections + commands). Used in the
/// catalog dialog and in [ScriptManagerPage].
///
/// [onBeforeCommandDialog] runs before opening the command preview (e.g. close
/// the parent [Dialog]); omit when embedded in a full page.
class PsCommandsCatalogPanel extends StatefulWidget {
  /// Context to use for [showRemotePsTerminalCommandDialog] (typically the
  /// page that stays mounted after an optional parent dialog is closed).
  final BuildContext hostContext;
  final String computerName;
  final String peerId;
  final Future<void> Function(String command) onRun;
  final VoidCallback? onBeforeCommandDialog;

  /// When true (Script Manager), show lock / add / edit / delete for the
  /// persisted global catalog (password once per app session).
  final bool enableGlobalCatalogAdmin;

  const PsCommandsCatalogPanel({
    super.key,
    required this.hostContext,
    required this.computerName,
    required this.peerId,
    required this.onRun,
    this.onBeforeCommandDialog,
    this.enableGlobalCatalogAdmin = false,
  });

  @override
  State<PsCommandsCatalogPanel> createState() => _PsCommandsCatalogPanelState();
}

class _PsCommandsCatalogPanelState extends State<PsCommandsCatalogPanel> {
  String _query = '';
  List<GlobalPsSectionEntry> _globalSections = const [];
  bool _loadingGlobal = true;

  @override
  void initState() {
    super.initState();
    unawaited(_reloadGlobal());
  }

  Future<void> _reloadGlobal() async {
    final list = await GlobalPsCatalogStore.load();
    if (!mounted) return;
    setState(() {
      _globalSections = list;
      _loadingGlobal = false;
    });
  }

  List<String> _parseParams(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<void> _promptAdminPassword() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('מצב מנהל — קטלוג גלובלי'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'סיסמה',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('אישור'),
          ),
        ],
      ),
    );
    try {
      if (ok == true && await GlobalPsCatalogAdmin.verifyPassword(ctrl.text)) {
        GlobalPsCatalogAdminSession.unlocked = true;
        if (mounted) setState(() {});
      } else if (ok == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('סיסמה שגויה')),
          );
        }
      }
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _showAddSectionDialog() async {
    final group = TextEditingController();
    final label = TextEditingController();
    final title = TextEditingController();
    final cmd = TextEditingController();
    final hint = TextEditingController();
    final params = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('קטגוריה ופקודה חדשות'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: group,
                decoration: const InputDecoration(
                  labelText: 'קטגוריה ראשית',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: label,
                decoration: const InputDecoration(
                  labelText: 'קטגוריה משנית',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: 'שם הפקודה',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: cmd,
                maxLines: 3,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'פקודת PowerShell',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: hint,
                decoration: const InputDecoration(
                  labelText: 'רמז (אופציונלי)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: params,
                decoration: const InputDecoration(
                  labelText: 'פרמטרים {TOKEN} — מופרדים בפסיק',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('שמור'),
          ),
        ],
      ),
    );
    if (ok != true) {
      group.dispose();
      label.dispose();
      title.dispose();
      cmd.dispose();
      hint.dispose();
      params.dispose();
      return;
    }
    if (group.text.trim().isEmpty ||
        label.text.trim().isEmpty ||
        title.text.trim().isEmpty ||
        cmd.text.trim().isEmpty) {
      group.dispose();
      label.dispose();
      title.dispose();
      cmd.dispose();
      hint.dispose();
      params.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('מלא קטגוריות, שם ופקודה')),
        );
      }
      return;
    }
    await GlobalPsCatalogStore.addSection(
      current: _globalSections,
      group: group.text,
      label: label.text,
      title: title.text,
      cmd: cmd.text,
      hint: hint.text,
      params: _parseParams(params.text),
    );
    group.dispose();
    label.dispose();
    title.dispose();
    cmd.dispose();
    hint.dispose();
    params.dispose();
    await _reloadGlobal();
  }

  Future<void> _showAddCommandDialog(GlobalPsSectionEntry section) async {
    final title = TextEditingController();
    final cmd = TextEditingController();
    final hint = TextEditingController();
    final params = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('הוספת פקודה לקטגוריה'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: 'שם הפקודה',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: cmd,
                maxLines: 3,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'פקודת PowerShell',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: hint,
                decoration: const InputDecoration(
                  labelText: 'רמז (אופציונלי)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: params,
                decoration: const InputDecoration(
                  labelText: 'פרמטרים — מופרדים בפסיק',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('שמור'),
          ),
        ],
      ),
    );
    if (ok != true) {
      title.dispose();
      cmd.dispose();
      hint.dispose();
      params.dispose();
      return;
    }
    if (title.text.trim().isEmpty || cmd.text.trim().isEmpty) {
      title.dispose();
      cmd.dispose();
      hint.dispose();
      params.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('מלא שם ופקודה')),
        );
      }
      return;
    }
    await GlobalPsCatalogStore.addCommandToSection(
      current: _globalSections,
      sectionId: section.id,
      title: title.text,
      cmd: cmd.text,
      hint: hint.text,
      params: _parseParams(params.text),
    );
    title.dispose();
    cmd.dispose();
    hint.dispose();
    params.dispose();
    await _reloadGlobal();
  }

  Future<void> _showEditSectionDialog(GlobalPsSectionEntry section) async {
    final group = TextEditingController(text: section.group);
    final label = TextEditingController(text: section.label);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('עריכת קטגוריות'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: group,
              decoration: const InputDecoration(
                labelText: 'קטגוריה ראשית',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: label,
              decoration: const InputDecoration(
                labelText: 'קטגוריה משנית',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('שמור'),
          ),
        ],
      ),
    );
    if (ok != true) {
      group.dispose();
      label.dispose();
      return;
    }
    await GlobalPsCatalogStore.updateSectionMeta(
      current: _globalSections,
      sectionId: section.id,
      group: group.text,
      label: label.text,
    );
    group.dispose();
    label.dispose();
    await _reloadGlobal();
  }

  Future<void> _showEditCommandDialog(
    GlobalPsSectionEntry section,
    GlobalPsCmdEntry entry,
  ) async {
    final title = TextEditingController(text: entry.title);
    final cmd = TextEditingController(text: entry.cmd);
    final hint = TextEditingController(text: entry.hint ?? '');
    final params = TextEditingController(text: entry.params.join(', '));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('עריכת פקודה'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: 'שם',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: cmd,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'פקודה',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: hint,
                decoration: const InputDecoration(
                  labelText: 'רמז',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: params,
                decoration: const InputDecoration(
                  labelText: 'פרמטרים — מופרדים בפסיק',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('שמור'),
          ),
        ],
      ),
    );
    if (ok != true) {
      title.dispose();
      cmd.dispose();
      hint.dispose();
      params.dispose();
      return;
    }
    await GlobalPsCatalogStore.updateCommand(
      current: _globalSections,
      sectionId: section.id,
      commandId: entry.id,
      title: title.text,
      cmd: cmd.text,
      hint: hint.text,
      params: _parseParams(params.text),
    );
    title.dispose();
    cmd.dispose();
    hint.dispose();
    params.dispose();
    await _reloadGlobal();
  }

  Future<void> _confirmDeleteCommand(
    GlobalPsSectionEntry section,
    GlobalPsCmdEntry entry,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('מחיקת פקודה'),
        content: Text('למחוק את "${entry.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('מחק'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await GlobalPsCatalogStore.deleteCommand(
      current: _globalSections,
      sectionId: section.id,
      commandId: entry.id,
    );
    await _reloadGlobal();
  }

  Future<void> _confirmDeleteSection(GlobalPsSectionEntry section) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('מחיקת קטגוריה'),
        content: Text(
          'למחוק את כל הפקודות ב"${section.label}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('מחק'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await GlobalPsCatalogStore.deleteSection(
      current: _globalSections,
      sectionId: section.id,
    );
    await _reloadGlobal();
  }

  void _runCmd(PsCmd cmd) {
    widget.onBeforeCommandDialog?.call();
    unawaited(showRemotePsTerminalCommandDialog(
      widget.hostContext,
      cmd: cmd,
      computerName: widget.computerName,
      agentId: widget.peerId,
      onRun: widget.onRun,
    ));
  }

  List<Widget> _buildBuiltinCatalog(ThemeData theme) {
    final sections = filterPsSections(_query, catalogue: psCatalogue);
    if (sections.isEmpty) return [];
    return [
      for (final g in groupCatalogSections(sections))
        ExpansionTile(
          key: PageStorageKey<String>('ps_panel_builtin_${g.title}'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 8),
          initiallyExpanded: true,
          title: Text(
            psSectionDisplayGroup(g.sections.first),
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          children: [
            for (final sec in g.sections) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    psSectionDisplayLabel(sec),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              for (final cmd in sec.cmds)
                ListTile(
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
                  title: Text(
                    psCmdDisplayTitle(cmd),
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: psCmdDisplayHint(cmd) != null
                      ? Text(
                          psCmdDisplayHint(cmd)!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.blueGrey,
                          ),
                        )
                      : null,
                  trailing: const Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: Colors.grey,
                  ),
                  onTap: () => _runCmd(cmd),
                ),
            ],
          ],
        ),
    ];
  }

  List<Widget> _buildGlobalCatalog(ThemeData theme) {
    final filtered =
        GlobalPsCatalogStore.filterForQuery(_globalSections, _query);
    final admin = widget.enableGlobalCatalogAdmin &&
        GlobalPsCatalogAdminSession.unlocked;

    final groupOrder = <String>[];
    final byGroup = <String, List<GlobalPsSectionEntry>>{};
    for (final s in filtered) {
      if (!byGroup.containsKey(s.group)) {
        groupOrder.add(s.group);
        byGroup[s.group] = [];
      }
      byGroup[s.group]!.add(s);
    }

    if (filtered.isEmpty && !admin) return [];

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
        child: Row(
          children: [
            Icon(Icons.public, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              'קטלוג גלובלי',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
      if (filtered.isEmpty && admin)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'אין עדיין פקודות — השתמש ב״קטגוריה חדשה״.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      for (final g in groupOrder) ...[
        ExpansionTile(
          key: PageStorageKey<String>('ps_panel_global_$g'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 8),
          initiallyExpanded: true,
          title: Text(
            psPickLocalizedBilingualField(g),
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          children: [
            for (final sec in byGroup[g]!) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          psPickLocalizedBilingualField(sec.label),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    if (admin)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, size: 18),
                        onSelected: (v) {
                          if (v == 'edit') {
                            unawaited(_showEditSectionDialog(sec));
                          } else if (v == 'add') {
                            unawaited(_showAddCommandDialog(sec));
                          } else if (v == 'del') {
                            unawaited(_confirmDeleteSection(sec));
                          }
                        },
                        itemBuilder: (ctx) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('עריכת קטגוריות'),
                          ),
                          const PopupMenuItem(
                            value: 'add',
                            child: Text('הוספת פקודה'),
                          ),
                          const PopupMenuItem(
                            value: 'del',
                            child: Text('מחיקת קטגוריה'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              for (final ge in sec.cmds)
                ListTile(
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  title: Text(
                    psPickLocalizedBilingualField(ge.title),
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: (ge.hint != null && ge.hint!.trim().isNotEmpty)
                      ? Text(
                          psPickLocalizedBilingualField(ge.hint!),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.blueGrey,
                          ),
                        )
                      : null,
                  trailing: admin
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () =>
                                  unawaited(_showEditCommandDialog(sec, ge)),
                            ),
                            IconButton(
                              icon:
                                  const Icon(Icons.delete_outline, size: 18),
                              onPressed: () =>
                                  unawaited(_confirmDeleteCommand(sec, ge)),
                            ),
                          ],
                        )
                      : const Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Colors.grey,
                        ),
                  onTap: () => _runCmd(ge.toPsCmd()),
                ),
            ],
          ],
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[
      ..._buildBuiltinCatalog(theme),
      ..._buildGlobalCatalog(theme),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.enableGlobalCatalogAdmin)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: [
                IconButton(
                  tooltip: GlobalPsCatalogAdminSession.unlocked
                      ? 'מצב מנהל פעיל'
                      : 'הזנת סיסמת מנהל',
                  icon: Icon(
                    GlobalPsCatalogAdminSession.unlocked
                        ? Icons.lock_open
                        : Icons.lock_outline,
                  ),
                  onPressed: () async {
                    if (GlobalPsCatalogAdminSession.unlocked) {
                      setState(() => GlobalPsCatalogAdminSession.unlocked =
                          false);
                    } else {
                      await _promptAdminPassword();
                    }
                  },
                ),
                if (GlobalPsCatalogAdminSession.unlocked) ...[
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                    label: const Text('קטגוריה חדשה'),
                    onPressed: () => unawaited(_showAddSectionDialog()),
                  ),
                ],
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'חפש פקודה...',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        Expanded(
          child: _loadingGlobal
              ? const Center(child: CircularProgressIndicator())
              : children.isEmpty
                  ? const Center(
                      child: Text(
                        'לא נמצאו פקודות',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView(
                      children: children,
                    ),
        ),
      ],
    );
  }
}

/// Picker for the PowerShell catalogue (search + sections), then
/// [showRemotePsTerminalCommandDialog] and [onRun] with the final command.
Future<void> showPsCommandsCatalogDialog(
  BuildContext context, {
  required String computerName,
  required String peerId,
  required Future<void> Function(String command) onRun,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return Dialog(
        child: SizedBox(
          width: 640,
          height: 540,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          color: Theme.of(ctx).dividerColor, width: 1)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.terminal, size: 18, color: Colors.blueGrey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'פקודות PowerShell — $computerName',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.pop(ctx),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PsCommandsCatalogPanel(
                  hostContext: context,
                  computerName: computerName,
                  peerId: peerId,
                  onBeforeCommandDialog: () => Navigator.pop(ctx),
                  onRun: onRun,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Dialog for Admin UI: optional param fields, editable preview, then [onRun].
Future<void> showRemotePsTerminalCommandDialog(
  BuildContext context, {
  required PsCmd cmd,
  required String computerName,
  required String agentId,
  required Future<void> Function(String command) onRun,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _RemotePsTerminalDialog(
      cmd: cmd,
      computerName: computerName,
      agentId: agentId,
      onRun: onRun,
    ),
  );
}

class _RemotePsTerminalDialog extends StatefulWidget {
  final PsCmd cmd;
  final String computerName;
  final String agentId;
  final Future<void> Function(String command) onRun;

  const _RemotePsTerminalDialog({
    required this.cmd,
    required this.computerName,
    required this.agentId,
    required this.onRun,
  });

  @override
  State<_RemotePsTerminalDialog> createState() => _RemotePsTerminalDialogState();
}

class _RemotePsTerminalDialogState extends State<_RemotePsTerminalDialog> {
  late final TextEditingController _preview;
  late final Map<String, TextEditingController> _paramCtrls;

  @override
  void initState() {
    super.initState();
    _paramCtrls = {
      for (final p in widget.cmd.params) p: TextEditingController(),
    };
    _preview = TextEditingController(text: widget.cmd.cmd);
    for (final c in _paramCtrls.values) {
      c.addListener(_syncPreview);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPreview());
  }

  void _syncPreview() {
    if (widget.cmd.params.isEmpty) return;
    final map = {for (final p in widget.cmd.params) p: _paramCtrls[p]!.text};
    _preview.text = resolvePsCommand(widget.cmd, map);
  }

  @override
  void dispose() {
    for (final c in _paramCtrls.values) {
      c.removeListener(_syncPreview);
      c.dispose();
    }
    _preview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cmd = widget.cmd;
    return AlertDialog(
      title: Text(psCmdDisplayTitle(cmd)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (psCmdDisplayHint(cmd) != null) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.blueGrey.withOpacity(0.25)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('💡 ', style: TextStyle(fontSize: 13)),
                    Expanded(
                      child: Text(
                        psCmdDisplayHint(cmd)!,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.blueGrey),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (cmd.params.isNotEmpty) ...[
              const Text(
                'מלא פרמטרים (אופציונלי לעריכה בשדה למטה):',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 6),
              for (final p in cmd.params)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _paramCtrls[p],
                    decoration: InputDecoration(
                      labelText: '$p?',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              const SizedBox(height: 4),
            ],
            Text(
              cmd.params.isEmpty
                  ? 'ערוך את הפקודה — לאחר אישור ייפתח טרמינל וההרצה תתחיל:'
                  : 'עריכת הפקודה הסופית לפני הרצה:',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _preview,
              maxLines: 8,
              minLines: 3,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                filled: true,
                contentPadding: EdgeInsets.all(10),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.computer, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  'מחשב יעד: ${widget.computerName}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(width: 8),
                Text(
                  'ID: ${widget.agentId}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('ביטול'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.terminal, size: 16),
          label: const Text('פתח טרמינל והפעל'),
          onPressed: () async {
            final finalCmd = _preview.text.trim();
            if (finalCmd.isEmpty) return;
            if (cmd.params.isNotEmpty) {
              final map = {for (final p in cmd.params) p: _paramCtrls[p]!.text};
              if (!psCommandParamsSatisfied(cmd, map)) {
                BotToast.showText(text: 'מלא את כל השדות');
                return;
              }
            }
            Navigator.pop(context);
            await widget.onRun(finalCmd);
          },
        ),
      ],
    );
  }
}
