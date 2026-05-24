import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_hbb/utils/cloud_sync_service.dart';

/// Cloud OTP connect + “Sync now” for any Address Book surface (classic tab or Favorites panel).
class AddressBookCloudSyncControls extends StatefulWidget {
  const AddressBookCloudSyncControls({
    super.key,
    this.padding = const EdgeInsets.only(bottom: 10),
    this.onBusyChanged,
    this.onCloudStateChanged,
    this.afterSync,
  });

  final EdgeInsetsGeometry padding;
  final void Function(bool busy)? onBusyChanged;
  final VoidCallback? onCloudStateChanged;
  final Future<void> Function()? afterSync;

  @override
  State<AddressBookCloudSyncControls> createState() =>
      _AddressBookCloudSyncControlsState();
}

class _AddressBookCloudSyncControlsState
    extends State<AddressBookCloudSyncControls> {
  bool _cloudBusy = false;
  String _cloudEmail = '';
  String _cloudDisplayName = '';

  @override
  void initState() {
    super.initState();
    _reloadCloudIdentity();
  }

  void _reloadCloudIdentity() {
    _cloudEmail = CloudSyncService.savedEmail;
    _cloudDisplayName = CloudSyncService.savedDisplayName.isNotEmpty
        ? CloudSyncService.savedDisplayName
        : CloudSyncService.savedUserName;
  }

  void _setBusy(bool v) {
    if (_cloudBusy == v) return;
    setState(() => _cloudBusy = v);
    widget.onBusyChanged?.call(v);
  }

  Future<void> _showConnectToCloudEmailDialog() async {
    final c = TextEditingController(text: _cloudEmail);
    final messenger = ScaffoldMessenger.of(context);
    var loading = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return PopScope(
            canPop: !loading,
            child: AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              title: const Text('Connect to Cloud'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading) const LinearProgressIndicator(),
                  if (loading) const SizedBox(height: 12),
                  TextField(
                    controller: c,
                    autofocus: true,
                    enabled: !loading,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      hintText: 'name@example.com',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed:
                      loading ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () async {
                          final email = c.text.trim();
                          if (email.isEmpty) {
                            messenger.showSnackBar(
                              const SnackBar(
                                  content: Text('Please enter your email')),
                            );
                            return;
                          }
                          setModalState(() => loading = true);
                          final err = await CloudSyncService.requestOtp(email);
                          if (!mounted) return;
                          if (err != null) {
                            setModalState(() => loading = false);
                            messenger
                                .showSnackBar(SnackBar(content: Text(err)));
                            return;
                          }
                          Navigator.of(dialogContext).pop();
                          if (mounted) await _showOtpDialog(email);
                        },
                  child: loading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Next / Continue'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showOtpDialog(String email) async {
    final messenger = ScaffoldMessenger.of(context);
    final c = TextEditingController();
    var loading = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return PopScope(
            canPop: !loading,
            child: AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              title: const Text('Enter verification code'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'We sent a 6-digit code to $email',
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  if (loading) const LinearProgressIndicator(),
                  if (loading) const SizedBox(height: 12),
                  TextField(
                    controller: c,
                    autofocus: true,
                    enabled: !loading,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Code',
                      hintText: '000000',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed:
                      loading ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () async {
                          final code = c.text.trim();
                          if (code.length != 6) {
                            messenger.showSnackBar(
                              const SnackBar(
                                  content:
                                      Text('Please enter the 6-digit code')),
                            );
                            return;
                          }
                          setModalState(() => loading = true);
                          final err = await CloudSyncService.verifyOtp(
                            email: email,
                            otp: code,
                          );
                          if (!mounted) return;
                          if (err != null) {
                            setModalState(() => loading = false);
                            messenger
                                .showSnackBar(SnackBar(content: Text(err)));
                            return;
                          }
                          Navigator.of(dialogContext).pop();
                          if (!mounted) return;
                          setState(() => _reloadCloudIdentity());
                          widget.onCloudStateChanged?.call();
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Connected successfully! / מחובר בהצלחה!',
                              ),
                            ),
                          );
                        },
                  child: loading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Verify'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _runCloudSync() async {
    final messenger = ScaffoldMessenger.of(context);
    _setBusy(true);
    final err = await CloudSyncService.runCloudSync();
    if (!mounted) return;
    if (widget.afterSync != null) {
      await widget.afterSync!();
    }
    if (!mounted) return;
    _setBusy(false);
    widget.onCloudStateChanged?.call();
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
    } else {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Cloud sync complete! / הסנכרון הושלם!'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = CloudSyncService.hasToken;
    _reloadCloudIdentity();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!connected)
            FilledButton.tonalIcon(
              onPressed: _cloudBusy ? null : _showConnectToCloudEmailDialog,
              icon: const Text('☁️', style: TextStyle(fontSize: 18)),
              label: const Text(
                'התחבר לענן',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
                minimumSize: const Size.fromHeight(44),
                backgroundColor: scheme.tertiaryContainer,
                foregroundColor: scheme.onTertiaryContainer,
                elevation: 1,
                side: BorderSide(
                  color: scheme.tertiary.withOpacity(0.6),
                  width: 1.2,
                ),
              ),
            ),
          if (connected) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withOpacity(0.45),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Connected',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  if (_cloudDisplayName.isNotEmpty)
                    Text(
                      _cloudDisplayName,
                      style: const TextStyle(fontSize: 13),
                    ),
                  if (_cloudEmail.isNotEmpty)
                    Text(
                      _cloudEmail,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _cloudBusy ? null : _runCloudSync,
              icon: _cloudBusy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync, size: 20),
              label: Text(_cloudBusy ? 'Syncing…' : 'Sync now'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _cloudBusy
                        ? null
                        : () async {
                            await CloudSyncService.clearSession();
                            if (!mounted) return;
                            setState(_reloadCloudIdentity);
                            widget.onCloudStateChanged?.call();
                            await _showConnectToCloudEmailDialog();
                          },
                    child: const Text('Replace user'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _cloudBusy
                        ? null
                        : () async {
                            await CloudSyncService.clearSession();
                            if (!mounted) return;
                            setState(_reloadCloudIdentity);
                            widget.onCloudStateChanged?.call();
                          },
                    child: const Text('Disconnect'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
