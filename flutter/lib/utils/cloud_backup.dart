import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Paths next to [Platform.resolvedExecutable] (Windows release layout).
class CloudBackupPaths {
  static String exeDir() => p.dirname(Platform.resolvedExecutable);

  static String backupBat() => p.join(exeDir(), 'backup.bat');

  static String restoreBat() => p.join(exeDir(), 'restore.bat');
  static String listBat() => p.join(exeDir(), 'list_backups.bat');

  /// Legacy: plain JSON per-user (optional; prefer encrypted .dat from license API).
  static String? gcsCredentialsUserPath() {
    final la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return null;
    return p.join(la, 'SeeDesktop', 'cloud', 'gcs_credentials.json');
  }
}

/// Launches [backup.bat] in a separate process: stops SeeDesktop, zips, uploads, restarts.
/// [apiServer] is license API base URL (HTTPS); credentials are fetched from
/// `{api}/seedesktop/gcs_credentials.dat` (encrypted).
Future<void> startCloudBackupDetached(String email, String apiServer) async {
  final bat = CloudBackupPaths.backupBat();
  if (!File(bat).existsSync()) {
    throw StateError('backup.bat not found next to executable.');
  }
  final wd = CloudBackupPaths.exeDir();
  await Process.start(
    'cmd',
    ['/c', 'start', '', '/min', bat, email.trim(), apiServer.trim()],
    workingDirectory: wd,
    mode: ProcessStartMode.detached,
  );
}

String _outputText(dynamic o) {
  if (o == null) return '';
  if (o is List<int>) return utf8.decode(o);
  return o.toString();
}

/// Lists cloud backups for [email], newest first. [apiServer] is license API base URL.
Future<List<Map<String, dynamic>>> listCloudBackups(
  String email,
  String apiServer,
) async {
  final bat = CloudBackupPaths.listBat();
  if (!File(bat).existsSync()) {
    throw StateError('list_backups.bat not found next to executable.');
  }
  final args = ['/c', 'call', bat, email.trim()];
  final a = apiServer.trim();
  if (a.isNotEmpty) {
    args.add(a);
  }
  final r = await Process.run(
    'cmd',
    args,
    workingDirectory: CloudBackupPaths.exeDir(),
    runInShell: false,
  );
  if (r.exitCode != 0) {
    throw Exception(
      _outputText(r.stderr).trim().isEmpty
          ? _outputText(r.stdout)
          : _outputText(r.stderr),
    );
  }
  final text = _outputText(r.stdout).trim();
  if (text.isEmpty) return [];
  final decoded = json.decode(text);
  if (decoded is! List) return [];
  return decoded
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
}

/// Restores from cloud and restarts SeeDesktop (see restore.bat).
Future<ProcessResult> runCloudRestoreBat(
  String email,
  String stamp,
  String apiServer,
) async {
  final bat = CloudBackupPaths.restoreBat();
  if (!File(bat).existsSync()) {
    throw StateError('restore.bat not found next to executable.');
  }
  final args = ['/c', 'call', bat, email.trim(), stamp.trim()];
  if (apiServer.trim().isNotEmpty) {
    args.add(apiServer.trim());
  }
  return Process.run(
    'cmd',
    args,
    workingDirectory: CloudBackupPaths.exeDir(),
    runInShell: false,
  );
}
