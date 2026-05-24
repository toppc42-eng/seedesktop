import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Starts a new SeeDesktop process and exits this one so license/session state
/// reloads cleanly (Rust + Flutter). Desktop only; no-op on web/mobile.
Future<void> restartSeeDesktopAfterLicenseChange() async {
  if (kIsWeb) return;
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
  final exe = Platform.resolvedExecutable;
  final wd = p.dirname(exe);
  try {
    if (Platform.isWindows) {
      await Process.start(
        'cmd',
        ['/c', 'start', '', exe],
        workingDirectory: wd,
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        exe,
        const <String>[],
        workingDirectory: wd,
        mode: ProcessStartMode.detached,
      );
    }
  } catch (e) {
    debugPrint('restartSeeDesktopAfterLicenseChange: $e');
    return;
  }
  exit(0);
}
