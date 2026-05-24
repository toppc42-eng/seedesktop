import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// Whether the app locale uses RTL layout for main-menu strings (Hebrew, Arabic, …).
bool mainMenuLocaleRtl() {
  final lc = localeName.toLowerCase();
  return lc.startsWith('he') ||
      lc.startsWith('ar') ||
      lc.startsWith('fa') ||
      lc.startsWith('ur');
}

/// Popup menu row text aligned for current locale direction.
Widget mainMenuPopupChild(String text, {TextStyle? style}) {
  final rtl = mainMenuLocaleRtl();
  return Directionality(
    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    child: Align(
      alignment: rtl ? Alignment.centerRight : Alignment.centerLeft,
      widthFactor: 1.0,
      child: Text(text, style: style),
    ),
  );
}
