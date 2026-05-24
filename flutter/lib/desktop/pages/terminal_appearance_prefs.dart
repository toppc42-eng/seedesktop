import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

const String kPrefTerminalBgArgb = 'terminal_window_bg_argb';
const String kPrefTerminalFgArgb = 'terminal_window_fg_argb';

/// xterm theme: custom background + foreground; ANSI palette from [TerminalThemes.whiteOnBlack].
TerminalTheme terminalThemeFromBaseColors(Color background, Color foreground) {
  const base = TerminalThemes.whiteOnBlack;
  return TerminalTheme(
    cursor: Color.lerp(foreground, background, 0.15)!,
    selection: foreground.withAlpha(120),
    foreground: foreground,
    background: background,
    black: base.black,
    red: base.red,
    green: base.green,
    yellow: base.yellow,
    blue: base.blue,
    magenta: base.magenta,
    cyan: base.cyan,
    white: base.white,
    brightBlack: base.brightBlack,
    brightRed: base.brightRed,
    brightGreen: base.brightGreen,
    brightYellow: base.brightYellow,
    brightBlue: base.brightBlue,
    brightMagenta: base.brightMagenta,
    brightCyan: base.brightCyan,
    brightWhite: base.brightWhite,
    searchHitBackground: base.searchHitBackground,
    searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
    searchHitForeground: base.searchHitForeground,
  );
}

Future<TerminalTheme> loadTerminalWindowTheme() async {
  final p = await SharedPreferences.getInstance();
  final bgI = p.getInt(kPrefTerminalBgArgb);
  final fgI = p.getInt(kPrefTerminalFgArgb);
  if (bgI != null && fgI != null) {
    return terminalThemeFromBaseColors(Color(bgI), Color(fgI));
  }
  return terminalThemeFromBaseColors(Colors.black, Colors.white);
}

Future<void> saveTerminalWindowTheme(Color background, Color foreground) async {
  final p = await SharedPreferences.getInstance();
  // ignore: deprecated_member_use
  await p.setInt(kPrefTerminalBgArgb, background.value);
  // ignore: deprecated_member_use
  await p.setInt(kPrefTerminalFgArgb, foreground.value);
}
