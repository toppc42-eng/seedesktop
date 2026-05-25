import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show translate;
import 'package:flutter_hbb/models/platform_model.dart' show localeName;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// External IT apps under `tools\extapps\` next to the running executable.
String seeDesktopExtAppPath(String fileName) {
  final dir = p.join(p.dirname(Platform.resolvedExecutable), 'tools', 'extapps');
  final full = p.join(dir, fileName);
  if (File(full).existsSync()) return full;
  if (kDebugMode) {
    final dev = p.join(r'C:\seedesktop\see-desk', 'tools', 'extapps', fileName);
    if (File(dev).existsSync()) return dev;
  }
  return full;
}

/// Some bundles ship `Tcpview .exe` (space before `.exe`) instead of `Tcpview.exe`.
/// Same for `Profwiz .msi` vs `Profwiz.msi`.
String? _findExistingExtAppPath(String fileName) {
  final primary = seeDesktopExtAppPath(fileName);
  if (File(primary).existsSync()) return primary;
  if (fileName == 'Tcpview.exe') {
    final spaced = seeDesktopExtAppPath('Tcpview .exe');
    if (File(spaced).existsSync()) return spaced;
  }
  if (fileName == 'Profwiz .msi' || fileName == 'Profwiz.msi') {
    for (final alt in <String>['Profwiz .msi', 'Profwiz.msi']) {
      final p = seeDesktopExtAppPath(alt);
      if (File(p).existsSync()) return p;
    }
  }
  if (fileName == 'VirusTotal.exe') {
    for (final alt in <String>['VirusTotal.exe', 'VirusTotal .exe']) {
      final p = seeDesktopExtAppPath(alt);
      if (File(p).existsSync()) return p;
    }
  }
  return null;
}

TextDirection _snackTextDirection() {
  try {
    return localeName.toLowerCase().startsWith('he')
        ? TextDirection.rtl
        : TextDirection.ltr;
  } catch (_) {
    return TextDirection.ltr;
  }
}

/// Sidebar entry for external tools: either `tools\extapps\[extAppFileName]` or `cmd.exe /c …`.
class ExternalItTool {
  final String nameKey;
  final String tooltipKey;
  final String? _extAppFileName;
  final String? _cmdLineAfterC;

  const ExternalItTool.extApp({
    required this.nameKey,
    required this.tooltipKey,
    required String extAppFileName,
  })  : _extAppFileName = extAppFileName,
        _cmdLineAfterC = null;

  const ExternalItTool.cmd({
    required this.nameKey,
    required this.tooltipKey,
    required String cmdLineAfterC,
  })  : _extAppFileName = null,
        _cmdLineAfterC = cmdLineAfterC;
}

/// GodMode / «All Tasks» folder (must match shell folder CLSID).
const String _kGodModeFolderPath =
    r'C:\admintools\admintools.{ED7BA470-8E54-465E-825C-99712043E01C}';

/// Do not chain `explorer` inside one `cmd /c` string — parsing can break on `{…}` and Explorer
/// then opens **Documents**. Use `explorer.exe` with a dedicated argv instead.
Future<void> _launchGodModeAdminPanel() async {
  try {
    await Process.run(
      r'C:\Windows\System32\cmd.exe',
      <String>[
        '/c',
        "mkdir \"$_kGodModeFolderPath\" 2>nul",
      ],
      runInShell: false,
    );
  } catch (_) {}
  try {
    await Process.start(
      r'C:\Windows\explorer.exe',
      <String>[_kGodModeFolderPath],
      mode: ProcessStartMode.detached,
    );
  } catch (_) {
    await Process.start(
      'explorer.exe',
      <String>[_kGodModeFolderPath],
      mode: ProcessStartMode.detached,
    );
  }
}

/// Bundled list for «External tools» (Local maintenance sidebar). Keys: [en.rs] / [he.rs].
const List<ExternalItTool> kExternalItTools = <ExternalItTool>[
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-autoruns',
    tooltipKey: 'lm-ext-tip-autoruns',
    extAppFileName: 'Autoruns.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-everything',
    tooltipKey: 'lm-ext-tip-everything',
    extAppFileName: 'Everything.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-procexp',
    tooltipKey: 'lm-ext-tip-procexp',
    extAppFileName: 'procexp.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-cpuz',
    tooltipKey: 'lm-ext-tip-cpuz',
    extAppFileName: 'cpuz.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-speedfan',
    tooltipKey: 'lm-ext-tip-speedfan',
    extAppFileName: 'speedfan.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-profwiz',
    tooltipKey: 'lm-ext-tip-profwiz',
    extAppFileName: 'Profwiz .msi',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-tcpview',
    tooltipKey: 'lm-ext-tip-tcpview',
    extAppFileName: 'Tcpview.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-treesize',
    tooltipKey: 'lm-ext-tip-treesize',
    extAppFileName: 'TreeSize.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-wnetwatcher',
    tooltipKey: 'lm-ext-tip-wnetwatcher',
    extAppFileName: 'WNetWatcher.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-virustotal',
    tooltipKey: 'lm-ext-tip-virustotal',
    extAppFileName: 'VirusTotal.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-minitool-partition',
    tooltipKey: 'lm-ext-tip-minitool-partition',
    extAppFileName: 'mini tool partition.exe',
  ),
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-bluescreenview',
    tooltipKey: 'lm-ext-tip-bluescreenview',
    extAppFileName: 'BlueScreenView.exe',
  ),
  ExternalItTool.cmd(
    nameKey: 'lm-ext-name-admin-cpanel',
    tooltipKey: 'lm-ext-tip-admin-cpanel',
    cmdLineAfterC: r'', // unused; handled by nameKey branch in [launchExternalItTool]
  ),
];

/// Bundled apps under «Secret folders» (Local maintenance sidebar).
const List<ExternalItTool> kSecretFolderItTools = <ExternalItTool>[
  ExternalItTool.extApp(
    nameKey: 'lm-ext-name-folderhide',
    tooltipKey: 'lm-ext-tip-folderhide',
    extAppFileName: 'FolderHide.exe',
  ),
];

Future<void> _startCmdDetached(String cmdLineAfterC) async {
  try {
    await Process.start(
      r'C:\Windows\System32\cmd.exe',
      <String>['/c', cmdLineAfterC],
      mode: ProcessStartMode.detached,
    );
  } catch (_) {
    await Process.start(
      'cmd.exe',
      <String>['/c', cmdLineAfterC],
      mode: ProcessStartMode.detached,
    );
  }
}

/// Launches an [ExternalItTool]: extapp file from `tools\extapps\`, or `cmd /c` for GodMode.
Future<void> launchExternalItTool(
  BuildContext? context,
  ExternalItTool tool,
) async {
  if (kIsWeb || !Platform.isWindows) return;

  if (tool.nameKey == 'lm-ext-name-admin-cpanel') {
    try {
      await _launchGodModeAdminPanel();
    } catch (e) {
      if (context?.mounted ?? false) {
        ScaffoldMessenger.of(context!).showSnackBar(
          SnackBar(
            content: Text(
              '${translate('lm-ext-snack-cmd-failed')} $e',
              textDirection: _snackTextDirection(),
            ),
          ),
        );
      }
    }
    return;
  }

  final cmd = tool._cmdLineAfterC;
  if (cmd != null && cmd.isNotEmpty) {
    try {
      await _startCmdDetached(cmd);
    } catch (e) {
      if (context?.mounted ?? false) {
        ScaffoldMessenger.of(context!).showSnackBar(
          SnackBar(
            content: Text(
              '${translate('lm-ext-snack-cmd-failed')} $e',
              textDirection: _snackTextDirection(),
            ),
          ),
        );
      }
    }
    return;
  }

  final fileName = tool._extAppFileName!;
  final path = _findExistingExtAppPath(fileName);
  if (path == null) {
    if (context?.mounted ?? false) {
      ScaffoldMessenger.of(context!).showSnackBar(
        SnackBar(
          content: Text(
            '${translate('lm-ext-snack-file-not-found')}\n${seeDesktopExtAppPath(fileName)}',
            textDirection: _snackTextDirection(),
          ),
        ),
      );
    }
    return;
  }
  final wd = p.dirname(path);
  try {
    final lower = path.toLowerCase();
    if (lower.endsWith('.msi')) {
      await Process.start(
        'msiexec.exe',
        <String>['/i', path],
        workingDirectory: wd,
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        path,
        const <String>[],
        workingDirectory: wd,
        mode: ProcessStartMode.detached,
      );
    }
  } catch (e) {
    try {
      final uri = Uri.file(path);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && (context?.mounted ?? false)) {
        ScaffoldMessenger.of(context!).showSnackBar(
          SnackBar(
            content: Text(
              '${translate('lm-ext-snack-launch-failed')} $e',
              textDirection: _snackTextDirection(),
            ),
          ),
        );
      }
    } catch (e2) {
      if (context?.mounted ?? false) {
        ScaffoldMessenger.of(context!).showSnackBar(
          SnackBar(
            content: Text(
              '${translate('lm-ext-snack-launch-failed')} $e2',
              textDirection: _snackTextDirection(),
            ),
          ),
        );
      }
    }
  }
}
