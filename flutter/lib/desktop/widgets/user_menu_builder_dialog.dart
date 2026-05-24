import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/utils/admin_settings_service.dart';
import 'package:flutter_hbb/utils/user_menu_layout_model.dart';
import 'package:flutter_hbb/utils/user_menu_layout_store.dart';

class _ActionRow {
  final TextEditingController name;
  final TextEditingController path;

  _ActionRow({String nameText = '', String pathText = ''})
      : name = TextEditingController(text: nameText),
        path = TextEditingController(text: pathText);

  void dispose() {
    name.dispose();
    path.dispose();
  }
}

class _CategoryBlock {
  final TextEditingController title;
  final List<_ActionRow> actions;

  _CategoryBlock({String titleText = '', List<_ActionRow>? actions})
      : title = TextEditingController(text: titleText),
        actions = actions ?? [];

  void dispose() {
    title.dispose();
    for (final a in actions) {
      a.dispose();
    }
  }
}

/// Admin UI: accordion-style categories with action items (name + executable path).
Future<void> showUserMenuBuilderDialog(
  BuildContext context, {
  required String password,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _UserMenuBuilderDialog(password: password),
  );
}

class _UserMenuBuilderDialog extends StatefulWidget {
  final String password;

  const _UserMenuBuilderDialog({required this.password});

  @override
  State<_UserMenuBuilderDialog> createState() => _UserMenuBuilderDialogState();
}

class _UserMenuBuilderDialogState extends State<_UserMenuBuilderDialog> {
  final List<_CategoryBlock> _blocks = [];
  bool _loading = true;
  bool _saving = false;
  String? _status;
  bool _lastCloudOk = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final doc = await UserMenuLayoutStore.load();
    if (!mounted) return;
    for (final c in doc.categories) {
      final rows = <_ActionRow>[
        for (final a in c.actions)
          _ActionRow(nameText: a.buttonName, pathText: a.executionPath),
      ];
      _blocks.add(_CategoryBlock(
        titleText: c.title,
        actions: rows,
      ));
    }
    setState(() {
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final b in _blocks) {
      b.dispose();
    }
    super.dispose();
  }

  void _addCategory() {
    setState(() {
      _blocks.add(_CategoryBlock());
    });
  }

  void _removeCategory(int i) {
    setState(() {
      _blocks[i].dispose();
      _blocks.removeAt(i);
    });
  }

  void _addAction(int catIndex) {
    setState(() {
      _blocks[catIndex].actions.add(_ActionRow());
    });
  }

  void _removeAction(int catIndex, int actIndex) {
    setState(() {
      final row = _blocks[catIndex].actions.removeAt(actIndex);
      row.dispose();
    });
  }

  UserMenuLayoutDocument _documentFromState() {
    final cats = <UserMenuCategory>[];
    for (final b in _blocks) {
      final items = <UserMenuActionItem>[];
      for (final a in b.actions) {
        items.add(UserMenuActionItem(
          buttonName: a.name.text.trim(),
          executionPath: a.path.text.trim(),
        ));
      }
      cats.add(UserMenuCategory(
        title: b.title.text.trim(),
        actions: items,
      ));
    }
    return UserMenuLayoutDocument(categories: cats);
  }

  Future<void> _saveLocal() async {
    await UserMenuLayoutStore.save(_documentFromState());
  }

  Future<void> _saveCloud() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    final doc = _documentFromState();
    await _saveLocal();
    final ok = await AdminSettingsService.saveUserMenuLayoutMap(
      doc.toJson(),
      password: widget.password,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _lastCloudOk = ok;
      _status = ok
          ? translate('user-menu-builder-saved-cloud')
          : translate('user-menu-builder-save-failed')
              .replaceFirst('{}', AdminSettingsService.lastSyncError);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(translate('user-menu-builder-title')),
      content: SizedBox(
        width: 640,
        height: 480,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    translate('user-menu-builder-intro'),
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _addCategory,
                    icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                    label: Text(translate('user-menu-builder-add-category')),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _blocks.length,
                      itemBuilder: (ctx, i) {
                        final block = _blocks[i];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ExpansionTile(
                            key: PageStorageKey('um_cat_$i'),
                            initiallyExpanded: true,
                            title: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: block.title,
                                    decoration: InputDecoration(
                                      labelText: translate(
                                          'user-menu-builder-category-name'),
                                      isDense: true,
                                      border: const OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: translate('Delete'),
                                  onPressed: () => _removeCategory(i),
                                ),
                              ],
                            ),
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 0, 12, 8),
                                child: Column(
                                  children: [
                                    for (int j = 0;
                                        j < block.actions.length;
                                        j++)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 8),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              flex: 2,
                                              child: TextField(
                                                controller:
                                                    block.actions[j].name,
                                                decoration: InputDecoration(
                                                  labelText: translate(
                                                      'user-menu-builder-button-name'),
                                                  isDense: true,
                                                  border:
                                                      const OutlineInputBorder(),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              flex: 3,
                                              child: TextField(
                                                controller:
                                                    block.actions[j].path,
                                                decoration: InputDecoration(
                                                  labelText: translate(
                                                      'user-menu-builder-exec-path'),
                                                  isDense: true,
                                                  border:
                                                      const OutlineInputBorder(),
                                                ),
                                                style: const TextStyle(
                                                  fontFamily: 'monospace',
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                  Icons.remove_circle_outline),
                                              onPressed: () =>
                                                  _removeAction(i, j),
                                            ),
                                          ],
                                        ),
                                      ),
                                    Align(
                                      alignment:
                                          AlignmentDirectional.centerStart,
                                      child: TextButton.icon(
                                        onPressed: () => _addAction(i),
                                        icon: const Icon(Icons.add, size: 18),
                                        label: Text(translate(
                                            'user-menu-builder-add-action')),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  if (_status != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _status!,
                        style: TextStyle(
                          fontSize: 12,
                          color: _lastCloudOk ? Colors.green : Colors.orange,
                        ),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(translate('Cancel')),
        ),
        TextButton(
          onPressed: _saving || _loading
              ? null
              : () async {
                  await _saveLocal();
                  if (mounted) {
                    setState(() {
                      _lastCloudOk = true;
                      _status = translate('user-menu-builder-saved-local');
                    });
                  }
                },
          child: Text(translate('user-menu-builder-save-local')),
        ),
        FilledButton(
          onPressed: _saving || _loading ? null : _saveCloud,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(translate('user-menu-builder-save-layout')),
        ),
      ],
    );
  }
}
