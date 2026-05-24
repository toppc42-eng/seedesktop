import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';

/// Shared header used by both connection panels (Remote ID + Your Desktop).
/// Both panels render their title with the same typography (titleMedium + bold)
/// and a help icon whose tooltip explains what the number below means.
Widget getConnectionPageTitle(
  BuildContext context,
  bool isWeb, {
  String titleKey = 'Control Remote Desktop',
  String? tooltipKey,
}) {
  final resolvedTooltipKey =
      tooltipKey ?? (isWeb ? 'web_id_input_tip' : 'id_input_tip');
  final titleStyle = Theme.of(context)
      .textTheme
      .titleMedium
      ?.copyWith(fontWeight: FontWeight.w700, height: 1);
  return Row(
    mainAxisAlignment: MainAxisAlignment.center,
    mainAxisSize: MainAxisSize.max,
    children: [
      Flexible(
        child: AutoSizeText(
          translate(titleKey),
          maxLines: 1,
          minFontSize: 10,
          textAlign: TextAlign.center,
          style: titleStyle,
        ),
      ),
      Tooltip(
        waitDuration: const Duration(milliseconds: 300),
        message: translate(resolvedTooltipKey),
        child: Icon(
          Icons.help_outline_outlined,
          size: 16,
          color:
              Theme.of(context).textTheme.titleMedium?.color?.withOpacity(0.5),
        ),
      ).marginOnly(left: 4),
    ],
  );
}
