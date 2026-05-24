import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/user_model.dart';

import 'cloud_backup.dart';

/// Prefer Sync Account email from Settings, then account API email (same GCS folder logic).
String? resolveCloudBackupEmail() {
  final cloud = bind.mainGetLocalOption(key: 'cloud_sync_email').trim();
  if (cloud.isNotEmpty) return cloud;
  final info = UserModel.getLocalUserInfo();
  if (info == null) return null;
  final e = info['email'];
  if (e is String && e.trim().isNotEmpty) return e.trim();
  return null;
}

/// Stops SeeDesktop via [backup.bat], uploads, then restarts the app. Exits this process after launch.
Future<void> runCloudBackupWithFeedback(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final email = resolveCloudBackupEmail();
  if (email == null || email.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'נדרש אימייל: התחבר ל-Sync Account בהגדרות > Account או התחבר לחשבון.',
        ),
      ),
    );
    return;
  }

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('גיבוי לענן'),
      content: const Text(
        'SeeDesktop תיסגר לרגע כדי לשחרר קבצים נעולים (יומנים וכו\'), '
        'ייווצר גיבוי ויועלה לענן, ואז התוכנה תופעל מחדש.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('ביטול'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('המשך'),
        ),
      ],
    ),
  );

  if (go != true || !context.mounted) return;

  try {
    final api = await bind.mainGetApiServer();
    await startCloudBackupDetached(email, api);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(0);
  } catch (e) {
    if (context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}

/// Pick a backup by date/label, confirm, then restore (restarts app).
Future<void> showCloudRestoreDialog(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final email = resolveCloudBackupEmail();
  if (email == null || email.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'נדרש אימייל: התחבר ל-Sync Account בהגדרות > Account או התחבר לחשבון.',
        ),
      ),
    );
    return;
  }

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(child: Text('טוען רשימת גיבויים…')),
        ],
      ),
    ),
  );

  List<Map<String, dynamic>> list;
  try {
    final api = await bind.mainGetApiServer();
    list = await listCloudBackups(email, api);
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
    return;
  }

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();

  if (list.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('אין גיבויים בענן עדיין.')),
    );
    return;
  }

  final stamp = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('שחזור מענן'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: list.map((b) {
            final s = (b['stamp'] ?? '').toString();
            final label = (b['label'] ?? s).toString();
            return ListTile(
              title: Text(label),
              onTap: () => Navigator.pop(ctx, s),
            );
          }).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('ביטול'),
        ),
      ],
    ),
  );

  if (stamp == null || stamp.isEmpty || !context.mounted) return;

  final label = list.firstWhere(
    (b) => (b['stamp'] ?? '').toString() == stamp,
    orElse: () => {'label': stamp},
  );
  final labelText = (label['label'] ?? stamp).toString();

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('אישור שחזור'),
      content: Text(
        'להחליף את כל הנתונים ב־%APPDATA%\\SeeDesktop בגיבוי מ־\n$labelText\n'
        'התוכנה תופעל מחדש.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('ביטול'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('שחזור'),
        ),
      ],
    ),
  );

  if (ok != true || !context.mounted) return;

  try {
    final api = await bind.mainGetApiServer();
    await runCloudRestoreBat(email, stamp, api);
  } catch (e) {
    if (context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}
