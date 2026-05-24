import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart' show MyTheme, translate;
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:get/get.dart';

import 'package:flutter_hbb/utils/cloud_sync_service.dart';
import 'package:flutter_hbb/utils/license_manager.dart';
import 'package:flutter_hbb/utils/secure_transfer_contacts.dart';
import 'package:flutter_hbb/utils/secure_transfer_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

/// Fallback if translation key is empty.
const String kDefaultSecureTransferMessageBody =
    "Hi, I've sent you a secure file via SeeDesktop...";

/// Secure Transfer: init → upload (progress) → complete; cloud history + local contacts.
class SecureTransferPage extends StatefulWidget {
  const SecureTransferPage({super.key});

  @override
  State<SecureTransferPage> createState() => _SecureTransferPageState();
}

class _SecureTransferPageState extends State<SecureTransferPage> {
  final _recipientNameCtrl = TextEditingController();
  final _recipientEmailCtrl = TextEditingController();
  final _messageBodyCtrl = TextEditingController();

  final _service = SecureTransferService();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  String? _filePath;
  String? _pickedFileName;

  bool _busy = false;
  double? _uploadProgress;

  List<SecureTransferHistoryItem> _history = <SecureTransferHistoryItem>[];
  bool _historyLoading = false;
  String? _historyError;

  List<SecureTransferContact> _contacts = <SecureTransferContact>[];

  /// `null` until the first access gate check finishes.
  bool? _gateReady;
  bool _isWordPressLoggedIn = false;
  int? _jumboCredits;
  bool _jumboCreditsLoading = false;

  Worker? _authWorker;

  @override
  void initState() {
    super.initState();
    final dm = translate('sd-transfer-default-message').trim();
    _messageBodyCtrl.text =
        dm.isNotEmpty ? dm : kDefaultSecureTransferMessageBody;
    _authWorker = ever(CloudSyncService.authRevision, (_) {
      unawaited(_bootstrap());
    });
    unawaited(_bootstrap());
  }

  bool _isWordPressAccountConnected() {
    if (!CloudSyncService.hasToken) return false;
    return _validEmail(CloudSyncService.savedEmail.trim());
  }

  /// Logged-in WordPress / cloud account email (Settings → Account OTP).
  String? _wordPressSenderEmail() {
    if (!_isWordPressAccountConnected()) return null;
    return CloudSyncService.savedEmail.trim();
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    setState(() {
      _gateReady = false;
      _isWordPressLoggedIn = _isWordPressAccountConnected();
      _jumboCredits = null;
    });

    if (!_isWordPressLoggedIn) {
      if (mounted) setState(() => _gateReady = true);
      return;
    }

    setState(() => _jumboCreditsLoading = true);
    final email = _wordPressSenderEmail()!;
    final result = await fetchJumboCreditsBalance(userEmail: email);
    if (!mounted) return;
    setState(() {
      _jumboCreditsLoading = false;
      _jumboCredits = result.success ? result.balance : 0;
      _gateReady = true;
    });

    if (result.success && result.balance > 0) {
      await _loadContacts();
      await _loadCloudHistory();
    }
  }

  Future<void> _refreshJumboCredits() async {
    final email = _wordPressSenderEmail();
    if (email == null) return;
    if (!mounted) return;
    setState(() => _jumboCreditsLoading = true);
    final result = await fetchJumboCreditsBalance(userEmail: email);
    if (!mounted) return;
    setState(() {
      _jumboCreditsLoading = false;
      if (result.success) {
        _jumboCredits = result.balance;
      }
    });
  }

  Future<bool> _ensureJumboCreditsAvailable() async {
    final email = _wordPressSenderEmail();
    if (email == null) {
      await _showLoginRequiredDialog();
      return false;
    }
    final result = await fetchJumboCreditsBalance(userEmail: email);
    if (!mounted) return false;
    if (!result.success) {
      _snack(translate('sd-transfer-credits-fetch-failed'), error: true);
      return false;
    }
    setState(() => _jumboCredits = result.balance);
    if (result.balance <= 0) {
      await _showOutOfCreditsDialog();
      return false;
    }
    return true;
  }

  void _openAccountLogin() {
    DesktopSettingPage.switch2page(SettingsTabKey.account);
  }

  Future<void> _openBuyCreditsPage() async {
    final uri = Uri.parse(kJumboBuyCreditsUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _showLoginRequiredDialog() async {
    await _showAccessDialog(
      icon: Icons.lock_outline_rounded,
      bodyKey: 'sd-transfer-login-required-body',
      actionLabelKey: 'sd-transfer-login-required-button',
      onAction: _openAccountLogin,
    );
  }

  Future<void> _showOutOfCreditsDialog() async {
    await _showAccessDialog(
      icon: Icons.inventory_2_outlined,
      bodyKey: 'sd-transfer-credits-empty-body',
      actionLabelKey: 'sd-transfer-buy-credits',
      onAction: _openBuyCreditsPage,
    );
  }

  Future<void> _showAccessDialog({
    required IconData icon,
    required String bodyKey,
    required String actionLabelKey,
    required VoidCallback onAction,
  }) async {
    final cs = Theme.of(context).colorScheme;
    final accent = MyTheme.accent;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          contentPadding: const EdgeInsets.fromLTRB(28, 28, 28, 12),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(icon, size: 38, color: accent),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    translate(bodyKey),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(translate('admin-close')),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                onAction();
              },
              child: Text(translate(actionLabelKey)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _consumeCreditAfterSuccessfulSend() async {
    final email = _wordPressSenderEmail();
    if (email == null) return;
    final consumed = await consumeJumboCreditOnServer(userEmail: email);
    if (!mounted) return;
    if (consumed.success) {
      setState(() => _jumboCredits = consumed.balance);
    }
  }

  @override
  void dispose() {
    _authWorker?.dispose();
    _recipientNameCtrl.dispose();
    _recipientEmailCtrl.dispose();
    _messageBodyCtrl.dispose();
    super.dispose();
  }

  /// Sender for transfer APIs — WordPress cloud account email only.
  String? _senderEmailFromProfile() => _wordPressSenderEmail();

  Future<void> _loadContacts() async {
    final local = await loadSecureTransferContacts();
    if (!mounted) return;
    setState(() => _contacts = local);
    final sender = _senderEmailFromProfile();
    if (sender == null || !_validEmail(sender)) return;
    try {
      final remote = await _service.fetchContacts(email: sender);
      final merged = mergeSecureTransferContacts(local, remote);
      await saveSecureTransferContacts(merged);
      await _service.syncContacts(senderEmail: sender, contacts: merged);
      if (mounted) setState(() => _contacts = merged);
    } catch (_) {
      // Keep local list already shown.
    }
  }

  Future<void> _pushContactsToCloud(List<SecureTransferContact> list) async {
    final sender = _senderEmailFromProfile();
    if (sender == null || !_validEmail(sender)) return;
    try {
      await _service.syncContacts(senderEmail: sender, contacts: list);
    } catch (_) {}
  }

  /// Add/update recipient in the phone book and sync to WordPress.
  Future<void> _upsertContactAfterSend(String name, String email) async {
    final next = List<SecureTransferContact>.from(_contacts);
    final ix =
        next.indexWhere((c) => c.email.toLowerCase() == email.toLowerCase());
    final contact = SecureTransferContact(
      id: ix >= 0 ? next[ix].id : Uuid().v4(),
      fullName: name,
      email: email,
      phone: ix >= 0 ? next[ix].phone : '',
      notes: ix >= 0 ? next[ix].notes : '',
    );
    if (ix >= 0) {
      next[ix] = contact;
    } else {
      next.add(contact);
    }
    next.sort(
        (a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
    await _saveContacts(next);
  }

  Future<void> _loadCloudHistory() async {
    final email = _senderEmailFromProfile();
    if (email == null) {
      if (mounted) {
        setState(() {
          _history = [];
          _historyError = null;
          _historyLoading = false;
        });
      }
      return;
    }
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final list = await _service.fetchHistory(email: email);
      if (mounted) {
        setState(() {
          _history = list;
          _historyLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _historyLoading = false;
          _historyError = e.toString();
        });
      }
    }
  }

  Future<void> _saveContacts(List<SecureTransferContact> list) async {
    await saveSecureTransferContacts(list);
    if (mounted) setState(() => _contacts = list);
    await _pushContactsToCloud(list);
  }

  void _snack(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          text,
          textDirection: TextDirection.rtl,
        ),
        backgroundColor: error ? Colors.red.shade800 : null,
      ),
    );
  }

  bool _validEmail(String v) {
    final t = v.trim();
    if (t.isEmpty) return false;
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t);
  }

  void _applyContact(SecureTransferContact c) {
    setState(() {
      _recipientNameCtrl.text = c.fullName;
      _recipientEmailCtrl.text = c.email;
    });
  }

  Future<void> _pickContactQuick() async {
    if (_contacts.isEmpty) {
      _snack(translate('sd-transfer-contacts-empty'));
      return;
    }
    final picked = await showModalBottomSheet<SecureTransferContact>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: _contacts
              .map(
                (c) => ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(c.fullName.isNotEmpty ? c.fullName : c.email),
                  subtitle: Text(c.email),
                  trailing: IconButton(
                    icon: const Icon(Icons.share),
                    tooltip: translate('sd-transfer-contact-share'),
                    onPressed: () => Navigator.pop(ctx, c),
                  ),
                  onTap: () => Navigator.pop(ctx, c),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (picked != null) _applyContact(picked);
  }

  Future<void> _copyLink(String? url) async {
    if (url == null || url.trim().isEmpty) {
      _snack(translate('sd-transfer-no-link'), error: true);
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) _snack(translate('sd-transfer-link-copied'));
  }

  /// Pre-fill recipient + message from a history row; user picks a new file and sends.
  void _repeatSendFromHistory(SecureTransferHistoryItem e) {
    if (_busy) return;
    setState(() {
      _recipientNameCtrl.text = e.recipientName;
      _recipientEmailCtrl.text = e.recipientEmail;
      if (e.message.trim().isNotEmpty) {
        _messageBodyCtrl.text = e.message;
      }
      _filePath = null;
      _pickedFileName = null;
    });
    _snack(translate('sd-transfer-repeat-filled'));
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    if (!_isWordPressAccountConnected()) {
      await _showLoginRequiredDialog();
      return;
    }
    if (!await _ensureJumboCreditsAvailable()) return;
    try {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withReadStream: false,
      );
      if (r == null || r.files.isEmpty) return;
      final f = r.files.single;
      final path = f.path;
      if (path == null || path.isEmpty) {
        _snack(translate('sd-transfer-pick-failed'), error: true);
        return;
      }
      final len = File(path).lengthSync();
      if (len <= 0) {
        _snack(translate('sd-transfer-no-file'), error: true);
        return;
      }
      setState(() {
        _filePath = path;
        _pickedFileName = f.name;
      });
    } catch (e) {
      _snack('${translate('sd-transfer-pick-failed')}: $e', error: true);
    }
  }

  Future<void> _send() async {
    if (_busy) return;
    if (!_isWordPressAccountConnected()) {
      await _showLoginRequiredDialog();
      return;
    }
    if (!await _ensureJumboCreditsAvailable()) return;
    if (kIsWeb || !Platform.isWindows) {
      _snack(translate('sd-transfer-windows-only'), error: true);
      return;
    }

    final sender = _senderEmailFromProfile();
    final name = _recipientNameCtrl.text.trim();
    final to = _recipientEmailCtrl.text.trim();
    final path = _filePath;
    final messageBody = _messageBodyCtrl.text;

    if (sender == null || !_validEmail(sender)) {
      _snack(translate('sd-transfer-no-sender-email'), error: true);
      return;
    }
    if (name.isEmpty) {
      _snack(translate('sd-transfer-invalid-recipient-name'), error: true);
      return;
    }
    if (!_validEmail(to)) {
      _snack(translate('sd-transfer-invalid-recipient-email'), error: true);
      return;
    }
    if (path == null || !File(path).existsSync()) {
      _snack(translate('sd-transfer-no-file'), error: true);
      return;
    }

    final file = File(path);
    final fileLen = file.lengthSync();
    if (fileLen <= 0) {
      _snack(translate('sd-transfer-no-file'), error: true);
      return;
    }

    final fileName = _pickedFileName ?? path.split(Platform.pathSeparator).last;

    setState(() {
      _busy = true;
    });

    try {
      final init = await _service.init(
        fileName: fileName,
        fileSizeBytes: fileLen,
      );

      if (mounted) {
        setState(() => _uploadProgress = 0);
      }

      await _service.uploadToSignedUrl(
        signedUrl: init.signedUrl,
        filePath: path,
        onProgress: (p) {
          if (mounted) setState(() => _uploadProgress = p);
        },
      );

      final msg = await _service.complete(
        senderEmail: sender,
        recipientName: name,
        recipientEmail: to,
        fileKey: init.fileKey,
        messageBody: messageBody,
      );

      if (mounted) {
        setState(() {
          _filePath = null;
          _pickedFileName = null;
          _uploadProgress = null;
        });
      }

      await _upsertContactAfterSend(name, to);
      await _loadCloudHistory();
      unawaited(_consumeCreditAfterSuccessfulSend());

      if (mounted) {
        _snack(
          msg.isNotEmpty ? msg : translate('sd-transfer-success'),
        );
      }
    } on SecureTransferException catch (e) {
      _snack('${translate('sd-transfer-error')}: ${e.message}', error: true);
    } catch (e) {
      _snack('${translate('sd-transfer-error')}: $e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _uploadProgress = null;
        });
      }
    }
  }

  Future<void> _showContactEditor({SecureTransferContact? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.fullName ?? '');
    final emailCtrl = TextEditingController(text: existing?.email ?? '');
    final phoneCtrl = TextEditingController(text: existing?.phone ?? '');
    final notesCtrl = TextEditingController(text: existing?.notes ?? '');
    final id = existing?.id ?? Uuid().v4();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(
            existing == null
                ? translate('sd-transfer-add-contact')
                : translate('sd-transfer-edit-contact'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: translate('sd-transfer-contact-name'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: translate('sd-transfer-recipient-email'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: translate('sd-transfer-contact-phone'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: translate('sd-transfer-contact-notes'),
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
      ),
    );

    if (ok != true || !mounted) return;
    final em = emailCtrl.text.trim();
    if (!_validEmail(em)) {
      _snack(translate('sd-transfer-invalid-recipient-email'), error: true);
      return;
    }
    final updated = SecureTransferContact(
      id: id,
      fullName: nameCtrl.text.trim(),
      email: em,
      phone: phoneCtrl.text.trim(),
      notes: notesCtrl.text.trim(),
    );
    final next = List<SecureTransferContact>.from(_contacts);
    final ix = next.indexWhere((c) => c.id == id);
    if (ix >= 0) {
      next[ix] = updated;
    } else {
      next.removeWhere((c) => c.email.toLowerCase() == em.toLowerCase());
      next.add(updated);
    }
    next.sort(
        (a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
    await _saveContacts(next);
    _snack(translate('sd-transfer-contact-saved'));
  }

  Future<void> _deleteContact(SecureTransferContact c) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(translate('sd-transfer-delete-contact')),
          content: Text(c.email),
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
      ),
    );
    if (yes != true) return;
    final next = _contacts.where((x) => x.id != c.id).toList();
    await _saveContacts(next);
  }

  Widget _buildAccessGate({
    required ColorScheme cs,
    required Color accent,
    required IconData icon,
    required String bodyKey,
    required String buttonKey,
    required VoidCallback onPressed,
  }) {
    return ColoredBox(
      color: cs.surface,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(26),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 56, color: accent),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    translate(bodyKey),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: onPressed,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Text(
                        translate(buttonKey),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _contactsDrawer(ColorScheme cs, Color accent) {
    return Drawer(
      width: 360,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: accent.withOpacity(0.12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    translate('sd-transfer-contacts-title'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () async {
                      Navigator.pop(context);
                      await _showContactEditor();
                    },
                    icon: const Icon(Icons.add),
                    label: Text(translate('sd-transfer-add-contact')),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _contacts.isEmpty
                  ? Center(
                      child: Text(
                        translate('sd-transfer-contacts-empty'),
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _contacts.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final c = _contacts[i];
                        return ListTile(
                          title: Text(
                            c.fullName.isNotEmpty ? c.fullName : c.email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              c.email,
                              if (c.phone.isNotEmpty) c.phone,
                            ].join('\n'),
                            maxLines: 3,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.share, size: 20),
                                tooltip: translate('sd-transfer-contact-share'),
                                onPressed: () {
                                  Navigator.pop(context);
                                  _applyContact(c);
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await _showContactEditor(existing: c);
                                },
                              ),
                              IconButton(
                                icon: Icon(Icons.delete_outline,
                                    size: 20, color: Colors.red.shade700),
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await _deleteContact(c);
                                },
                              ),
                            ],
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _applyContact(c);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = MyTheme.accent;

    if (kIsWeb || !Platform.isWindows) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            translate('sd-transfer-windows-only'),
            textDirection: TextDirection.rtl,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    if (_gateReady != true) {
      return ColoredBox(
        color: cs.surface,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (!_isWordPressLoggedIn) {
      return _buildAccessGate(
        cs: cs,
        accent: accent,
        icon: Icons.lock_outline_rounded,
        bodyKey: 'sd-transfer-login-required-body',
        buttonKey: 'sd-transfer-login-required-button',
        onPressed: _openAccountLogin,
      );
    }

    if ((_jumboCredits ?? 0) <= 0) {
      return _buildAccessGate(
        cs: cs,
        accent: accent,
        icon: Icons.inventory_2_outlined,
        bodyKey: 'sd-transfer-credits-empty-body',
        buttonKey: 'sd-transfer-buy-credits',
        onPressed: _openBuyCreditsPage,
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: cs.surface,
      endDrawer: _contactsDrawer(cs, accent),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          translate('sd-transfer-title'),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: accent,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          translate('sd-transfer-subtitle'),
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_jumboCreditsLoading)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (_jumboCredits != null)
                    Tooltip(
                      message: translate('sd-transfer-credits-tooltip'),
                      child: Chip(
                        avatar: Icon(Icons.token_outlined,
                            size: 18, color: accent),
                        label: Text(
                          translate('sd-transfer-credits-balance')
                              .replaceFirst('{}', '${_jumboCredits!}'),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: (_jumboCredits ?? 0) > 0
                                ? cs.onSurface
                                : cs.error,
                          ),
                        ),
                        backgroundColor: accent.withOpacity(0.1),
                      ),
                    ),
                  IconButton(
                    tooltip: translate('sd-transfer-refresh-credits'),
                    onPressed: _jumboCreditsLoading ? null : _refreshJumboCredits,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                  IconButton(
                    tooltip: translate('sd-transfer-contacts-title'),
                    onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                    icon: const Icon(Icons.contacts_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: SingleChildScrollView(
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Obx(() {
                                  final _ = CloudSyncService.authRevision.value;
                                  final em = _wordPressSenderEmail();
                                  return InputDecorator(
                                    decoration: InputDecoration(
                                      labelText: translate(
                                        'sd-transfer-sender-from-account',
                                      ),
                                      border: const OutlineInputBorder(),
                                    ),
                                    child: Text(
                                      em ??
                                          translate(
                                              'sd-transfer-no-sender-email'),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: em != null
                                            ? cs.onSurface
                                            : cs.error,
                                      ),
                                    ),
                                  );
                                }),
                                const SizedBox(height: 12),
                                if (_contacts.isNotEmpty) ...[
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: _contacts
                                        .take(6)
                                        .map(
                                          (c) => ActionChip(
                                            avatar: const Icon(Icons.person,
                                                size: 18),
                                            label: Text(
                                              c.fullName.isNotEmpty
                                                  ? c.fullName
                                                  : c.email,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            onPressed: _busy
                                                ? null
                                                : () => _applyContact(c),
                                          ),
                                        )
                                        .toList(),
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _recipientNameCtrl,
                                        decoration: InputDecoration(
                                          labelText: translate(
                                            'sd-transfer-recipient-name',
                                          ),
                                          border: const OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextField(
                                        controller: _recipientEmailCtrl,
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        decoration: InputDecoration(
                                          labelText: translate(
                                            'sd-transfer-recipient-email',
                                          ),
                                          border: const OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip:
                                          translate('sd-transfer-pick-contact'),
                                      onPressed:
                                          _busy ? null : _pickContactQuick,
                                      icon: const Icon(
                                          Icons.contact_mail_outlined),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _messageBodyCtrl,
                                  minLines: 3,
                                  maxLines: 8,
                                  decoration: InputDecoration(
                                    labelText:
                                        translate('sd-transfer-message-body'),
                                    alignLabelWithHint: true,
                                    border: const OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: _busy ? null : _pickFile,
                                  icon: const Icon(Icons.attach_file),
                                  label:
                                      Text(translate('sd-transfer-pick-file')),
                                ),
                                if (_pickedFileName != null) ...[
                                  const SizedBox(height: 8),
                                  SelectableText(
                                    '${translate('sd-transfer-selected')}: $_pickedFileName',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: cs.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                                if (_busy && _uploadProgress != null) ...[
                                  const SizedBox(height: 16),
                                  Text(translate('sd-transfer-uploading')),
                                  const SizedBox(height: 8),
                                  LinearProgressIndicator(
                                    value: _uploadProgress,
                                  ),
                                ],
                                const SizedBox(height: 20),
                                FilledButton.icon(
                                  onPressed: _busy ? null : _send,
                                  icon: _busy
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(Icons.send),
                                  label: Text(translate('sd-transfer-send')),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      translate('sd-transfer-recent'),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: translate(
                                        'sd-transfer-refresh-history'),
                                    icon: const Icon(Icons.refresh, size: 20),
                                    onPressed: _historyLoading
                                        ? null
                                        : _loadCloudHistory,
                                  ),
                                ],
                              ),
                              if (_historyError != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(
                                    _historyError!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.error,
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: _historyLoading
                                    ? const Center(
                                        child: CircularProgressIndicator())
                                    : _history.isEmpty
                                        ? Center(
                                            child: Text(
                                              translate(
                                                  'sd-transfer-recent-empty'),
                                              style: TextStyle(
                                                color: cs.onSurfaceVariant,
                                              ),
                                            ),
                                          )
                                        : ListView.separated(
                                            itemCount: _history.length,
                                            separatorBuilder: (_, __) =>
                                                const Divider(height: 1),
                                            itemBuilder: (context, i) {
                                              final e = _history[i];
                                              return ListTile(
                                                dense: true,
                                                leading: Icon(
                                                  e.ok
                                                      ? Icons.check_circle
                                                      : Icons.error_outline,
                                                  color: e.ok
                                                      ? Colors.green
                                                      : Colors.red,
                                                  size: 20,
                                                ),
                                                title: Text(
                                                  e.fileName,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                subtitle: Text(
                                                  '${e.recipientName} <${e.recipientEmail}>\n${e.atIso}',
                                                  maxLines: 3,
                                                  style: const TextStyle(
                                                      fontSize: 11),
                                                ),
                                                trailing: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    IconButton(
                                                      icon: const Icon(
                                                        Icons.repeat,
                                                        size: 20,
                                                      ),
                                                      tooltip: translate(
                                                        'sd-transfer-repeat-send',
                                                      ),
                                                      onPressed: _busy
                                                          ? null
                                                          : () =>
                                                              _repeatSendFromHistory(
                                                                  e),
                                                    ),
                                                    if (e.downloadUrl != null)
                                                      IconButton(
                                                        icon: const Icon(
                                                          Icons.link,
                                                          size: 20,
                                                        ),
                                                        tooltip: translate(
                                                          'sd-transfer-resend-link',
                                                        ),
                                                        onPressed: () =>
                                                            _copyLink(
                                                                e.downloadUrl),
                                                      ),
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
