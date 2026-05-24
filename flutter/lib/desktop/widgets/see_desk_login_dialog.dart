import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/utils/license_manager.dart';
import 'package:flutter_hbb/utils/license_restart.dart';

void _scheduleRestartAfterLicenseSave() {
  scheduleMicrotask(() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await restartSeeDesktopAfterLicenseChange();
  });
}

Future<void> showSeeDeskLoginDialog(BuildContext context) async {
  final formKey = GlobalKey<FormState>();
  final controller = TextEditingController();
  bool loading = false;
  String? errorText;

  await showDialog<void>(
    context: context,
    barrierDismissible: !loading,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> onSubmit() async {
            if (!formKey.currentState!.validate()) {
              return;
            }

            final license = controller.text.trim();
            setState(() {
              loading = true;
              errorText = null;
            });

            try {
              final verify = await verifyLicenseWithServer(license);
              if (!verify.approved) {
                if (verify.isExpired) {
                  await saveLicenseToPrefs(
                    license,
                    allowedConnections: 1,
                    activeConnections: verify.activeConnections,
                    expiryDateIsoUtc: verify.expiryDateIsoUtc,
                    isExpired: true,
                  );
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text(verify.message)),
                    );
                    Navigator.of(dialogContext).pop();
                  }
                  _scheduleRestartAfterLicenseSave();
                  return;
                }
                setState(() {
                  errorText = verify.message;
                  loading = false;
                });
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(content: Text(verify.message)),
                  );
                }
                return;
              }

              await saveLicenseToPrefs(
                license,
                allowedConnections: verify.allowedConnections,
                activeConnections: verify.activeConnections,
                expiryDateIsoUtc: verify.expiryDateIsoUtc,
                isExpired: verify.isExpired,
              );

              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
              _scheduleRestartAfterLicenseSave();
            } on TimeoutException catch (_) {
              setState(() {
                errorText = kLicenseCommunicationErrorMessage;
                loading = false;
              });
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text(kLicenseCommunicationErrorMessage)),
                );
              }
            } catch (_) {
              setState(() {
                errorText = kLicenseCommunicationErrorMessage;
                loading = false;
              });
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text(kLicenseCommunicationErrorMessage)),
                );
              }
            }
          }

          return AlertDialog(
            title: const Text('SeeDesktop License Login'),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: controller,
                    autofocus: true,
                    enabled: !loading,
                    decoration: const InputDecoration(
                      labelText: 'License Key',
                      hintText: 'Enter your license key',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'License key is required';
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => onSubmit(),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                  if (loading) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: loading ? null : () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: loading ? null : onSubmit,
                child: const Text('Verify & Login'),
              ),
            ],
          );
        },
      );
    },
  );

  controller.dispose();
}
