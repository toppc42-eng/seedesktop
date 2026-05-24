import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

const String kSeeDesktopProPurchaseUrl = 'https://seedesktop.com';

/// Shown when a non–Pro user tries to open **My Devices** (RMM dashboard).
Future<void> showRmmProGateDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final isDark = theme.brightness == Brightness.dark;
      final rtl =
          bind.mainGetLocalOption(key: kCommConfKeyLang) == 'he';
      final bg = isDark ? const Color(0xFF161B22) : Colors.white;
      final bodyColor = isDark ? Colors.white70 : const Color(0xFF4B5563);
      return AlertDialog(
        backgroundColor: bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        contentPadding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.monitor_heart_outlined,
                        color: Color(0xFF0284C7), size: 28),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  translate('rmm-pro-gate-title'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  translate('rmm-pro-gate-body'),
                  textAlign: rtl ? TextAlign.right : TextAlign.start,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: bodyColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(translate('rmm-pro-gate-close')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () async {
              final uri = Uri.parse(kSeeDesktopProPurchaseUrl);
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: Text(
              translate('rmm-pro-gate-buy'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      );
    },
  );
}
