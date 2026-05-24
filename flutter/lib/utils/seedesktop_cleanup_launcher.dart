import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/utils/agent_heartbeat_manager.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// Bundled `.exe` next to [SeeDesktop.exe] (release). In debug, may use repo `tools/*/dist`.
String seeDesktopBundledToolPath(String fileName) {
  final primary =
      p.join(p.dirname(Platform.resolvedExecutable), fileName);
  if (File(primary).existsSync()) return primary;
  if (kDebugMode) {
    final dev = <String, String>{
      'SeeDesktopCleanup.exe':
          r'C:\seedesktop\see-desk\tools\seedesktop_cleanup\dist\SeeDesktopCleanup.exe',
      'SeeDesktopDiskCheck.exe':
          r'C:\seedesktop\see-desk\tools\seedesktop_disk_check\dist\SeeDesktopDiskCheck.exe',
      'SeeDesktopSystemRepair.exe': r'C:\seedesktop\see-desk\tools\seedesktop_system_repair\dist\SeeDesktopSystemRepair.exe',
    }[fileName];
    if (dev != null && File(dev).existsSync()) return dev;
  }
  return primary;
}

/// Bundled tool next to [SeeDesktop.exe] (release layout). In debug, falls back
/// to the repo `tools/seedesktop_cleanup/dist` path when present.
String seeDesktopCleanupExePath() =>
    seeDesktopBundledToolPath('SeeDesktopCleanup.exe');

/// Opens a bundled tool by file name (Windows desktop only).
Future<void> openSeeDesktopBundledToolLocally(
  BuildContext? context,
  String fileName,
) async {
  if (!isWindows) return;
  final path = seeDesktopBundledToolPath(fileName);
  if (!File(path).existsSync()) {
    if (context?.mounted ?? false) {
      ScaffoldMessenger.of(context!).showSnackBar(
        SnackBar(
          content: Text(
            '${translate('rmm-cleanup-exe-not-found')}\n$path',
          ),
        ),
      );
    }
    return;
  }
  final uri = Uri.file(path);
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && (context?.mounted ?? false)) {
    ScaffoldMessenger.of(context!).showSnackBar(
      SnackBar(content: Text(translate('rmm-cleanup-launch-failed'))),
    );
  }
}

/// Opens [SeeDesktopCleanup.exe] (Windows desktop only).
Future<void> openSeeDesktopCleanupLocally(BuildContext? context) async {
  await openSeeDesktopBundledToolLocally(context, 'SeeDesktopCleanup.exe');
}

/// UTF-16LE for PowerShell `-EncodedCommand` (same as Windows Terminal health scripts).
Uint8List _utf16LeBytes(String input) {
  final units = input.codeUnits;
  final out = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    out[i * 2] = u & 0xff;
    out[i * 2 + 1] = (u >> 8) & 0xff;
  }
  return out;
}

/// Full command for [queueCommandRemote] — resolves path from running SeeDesktop process.
String buildRemoteLaunchCleanupCommand() {
  const ps = r"$p = (Get-Process -Name 'SeeDesktop' -ErrorAction SilentlyContinue | Select-Object -First 1).Path; if ($null -ne $p) { $d = Split-Path -LiteralPath $p; $c = Join-Path $d 'SeeDesktopCleanup.exe'; if (Test-Path -LiteralPath $c) { Start-Process -FilePath $c } }";
  final enc = base64Encode(_utf16LeBytes(ps));
  return 'powershell.exe -NoProfile -NonInteractive -EncodedCommand $enc';
}

/// Queue cleanup on a remote agent (same mechanism as «פעולות מומלצות»).
Future<void> queueRemoteSeeDesktopCleanup({
  required BuildContext context,
  required String agentId,
}) async {
  final id = agentId.trim();
  if (id.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(translate('rmm-cleanup-no-agent-id'))),
      );
    }
    return;
  }
  try {
    await queueCommandRemote(
      agentId: id,
      command: buildRemoteLaunchCleanupCommand(),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(translate('rmm-cleanup-queued-remote'))),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${translate('rmm-cleanup-queue-failed')}: $e'),
      ),
    );
  }
}
