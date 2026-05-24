import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_hbb/common.dart' show MyTheme, globalKey;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'ota_scheduled_task_windows.dart';
import 'version_helper.dart';

class OtaUpdateService {
  /// In-app fallback timer when no Windows scheduled task is registered.
  static Timer? _dailyScheduleTimer;
  static bool _started = false;
  static bool _updateInProgress = false;
  static bool _updateDialogVisible = false;

  static const List<String> _jsonUrls = [
    'https://storage.googleapis.com/my-saas-uploads-2025/seedesktop/updates/version.json',
  ];
  static const String _laterUntilMsKey = 'ota_update_later_until_ms';

  /// OTA checks: Windows `.zip` (silent install via update.bat); macOS `.dmg` (open download).
  /// Call once from main desktop startup.
  ///
  /// - On launch: check manifest and show an update prompt. Never installs automatically.
  /// - Daily silent install: Windows Task Scheduler only (user registers via Updates UI).
  static void startAutoChecks() {
    if (_started) return;
    if (!Platform.isWindows && !Platform.isMacOS) return;
    _started = true;
    if (Platform.isWindows) {
      unawaited(() async {
        await OtaWindowsScheduledTask.ensureScheduledTaskIfMissing();
        await OtaWindowsScheduledTask.syncWithSavedSettingsIfNeeded();
        _scheduleNextDailySilentInstall();
      }());
    }
    Timer(const Duration(seconds: 6), () {
      unawaited(_promptUpdateIfAvailable(reason: 'startup'));
    });
  }

  /// Whether the daily timed silent check is on (`Y`/`N` in Flutter local options; default on).
  static bool get dailySilentScheduleEnabled => _readDailyScheduleEnabled();

  /// Local wall-clock time for the daily silent check (default 16:00).
  static TimeOfDay get dailySilentScheduleTime => _readScheduledDailyTime();

  /// Saves daily schedule options only — does not touch Task Scheduler.
  static Future<void> persistDailySilentSchedule({
    required bool enabled,
    TimeOfDay? time,
  }) async {
    await bind.setLocalFlutterOption(
      k: kOptionOtaSilentDailyEnabled,
      v: enabled ? 'Y' : 'N',
    );
    if (time != null) {
      await bind.setLocalFlutterOption(
        k: kOptionOtaSilentDailyTime,
        v:
            '${time.hour}:${time.minute.toString().padLeft(2, '0')}',
      );
    }
    if (_started) {
      _scheduleNextDailySilentInstall();
    }
  }

  /// Registers/removes Windows scheduled task from saved options (UAC on demand).
  static Future<void> registerWindowsScheduledTask() async {
    await OtaWindowsScheduledTask.registerWithHighestPrivileges();
    if (_started) {
      _scheduleNextDailySilentInstall();
    }
  }

  /// Headless entry for Task Scheduler (`--ota-silent-scheduled`): download + install, no UI.
  static Future<void> runScheduledSilentInstall() async {
    if (!Platform.isWindows) return;
    try {
      await OtaWindowsScheduledTask.syncBeforeScheduledRun();
      if (!OtaUpdateService.dailySilentScheduleEnabled) {
        if (kDebugMode) {
          debugPrint('[OTA] scheduled: daily silent disabled — task removed');
        }
        return;
      }
      await checkNow();
      if (!stateGlobal.hasOtaUpdate.value) {
        if (kDebugMode) {
          debugPrint('[OTA] scheduled: already on latest');
        }
        return;
      }
      final url = stateGlobal.otaDownloadUrl.value.trim();
      if (url.isEmpty || !url.toLowerCase().endsWith('.zip')) {
        if (kDebugMode) {
          debugPrint('[OTA] scheduled: no .zip update URL');
        }
        return;
      }
      if (kDebugMode) {
        debugPrint('[OTA] scheduled: installing from $url');
      }
      await _downloadAndInstallZip(url, relaunchGuiAfterUpdate: false);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[OTA] scheduled install failed: $e\n$st');
      }
    }
  }

  /// `%ProgramData%\\SeeDesktop\\ota_relaunch_after_update.flag` — read by update.bat.
  static const String _otaRelaunchFlagPath =
      r'C:\ProgramData\SeeDesktop\ota_relaunch_after_update.flag';

  /// `1` = user had the app open; `0` = leave closed after install (scheduled silent).
  static Future<void> _writeOtaRelaunchGuiFlag(bool relaunch) async {
    if (!Platform.isWindows) return;
    final flagFile = File(_otaRelaunchFlagPath);
    final parent = flagFile.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    await flagFile.writeAsString(relaunch ? '1' : '0');
  }

  static bool _readDailyScheduleEnabled() {
    try {
      final v = bind.getLocalFlutterOption(k: kOptionOtaSilentDailyEnabled);
      if (v.isEmpty) return true;
      final s = v.trim().toLowerCase();
      return s != 'n' && s != 'false' && s != '0';
    } catch (_) {
      return true;
    }
  }

  static TimeOfDay _readScheduledDailyTime() {
    try {
      final raw =
          bind.getLocalFlutterOption(k: kOptionOtaSilentDailyTime).trim();
      if (raw.isEmpty) {
        return OtaWindowsScheduledTask.defaultScheduleTime;
      }
      final parts = raw.split(':');
      if (parts.length >= 2) {
        final def = OtaWindowsScheduledTask.defaultScheduleTime;
        final h = int.tryParse(parts[0].trim()) ?? def.hour;
        final m = int.tryParse(parts[1].trim()) ?? def.minute;
        return TimeOfDay(
          hour: h.clamp(0, 23),
          minute: m.clamp(0, 59),
        );
      }
    } catch (_) {}
    return OtaWindowsScheduledTask.defaultScheduleTime;
  }

  static Future<bool> _isUpdatePromptSnoozed() async {
    try {
      final raw = bind.getLocalFlutterOption(k: _laterUntilMsKey).trim();
      final untilMs = int.tryParse(raw) ?? 0;
      if (untilMs <= 0) return false;
      return DateTime.now().millisecondsSinceEpoch < untilMs;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _snoozeUpdatePromptFor24Hours() async {
    final untilMs = DateTime.now()
        .add(const Duration(hours: 24))
        .millisecondsSinceEpoch
        .toString();
    await bind.setLocalFlutterOption(k: _laterUntilMsKey, v: untilMs);
  }

  static void _scheduleNextDailySilentInstall() {
    _dailyScheduleTimer?.cancel();
    if (!_readDailyScheduleEnabled()) {
      if (kDebugMode) {
        debugPrint('[OTA] daily silent schedule disabled in settings');
      }
      return;
    }
    // Prefer Windows Task Scheduler when registered successfully.
    if (Platform.isWindows && OtaWindowsScheduledTask.taskRegistered) {
      if (kDebugMode) {
        debugPrint(
            '[OTA] using Windows scheduled task for daily silent update');
      }
      return;
    }
    final t = _readScheduledDailyTime();
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    if (!next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }
    if (kDebugMode) {
      debugPrint('[OTA] next daily silent check at $next (local)');
    }
    _dailyScheduleTimer = Timer(next.difference(now), () {
      unawaited(_promptUpdateIfAvailable(reason: 'scheduled_daily'));
      _scheduleNextDailySilentInstall();
    });
  }

  static Future<void> _promptUpdateIfAvailable({required String reason}) async {
    try {
      if (await _isUpdatePromptSnoozed()) {
        if (kDebugMode) {
          debugPrint('[OTA] prompt ($reason): snoozed for 24h');
        }
        return;
      }
      await checkNow();
      if (!stateGlobal.hasOtaUpdate.value) return;
      final url = stateGlobal.otaDownloadUrl.value.trim();
      if (url.isEmpty || !_isSupportedOtaPackageUrl(url)) {
        if (kDebugMode) {
          debugPrint(
              '[OTA] prompt ($reason): skip — unsupported or empty update URL');
        }
        return;
      }
      final context = globalKey.currentContext;
      if (context == null || !context.mounted) {
        if (reason == 'startup') {
          Timer(const Duration(seconds: 5), () {
            unawaited(_promptUpdateIfAvailable(reason: 'startup-retry'));
          });
        }
        return;
      }
      if (kDebugMode) {
        debugPrint('[OTA] prompt ($reason): showing update dialog for $url');
      }
      await _showUpdateAvailableDialog(context, suppressOnLater: true);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[OTA] prompt ($reason) failed: $e\n$st');
      }
    }
  }

  static Future<void> checkNow() async {
    try {
      final currentVersion = await getUnifiedAppVersion();
      http.Response? response;
      String? matchedJsonUrl;
      for (final jsonUrl in _jsonUrls) {
        final manifestUri = Uri.parse(jsonUrl).replace(
          queryParameters: {'ts': '${DateTime.now().millisecondsSinceEpoch}'},
        );
        final r = await http.get(
          manifestUri,
          headers: {'Cache-Control': 'no-cache'},
        );
        response = r;
        if (r.statusCode == 200) {
          matchedJsonUrl = jsonUrl;
          break;
        }
      }
      if (response == null || response.statusCode != 200) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final latestVersion = (data['latest_version'] ?? '').toString();
      final rawDownloadUrl = Platform.isMacOS
          ? (data['mac_download_url'] ?? data['download_url'] ?? '').toString()
          : (data['download_url'] ?? '').toString();
      final releaseNotes = (data['release_notes'] ?? '').toString();
      final effectiveDownloadUrl =
          _resolveDownloadUrl(rawDownloadUrl, matchedJsonUrl);

      final hasUpdate = latestVersion.isNotEmpty &&
          effectiveDownloadUrl.isNotEmpty &&
          _isVersionNewer(currentVersion, latestVersion);
      stateGlobal.hasOtaUpdate.value = hasUpdate;
      stateGlobal.otaLatestVersion.value = latestVersion;
      stateGlobal.otaDownloadUrl.value = effectiveDownloadUrl;
      stateGlobal.otaReleaseNotes.value = releaseNotes;
    } catch (_) {}
  }

  static Future<void> showCheckResultDialog(BuildContext context) async {
    final currentVersion = await getUnifiedAppVersion();
    await checkNow();
    if (!context.mounted) return;
    if (!stateGlobal.hasOtaUpdate.value) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('You are using the latest version ($currentVersion)'),
          backgroundColor: Colors.green,
        ),
      );
      return;
    }

    await _showUpdateAvailableDialog(context, suppressOnLater: true);
  }

  static Future<void> _showUpdateAvailableDialog(
    BuildContext context, {
    required bool suppressOnLater,
  }) async {
    if (_updateDialogVisible) return;
    if (!context.mounted) return;
    final latestVersion = stateGlobal.otaLatestVersion.value;
    final releaseNotes = stateGlobal.otaReleaseNotes.value;
    final downloadUrl = stateGlobal.otaDownloadUrl.value;

    _updateDialogVisible = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        var installing = false;
        return StatefulBuilder(
          builder: (BuildContext context,
              void Function(void Function()) setLocalState) {
            return PopScope(
              canPop: !installing,
              child: AlertDialog(
                title: const Text('🎉 New Update Available!'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (installing) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const SizedBox(
                              width: 28,
                              height: 28,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.8),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                'Downloading and preparing the update… '
                                'This can take up to a minute. The app is working — please wait.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                      ],
                      Text('Version $latestVersion is available to download.'),
                      const SizedBox(height: 10),
                      const Text('Release Notes:'),
                      const SizedBox(height: 6),
                      Text(releaseNotes),
                      const SizedBox(height: 12),
                      Text(
                        Platform.isMacOS
                            ? 'The macOS update opens your browser to download the DMG. Open the disk image and drag SeeDesktop into Applications to finish installing.'
                            : 'Update downloads to temp, extracts, runs update.bat in a detached process, then exits so files can be replaced. If the app was open, it will reopen after the update; if it was closed, it stays closed.',
                      ),
                    ],
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: installing
                        ? null
                        : () async {
                            if (suppressOnLater) {
                              await _snoozeUpdatePromptFor24Hours();
                            }
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                          },
                    child: const Text('Later'),
                  ),
                  TextButton(
                    onPressed: installing
                        ? null
                        : () async {
                            setLocalState(() => installing = true);
                            await _downloadAndInstallOrOpen(
                                dialogContext, downloadUrl);
                            if (dialogContext.mounted) {
                              setLocalState(() => installing = false);
                            }
                          },
                    child: installing
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: MyTheme.accent,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text('Updating…'),
                            ],
                          )
                        : const Text('Update Now'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: MyTheme.accent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: installing ? null : () => exit(0),
                    child: const Text('Close App'),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _updateDialogVisible = false;
    });
  }

  static Future<void> openDownload(BuildContext context) async {
    final url = stateGlobal.otaDownloadUrl.value;
    if (url.isEmpty) {
      await showCheckResultDialog(context);
      return;
    }
    await _downloadAndInstallOrOpen(context, url);
  }

  static Future<void> _downloadAndInstallOrOpen(
      BuildContext context, String downloadUrl) async {
    if (_updateInProgress) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Update is already in progress.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    try {
      _updateInProgress = true;
      if (downloadUrl.toLowerCase().endsWith('.zip')) {
        await _downloadAndInstallZip(downloadUrl);
        return;
      }
      if (await canLaunchUrl(Uri.parse(downloadUrl))) {
        await launchUrl(Uri.parse(downloadUrl),
            mode: LaunchMode.externalApplication);
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open update download URL.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Update failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      _updateInProgress = false;
    }
  }

  /// Work folder for OTA payload: prefer `C:\\Windows\\Temp` on Windows (SYSTEM-friendly), else app temp.
  static Future<Directory> _otaWorkBaseDirectory() async {
    if (Platform.isWindows) {
      try {
        final winTemp = Directory(r'C:\Windows\Temp');
        if (await winTemp.exists()) {
          return winTemp;
        }
      } catch (_) {}
    }
    return getTemporaryDirectory();
  }

  /// Silent agent update: run `update.bat` **detached** (inherits environment, survives parent exit),
  /// then **exit(0)** immediately so the EXE is not locked for replacement.
  ///
  /// Use when the process already runs elevated (e.g. SYSTEM); no UAC, no blocking on the child.
  static Future<void> executeSilentUpdate(
    String batFilePath, {
    bool relaunchGuiAfterUpdate = true,
  }) async {
    await _launchUpdateBatDetachedAndExit(
      batFilePath,
      relaunchGuiAfterUpdate: relaunchGuiAfterUpdate,
    );
  }

  static Future<void> _launchUpdateBatDetachedAndExit(
    String batFilePath, {
    required bool relaunchGuiAfterUpdate,
  }) async {
    final trimmed = batFilePath.trim();
    if (trimmed.isEmpty) {
      throw 'update.bat path is empty.';
    }
    final bat = File(trimmed);
    if (!await bat.exists()) {
      throw 'update.bat not found: $trimmed';
    }
    final batAbs = bat.absolute.path;
    final workingDir = bat.parent.path;

    if (!Platform.isWindows) {
      throw UnsupportedError(
          'Detached update.bat launch is only implemented for Windows.');
    }
    await _writeOtaRelaunchGuiFlag(relaunchGuiAfterUpdate);
    await Process.start(
      r'C:\Windows\System32\cmd.exe',
      ['/c', batAbs],
      workingDirectory: workingDir,
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  static Future<void> _downloadAndInstallZip(
    String zipUrl, {
    bool relaunchGuiAfterUpdate = true,
  }) async {
    final baseDir = await _otaWorkBaseDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final sep = Platform.pathSeparator;
    final workDir = '${baseDir.path}${sep}seedesktop_update_$stamp';
    final zipPath = '$workDir${sep}SeeDesktopinst_$stamp.zip';
    final extractDir = '$workDir${sep}extract';

    final dio = Dio();
    await Directory(workDir).create(recursive: true);
    try {
      await dio.download(
        zipUrl,
        zipPath,
        deleteOnError: true,
      );
    } finally {
      dio.close(force: true);
    }
    final zipFile = File(zipPath);
    if (!await zipFile.exists()) {
      throw 'Downloaded update package is missing.';
    }
    if (await zipFile.length() <= 0) {
      throw 'Downloaded update package is empty.';
    }

    final escapedZip = zipPath.replaceAll("'", "''");
    final escapedExtract = extractDir.replaceAll("'", "''");
    // Extract only; do **not** Stop-Process here (would kill this app mid-update).
    // Do **not** use RunAs — silent SYSTEM/service updates inherit privileges; UAC breaks quiet mode.
    final psCommand = """
if (Test-Path '$escapedExtract') {
  Remove-Item -Recurse -Force '$escapedExtract'
}
\$zipPath = '$escapedZip'
\$extractPath = '$escapedExtract'
\$maxAttempts = 8
\$expanded = \$false
for (\$i = 1; \$i -le \$maxAttempts; \$i++) {
  try {
    \$fs = [System.IO.File]::Open(\$zipPath, 'Open', 'Read', 'None')
    \$fs.Close()
    Expand-Archive -LiteralPath \$zipPath -DestinationPath \$extractPath -Force
    \$expanded = \$true
    break
  } catch {
    if (\$i -eq \$maxAttempts) { throw }
    Start-Sleep -Milliseconds 600
  }
}
if (-not \$expanded) {
  throw 'Failed to extract update package after retries.'
}
\$updateBat = Get-ChildItem -Path '$escapedExtract' -Recurse -File -Filter 'update.bat' |
  Select-Object -First 1 -ExpandProperty FullName
if (-not \$updateBat) {
  throw 'update.bat was not found in extracted update package.'
}
Write-Output \$updateBat
""";

    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      psCommand,
    ]);
    if (result.exitCode != 0) {
      throw 'Failed to extract update package: ${result.stderr}${result.stdout}';
    }

    final out = '${result.stdout}'.trim();
    final lines = out
        .split(RegExp(r'[\r\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      throw 'Extraction succeeded but update.bat path was not returned.';
    }
    final batPath = lines.last;
    if (!batPath.toLowerCase().endsWith('.bat')) {
      throw 'Invalid update.bat path from extractor: $batPath';
    }

    await _launchUpdateBatDetachedAndExit(
      batPath,
      relaunchGuiAfterUpdate: relaunchGuiAfterUpdate,
    );
  }

  static bool _isSupportedOtaPackageUrl(String url) {
    final lower = url.trim().toLowerCase();
    if (lower.isEmpty) return false;
    if (Platform.isWindows) return lower.endsWith('.zip');
    if (Platform.isMacOS) return lower.endsWith('.dmg');
    return false;
  }

  static String _resolveDownloadUrl(
      String rawDownloadUrl, String? matchedJsonUrl) {
    if (matchedJsonUrl == null) return rawDownloadUrl;
    final jsonUri = Uri.tryParse(matchedJsonUrl);
    final downloadUri = Uri.tryParse(rawDownloadUrl);
    if (jsonUri == null || downloadUri == null) return rawDownloadUrl;

    final manifestDir = jsonUri.path.replaceAll(RegExp(r'/version\.json$'), '');
    final fileName = downloadUri.pathSegments.isNotEmpty
        ? downloadUri.pathSegments.last
        : 'SeeDesktop.exe';
    if (downloadUri.path == '/downloads/$fileName') {
      return jsonUri.replace(path: '$manifestDir/$fileName').toString();
    }
    return rawDownloadUrl;
  }

  static bool _isVersionNewer(String currentVersion, String latestVersion) {
    List<int> parse(String v) => v
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final current = parse(currentVersion);
    final latest = parse(latestVersion);
    final len = current.length > latest.length ? current.length : latest.length;
    for (int i = 0; i < len; i++) {
      final c = i < current.length ? current[i] : 0;
      final l = i < latest.length ? latest[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }
}
