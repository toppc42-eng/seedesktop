import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

const String kPrefTerminalSdTargetUserPrefix = 'terminal_sd_target_user_';

/// Allowed folder names under `C:\Users` (reduces injection risk in pasted PowerShell).
bool isValidWindowsUsersFolderName(String raw) {
  final s = raw.trim();
  if (s.isEmpty || s.length > 64) return false;
  return RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._\-]*$').hasMatch(s);
}

String? escapeForPowerShellSingleQuoted(String name) {
  if (!isValidWindowsUsersFolderName(name)) return null;
  return name.replaceAll("'", "''");
}

Future<String?> loadSavedWindowsProfileFolder(String peerId) async {
  if (peerId.isEmpty) return null;
  final prefs = await SharedPreferences.getInstance();
  final v = prefs.getString('$kPrefTerminalSdTargetUserPrefix$peerId')?.trim();
  if (v == null || v.isEmpty) return null;
  return isValidWindowsUsersFolderName(v) ? v : null;
}

Future<void> saveWindowsProfileFolder(String peerId, String? folder) async {
  if (peerId.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final key = '$kPrefTerminalSdTargetUserPrefix$peerId';
  final t = folder?.trim() ?? '';
  if (t.isEmpty || !isValidWindowsUsersFolderName(t)) {
    await prefs.remove(key);
    return;
  }
  await prefs.setString(key, t);
}

/// PowerShell one-liner (no trailing newline) that sets `$SD_UserName`, `$SD_UserProfile`,
/// and `$global:SD_TargetUser*` for catalogue / manual scripts.
String? buildWindowsTargetProfileBootstrapPs1(String folderName) {
  final esc = escapeForPowerShellSingleQuoted(folderName);
  if (esc == null) return null;
  return "\$SD_UserName='$esc'; "
      "\$SD_UserProfile=[System.IO.Path]::Combine(\$env:SystemDrive,'Users',\$SD_UserName); "
      "\$global:SD_TargetUserName=\$SD_UserName; "
      "\$global:SD_TargetUserProfile=\$SD_UserProfile";
}

/// Prepends the bootstrap so pasted scripts can use the target profile under `C:\Users\<name>`.
String wrapWindowsTargetProfileScript(String folderName, String cmd) {
  final pre = buildWindowsTargetProfileBootstrapPs1(folderName);
  if (pre == null) return cmd;
  return '$pre\r\n\r\n$cmd';
}

// --- Remote probe: interactive user + profile folders (for SYSTEM terminal) ---

const String kSeedeskProfilesStart = '<<<SEEDESK_PROFILES_START>>>';
const String kSeedeskProfilesEnd = '<<<SEEDESK_PROFILES_END>>>';

/// PowerShell emitted as UTF-16LE for -EncodedCommand. Approximates “who is at the PC” via Win32_ComputerSystem.UserName.
const String kWindowsProfileProbeScript = r'''
$ErrorActionPreference='SilentlyContinue'
$active=$null
try{
  $wu=(Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
  if($wu){
    $sam=($wu -replace '.*\\','').Trim()
    if($sam -ne ''){$active=$sam}
  }
}catch{}
$profiles=New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath ([IO.Path]::Combine($env:SystemDrive,'Users')) -Directory -ErrorAction SilentlyContinue|ForEach-Object{$profiles.Add($_.Name)}
$uniq=$profiles|Sort-Object -Unique
$payload=@{active=$active;profiles=@($uniq)}|ConvertTo-Json -Depth 5 -Compress
Write-Output '<<<SEEDESK_PROFILES_START>>>'
Write-Output $payload
Write-Output '<<<SEEDESK_PROFILES_END>>>'
''';

Uint8List _utf16LeForProbe(String input) {
  final units = input.codeUnits;
  final out = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    out[i * 2] = u & 0xff;
    out[i * 2 + 1] = (u >> 8) & 0xff;
  }
  return out;
}

/// Command to paste into the remote shell (caller may append `\r`).
String buildWindowsProfileProbeCommand() {
  final enc = base64Encode(_utf16LeForProbe(kWindowsProfileProbeScript));
  return 'powershell.exe -NoProfile -NonInteractive -EncodedCommand $enc';
}

String _stripAnsiForProbe(String s) {
  return s
      .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\x1b\][^\x07]*\x07'), '');
}

bool isReservedWindowsUsersFolder(String name) {
  final u = name.trim().toUpperCase();
  return u == 'PUBLIC' || u == 'DEFAULT' || u == 'DEFAULT USER';
}

class WindowsProfileProbeResult {
  WindowsProfileProbeResult({this.activeSam, required this.profileFolders});

  final String? activeSam;
  final List<String> profileFolders;

  static WindowsProfileProbeResult? parseCapture(String raw) {
    final stripped = _stripAnsiForProbe(raw);
    final si = stripped.lastIndexOf(kSeedeskProfilesStart);
    final ei = stripped.lastIndexOf(kSeedeskProfilesEnd);
    if (si < 0 || ei < 0 || ei <= si) return null;
    var jsonStr =
        stripped.substring(si + kSeedeskProfilesStart.length, ei).trim();
    jsonStr = jsonStr.replaceAll(RegExp(r'^\uFEFF'), '');
    final brace = jsonStr.indexOf('{');
    if (brace > 0) jsonStr = jsonStr.substring(brace);
    if (jsonStr.isEmpty) return null;
    try {
      final obj = jsonDecode(jsonStr) as Map<String, dynamic>;
      final active = obj['active']?.toString().trim();
      final activeSam = (active == null || active.isEmpty) ? null : active;
      final profiles = <String>[];
      final profRaw = obj['profiles'];
      if (profRaw is List) {
        for (final e in profRaw) {
          final s = e?.toString().trim() ?? '';
          if (s.isNotEmpty) profiles.add(s);
        }
      } else if (profRaw is String && profRaw.isNotEmpty) {
        profiles.add(profRaw);
      } else if (profRaw is Map) {
        for (final e in profRaw.values) {
          final s = e?.toString().trim() ?? '';
          if (s.isNotEmpty) profiles.add(s);
        }
      }
      return WindowsProfileProbeResult(
        activeSam: activeSam,
        profileFolders: profiles,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Picks the folder under `C:\Users` to use: interactive user if valid, else first suitable profile.
String? pickDefaultWindowsProfileFolder(WindowsProfileProbeResult r) {
  final usable = <String>[];
  for (final p in r.profileFolders) {
    if (!isValidWindowsUsersFolderName(p)) continue;
    if (isReservedWindowsUsersFolder(p)) continue;
    usable.add(p);
  }
  usable.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  if (usable.isEmpty) return null;

  final active = r.activeSam?.trim();
  if (active != null && active.isNotEmpty) {
    for (final p in usable) {
      if (p.toLowerCase() == active.toLowerCase()) return p;
    }
    for (final p in usable) {
      if (p.toLowerCase().startsWith(active.toLowerCase())) return p;
    }
  }
  return usable.first;
}

/// Distinct usable names for a dropdown (sorted).
List<String> usableWindowsProfileFolders(WindowsProfileProbeResult r) {
  final set = <String>{};
  for (final p in r.profileFolders) {
    if (!isValidWindowsUsersFolderName(p)) continue;
    if (isReservedWindowsUsersFolder(p)) continue;
    set.add(p);
  }
  final list = set.toList();
  list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return list;
}
