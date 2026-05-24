import 'package:flutter/material.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/premium_paywall_dialog.dart';
import 'package:flutter_hbb/desktop/pages/cloud_contacts_page.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/cloud_contacts_service.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';
import 'package:flutter_hbb/utils/peer_display_name_sync.dart';

TextDirection _dialogTextDirection() {
  return localeName.toLowerCase().startsWith('he')
      ? TextDirection.rtl
      : TextDirection.ltr;
}

Alignment _dialogAlignStart() {
  return _dialogTextDirection() == TextDirection.rtl
      ? Alignment.centerRight
      : Alignment.centerLeft;
}

/// Confirm or edit alias + client group(s) before upserting a cloud contact.
Future<bool?> showCloudContactAliasDialog(
  BuildContext context, {
  required String remoteId,
  String? initialAlias,
  List<String>? initialGroups,
  List<String>? knownGroupNames,
  bool isEdit = false,
  Peer? peer,
}) async {
  final dir = _dialogTextDirection();
  final alignStart = _dialogAlignStart();
  final aliasController = TextEditingController(
    text: (initialAlias ?? '').trim().isNotEmpty
        ? initialAlias!.trim()
        : remoteId.trim(),
  );
  final newGroupController = TextEditingController();

  List<String> groupSuggestions = knownGroupNames ?? [];
  if (groupSuggestions.isEmpty) {
    try {
      groupSuggestions = await CloudContactsService.fetchGroupNames();
    } catch (_) {}
  }

  final selectedGroups = <String>{
    ...?initialGroups?.map((g) => g.trim()).where((g) => g.isNotEmpty),
  };

  final title = isEdit
      ? translate('Edit Contact')
      : translate('Add to Contacts');
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: dir,
      child: StatefulBuilder(
        builder: (ctx, setDialogState) {
          void toggleGroup(String g) {
            setDialogState(() {
              if (selectedGroups.contains(g)) {
                selectedGroups.remove(g);
              } else {
                selectedGroups.add(g);
              }
            });
          }

          void addNewGroup() {
            final g = newGroupController.text.trim();
            if (g.isEmpty) return;
            setDialogState(() {
              selectedGroups.add(g);
              if (!groupSuggestions.contains(g)) {
                groupSuggestions = [...groupSuggestions, g]
                  ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
              }
              newGroupController.clear();
            });
          }

          final allChips = <String>{
            ...groupSuggestions,
            ...selectedGroups,
          }.toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      remoteId,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                      textDirection: dir,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: aliasController,
                      textDirection: dir,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: translate('Alias Name'),
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => Navigator.pop(ctx, true),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      translate('Client Group Name'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newGroupController,
                            textDirection: dir,
                            decoration: InputDecoration(
                              hintText: translate('Client Group Name hint'),
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: (_) => addNewGroup(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: translate('OK'),
                          onPressed: addNewGroup,
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                    if (allChips.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: alignStart,
                        child: Text(
                          translate('Existing groups'),
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: alignStart,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: allChips.map((g) {
                            return FilterChip(
                              label: Text(g),
                              selected: selectedGroups.contains(g),
                              onSelected: (_) => toggleGroup(g),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ],
                ),
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
          );
        },
      ),
    ),
  );
  if (saved != true || !context.mounted) {
    aliasController.dispose();
    newGroupController.dispose();
    return false;
  }
  if (!await canUseCloudContactsLocal()) {
    aliasController.dispose();
    newGroupController.dispose();
    if (context.mounted) {
      await showPremiumPaywallDialog(context);
    }
    return false;
  }
  final alias = aliasController.text.trim();
  final groups = selectedGroups.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  aliasController.dispose();
  newGroupController.dispose();
  if (alias.isEmpty) {
    showToast(translate('Name can not be empty'));
    return false;
  }
  try {
    await applyPeerDisplayNameEverywhere(
      remoteId: remoteId,
      alias: alias,
      cloudGroups: groups,
      peer: peer,
      forceCloudUpsert: true,
    );
    if (context.mounted) {
      await context
          .findAncestorStateOfType<CloudContactsPageState>()
          ?.reloadCloudContacts();
      showToast(translate('Successful'));
    }
    return true;
  } on CloudContactsException catch (e) {
    showToast(e.message);
    return false;
  } catch (_) {
    showToast(translate('Operation failed'));
    return false;
  }
}
