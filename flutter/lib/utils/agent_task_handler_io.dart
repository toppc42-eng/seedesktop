import 'dart:convert';
import 'dart:io' show Platform, Process, ProcessResult;

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/utils/license_api_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_hbb/models/platform_model.dart';
import 'license_manager.dart';

const String kLastPendingTaskKey = 'last_pending_task';

/// Prevents re-running chkdsk/shutdown on every heartbeat while server still sends the same task.
const String kPendingTaskDispatchedKey = 'pending_task_dispatched';

const String kAgentSubmitLogEndpoint =
    '$kLicenseServerBaseUrl/agent_submit_log';

const String _kHwidKey = 'license_hardware_id';

/// Prefer numeric SeeDesktop connection ID; fall back for edge cases only.
Future<String> _resolveAgentIdForVps() async {
  var id = (await bind.mainGetMyId()).trim();
  if (id.isNotEmpty) return id;
  final prefs = await SharedPreferences.getInstance();
  id = prefs.getString(_kHwidKey)?.trim() ?? '';
  if (id.isNotEmpty) return id;
  return (await bind.mainGetUuid()).trim();
}

void _printExecutionFailed(String context, Object error, [String? stderrOrExtra]) {
  final extra = stderrOrExtra?.trim() ?? '';
  final errStr = error.toString();
  final detail = extra.isNotEmpty ? extra : errStr;
  final line =
      "🚨 EXECUTION FAILED: The app likely needs to be 'Run As Administrator'. Error: [$detail]";
  print('');
  print(line);
  if (context.isNotEmpty) {
    print('   ($context)');
  }
  print('');
  debugPrint(line);
  if (context.isNotEmpty) {
    debugPrint('   ($context)');
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Called once at main app startup (Windows). Scrapes Event Viewer logs for a
/// completed [last_pending_task] and POSTs them to the VPS, then clears prefs.
Future<void> checkAndSubmitPendingLogs() async {
  if (!Platform.isWindows) return;

  final prefs = await SharedPreferences.getInstance();
  final taskRaw = prefs.getString(kLastPendingTaskKey)?.trim();
  if (taskRaw == null || taskRaw.isEmpty) return;

  final taskNorm = taskRaw.toLowerCase();

  try {
    final agentId = await _resolveAgentIdForVps();
    if (agentId.isEmpty) {
      if (kDebugMode) {
        debugPrint('[AgentTask] checkAndSubmitPendingLogs: empty agent_id');
      }
      return;
    }

    String logContent;
    if (taskNorm == 'chkdsk') {
      logContent = await _runPowerShellLogCommand(_psChkdskLogCommand);
    } else if (taskNorm == 'memtest') {
      logContent = await _runPowerShellLogCommand(_psMemtestLogCommand);
    } else if (taskNorm.startsWith('pwsh:')) {
      // pwsh: tasks are executed and submitted in-session (no reboot path).
      // Just let the finally block clear the prefs.
      return;
    } else {
      logContent = '(unknown task: $taskRaw — no scraper defined)';
    }

    await _postSubmitLog(
      agentId: agentId,
      taskName: taskRaw,
      logContent: logContent,
    );
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('[AgentTask] checkAndSubmitPendingLogs error: $e\n$st');
    }
    try {
      final agentId = await _resolveAgentIdForVps();
      if (agentId.isNotEmpty) {
        await _postSubmitLog(
          agentId: agentId,
          taskName: taskRaw,
          logContent: 'Error collecting log: $e',
        );
      }
    } catch (_) {}
  } finally {
    await prefs.remove(kLastPendingTaskKey);
    await prefs.remove(kPendingTaskDispatchedKey);
    if (kDebugMode) {
      debugPrint(
          '[AgentTask] cleared $kLastPendingTaskKey + $kPendingTaskDispatchedKey');
    }
  }
}

/// After a successful heartbeat, if the server sends [pending_task], persist
/// and run the associated local actions (Windows only).
Future<void> handleInboundPendingTask(String taskName) async {
  final t = taskName.trim();
  if (t.isEmpty) return;
  if (!Platform.isWindows) return;

  final prefs = await SharedPreferences.getInstance();
  final prev = prefs.getString(kLastPendingTaskKey)?.trim();
  final alreadyDispatched = prefs.getBool(kPendingTaskDispatchedKey) ?? false;

  await prefs.setString(kLastPendingTaskKey, t);
  if (kDebugMode) {
    debugPrint('[AgentTask] saved $kLastPendingTaskKey=$t');
  }

  // Avoid re-firing chkdsk/shutdown while heartbeats still report the same task.
  if (alreadyDispatched && prev != null && prev.toLowerCase() == t.toLowerCase()) {
    if (kDebugMode) {
      debugPrint('[AgentTask] skip duplicate execute for $t');
    }
    return;
  }

  await prefs.setBool(kPendingTaskDispatchedKey, true);

  final norm = t.toLowerCase();
  try {
    if (norm == 'chkdsk') {
      await _runChkdskAndReboot();
    } else if (norm == 'memtest') {
      await _runMemtest();
    } else if (norm.startsWith('pwsh:')) {
      // Arbitrary PowerShell command sent from the RMM admin UI.
      // Run immediately, submit log, then clear prefs (no reboot needed).
      await _runPwshCommandTask(t);
    } else {
      if (kDebugMode) {
        debugPrint('[AgentTask] unknown pending_task: $t (no local runner)');
      }
    }
  } catch (e, st) {
    _printExecutionFailed('handleInboundPendingTask', e, st.toString());
    if (kDebugMode) {
      debugPrint('[AgentTask] execute task failed: $e\n$st');
    }
  }
}

/// Execute an arbitrary PowerShell command delivered via the RMM task queue.
/// The task name format is `pwsh:<base64_encoded_ps_command>`.
Future<void> _runPwshCommandTask(String taskRaw) async {
  final encoded = taskRaw.length > 5 ? taskRaw.substring(5) : '';
  String psCommand;
  try {
    psCommand = utf8.decode(base64Decode(encoded)).trim();
  } catch (_) {
    psCommand = encoded; // fallback: treat as raw (unencoded) command
  }
  if (psCommand.isEmpty) return;

  if (kDebugMode) {
    debugPrint('[AgentTask] pwsh command: $psCommand');
  }

  final agentId = await _resolveAgentIdForVps();
  if (agentId.isEmpty) return;

  String logContent;
  try {
    logContent = await _runPowerShellLogCommand(psCommand);
  } catch (e) {
    logContent = 'Error running command: $e';
  }

  try {
    await _postSubmitLog(
      agentId: agentId,
      taskName: 'ps_output',
      logContent: '> ${psCommand.trim()}\n\n$logContent',
    );
  } catch (_) {}

  // Clear pending task immediately — no reboot path for pwsh commands.
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(kLastPendingTaskKey);
  await prefs.remove(kPendingTaskDispatchedKey);
}

// ---------------------------------------------------------------------------
// Heartbeat: local execution
// ---------------------------------------------------------------------------

Future<void> _runProcessChecked({
  required String label,
  required String executable,
  required List<String> arguments,
  bool runInShell = false,
}) async {
  try {
    final r = await Process.run(
      executable,
      arguments,
      runInShell: runInShell,
    );
    final err = '${r.stderr}'.trim();
    final out = '${r.stdout}'.trim();
    if (kDebugMode) {
      debugPrint(
          '[AgentTask] $label exit=${r.exitCode} out=$out err=$err');
    }
    if (r.exitCode != 0) {
      final detail = err.isNotEmpty ? err : out;
      _printExecutionFailed(
        label,
        'exitCode=${r.exitCode}',
        detail.isNotEmpty ? detail : null,
      );
    }
  } catch (e, st) {
    _printExecutionFailed(label, e, st.toString());
  }
}

Future<void> _runChkdskAndReboot() async {
  // Schedule chkdsk (cmd.exe /c echo Y | chkdsk c: /f), then reboot.
  await _runProcessChecked(
    label: 'chkdsk',
    executable: 'cmd.exe',
    arguments: ['/c', 'echo Y | chkdsk c: /f'],
    runInShell: false,
  );

  await _runProcessChecked(
    label: 'shutdown /r',
    executable: 'shutdown',
    arguments: ['/r', '/t', '5'],
    runInShell: false,
  );
}

Future<void> _runMemtest() async {
  await _runProcessChecked(
    label: 'mdsched.exe (Memory Diagnostics)',
    executable: 'mdsched.exe',
    arguments: [],
    runInShell: true,
  );
}

// ---------------------------------------------------------------------------
// Event log (PowerShell)
// ---------------------------------------------------------------------------

/// Uses legacy EventLog API (more forgiving than Get-WinEvent when Wininit
/// provider metadata is missing on some systems).
const String _psChkdskLogCommand =
    r"Get-EventLog -LogName Application -Source 'Wininit','Chkdsk' -Newest 1 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Message";

const String _psMemtestLogCommand =
    r"Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results'} -MaxEvents 1 | Select-Object -ExpandProperty Message";

String _logNotFoundMessage(int? exitCode) =>
    'Log not found. The scan may have been skipped or the Event Provider is missing. Exit code: ${exitCode ?? 'N/A'}';

/// Never throws: on failure or empty output returns [_logNotFoundMessage] so the
/// VPS still receives a submission and the pending queue can clear.
Future<String> _runPowerShellLogCommand(String command) async {
  late final ProcessResult result;
  try {
    result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        command,
      ],
      runInShell: false,
    );
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('[AgentTask] PowerShell log scrape Process.run failed: $e\n$st');
    }
    return _logNotFoundMessage(null);
  }

  final out = '${result.stdout}'.trim();
  if (out.isEmpty) {
    if (kDebugMode) {
      final err = '${result.stderr}'.trim();
      debugPrint(
          '[AgentTask] PowerShell log empty (exit=${result.exitCode}) stderr=$err');
    }
    return _logNotFoundMessage(result.exitCode);
  }
  return out;
}

// ---------------------------------------------------------------------------
// HTTP: submit log
// ---------------------------------------------------------------------------

Future<void> _postSubmitLog({
  required String agentId,
  required String taskName,
  required String logContent,
}) async {
  final body = jsonEncode({
    'agent_id': agentId,
    'task_name': taskName,
    'log_content': logContent,
  });
  final resp = await LicenseApiRouter.post(
    Uri.parse(kAgentSubmitLogEndpoint),
    headers: const {'Content-Type': 'application/json'},
    body: body,
    requestTimeout: const Duration(seconds: 30),
  );
  if (kDebugMode) {
    debugPrint(
        '[AgentTask] agent_submit_log status=${resp.statusCode} body=${resp.body}');
  }
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('agent_submit_log failed: ${resp.statusCode} ${resp.body}');
  }
}

// ---------------------------------------------------------------------------
// Hardware telemetry (WMI) for agent heartbeat — Windows only
// ---------------------------------------------------------------------------

/// Local hardware for heartbeat via PowerShell + CIM.
/// FreePhysicalMemory / TotalVisibleMemorySize are in **KB**.
/// To convert KB → GB: divide by 1024 twice (KB→MB→GB).
/// Also collects basic S.M.A.R.T status via Get-PhysicalDisk.
Future<Map<String, String>> collectHardwareTelemetryForHeartbeat() async {
  if (!Platform.isWindows) return {};

  const na = 'N/A';
  final out = <String, String>{
    'cpu_usage': na,
    'ram_usage': na,
    'disk_free': na,
    'smart_status': na,
  };

  const psScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
$cpu = 0
try { $cpu = [int][math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average) } catch {}
$ramFreeKb = 0; $ramTotalKb = 0
try {
  $os = Get-CimInstance Win32_OperatingSystem
  $ramFreeKb  = [double]$os.FreePhysicalMemory
  $ramTotalKb = [double]$os.TotalVisibleMemorySize
} catch {}
$diskFreeGb = 0
try { $diskFreeGb = [int][math]::Round([double](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB) } catch {}
$smart = 'Unknown'
try { $smart = (Get-PhysicalDisk | Select-Object -First 1).HealthStatus } catch {}
if (-not $smart) { try { $smart = (Get-WmiObject Win32_DiskDrive | Select-Object -First 1).Status } catch { $smart = 'Unknown' } }
$ramUsedKb = $ramTotalKb - $ramFreeKb
$ramUsedGb  = [math]::Round($ramUsedKb  / 1024 / 1024, 1)
$ramTotalGb = [math]::Round($ramTotalKb / 1024 / 1024, 1)
@{ cpu=$cpu; ram_used_gb=$ramUsedGb; ram_total_gb=$ramTotalGb; disk_free_gb=$diskFreeGb; smart=$smart } | ConvertTo-Json -Compress
''';

  try {
    final r = await Process.run(
      'powershell.exe',
      const [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        psScript,
      ],
      runInShell: false,
    );
    final raw = '${r.stdout}'.trim();
    if (raw.isNotEmpty) {
      // Strip BOM / non-JSON prefix if present
      final jsonStart = raw.indexOf('{');
      final cleaned = jsonStart > 0 ? raw.substring(jsonStart) : raw;
      final j = jsonDecode(cleaned);
      if (j is Map<String, dynamic>) {
        final cpu = j['cpu'];
        if (cpu != null) {
          out['cpu_usage'] =
              '${(cpu is num) ? cpu.round() : int.tryParse('$cpu') ?? 0}%';
        }
        final ru = j['ram_used_gb'];
        final rt = j['ram_total_gb'];
        if (ru != null && rt != null) {
          final a = (ru is num) ? ru.toDouble() : double.tryParse('$ru') ?? 0;
          final b = (rt is num) ? rt.toDouble() : double.tryParse('$rt') ?? 0;
          if (b > 0) {
            out['ram_usage'] =
                '${a.toStringAsFixed(1)}GB / ${b.toStringAsFixed(1)}GB';
          }
        }
        final dg = j['disk_free_gb'];
        if (dg != null) {
          final g = (dg is num) ? dg.round() : int.tryParse('$dg') ?? 0;
          out['disk_free'] = '${g}GB Free';
        }
        final sm = j['smart']?.toString().trim();
        if (sm != null && sm.isNotEmpty) out['smart_status'] = sm;
      }
    }
  } catch (_) {}

  return out;
}

