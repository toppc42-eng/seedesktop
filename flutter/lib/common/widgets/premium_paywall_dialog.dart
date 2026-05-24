import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:url_launcher/url_launcher.dart';

String _tr(String key) => platformFFI.translate(key, localeName);

Future<void> showPremiumPaywallDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final isDark = theme.brightness == Brightness.dark;
      final bgColor = isDark ? const Color(0xFF161B22) : Colors.white;
      final bodyColor = isDark ? Colors.white70 : const Color(0xFF4B5563);
      final rtl = bind.mainGetLocalOption(key: kCommConfKeyLang) == 'he';
      return AlertDialog(
        backgroundColor: bgColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        contentPadding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A84FF).withOpacity(0.16),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.lock,
                        color: Color(0xFF0A84FF), size: 30),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    _tr('paywall-pro-title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _tr('paywall-pro-body'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
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
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(_tr('paywall-maybe-later')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0A84FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () async {
                    final uri = Uri.parse('https://seedesktop.com');
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: Text(
                    _tr('paywall-upgrade-cta'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}
