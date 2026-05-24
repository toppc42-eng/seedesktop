import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/native/win32.dart'
    if (dart.library.html) 'package:flutter_hbb/web/win32.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/utils/license_api_router.dart';

import 'agent_task_handler.dart';
import 'freemium_guard.dart' show licenseTierForHeartbeatPayload;
import 'license_manager.dart';

/// Agent POST body may include `hw_health` (object) alongside cpu/ram/disk strings.
/// The VPS should persist it on the agent row and return it from `get_all_agents`.
const String kAgentHeartbeatEndpoint = '$kLicenseServerBaseUrl/agent_heartbeat';
const String kGetAllAgentsEndpoint = '$kLicenseServerBaseUrl/get_all_agents';
const String kSetAgentTaskEndpoint = '$kLicenseServerBaseUrl/set_agent_task';
const String kQueueCommandEndpoint = '$kLicenseServerBaseUrl/queue_command';

/// Body: `{"prompt": "..."}`. Optional: `{"prompt":"...","system_prompt":"..."}` —
/// the Terminal AI Copilot sends the long system string from `ai_copilot_system_prompt.dart`;
/// the API should apply it as the model system instruction (or merge with server defaults).
const String kAiGenerateCommandEndpoint =
    '$kLicenseServerBaseUrl/ai_generate_command';

/// Must match the VPS `API_KEY` for routes that require `Authorization: Bearer`.
/// Do not log this value from the client.
const String kVpsAdminBearerKey = 'ELI_TOP_SECRET_2026_KEY';

/// VPS `last_seen` / online window: keep heartbeats in the ~30–60s range.
const Duration _kHeartbeatInterval = Duration(seconds: 45);
const String _kPrefsDailyRmmSyncDate = 'agent_heartbeat_daily_rmm_sync_date';

/// Last successful numeric peer id from [bind.mainGetMyId] (fallback if IPC is slow at boot).
const String _kPrefsCachedNumericPeerId = 'agent_heartbeat_numeric_peer_id';

/// Resolves the SeeDesktop **connection ID** (digits only, same as main window / `connect()`).
/// Retries briefly while Rust/IPC initializes, then optional prefs cache from last run.
Future<String> _resolveNumericAgentIdForHeartbeat() async {
  final prefs = await SharedPreferences.getInstance();
  for (var attempt = 0; attempt < 25; attempt++) {
    final id = (await bind.mainGetMyId()).trim();
    if (id.isNotEmpty) {
      await prefs.setString(_kPrefsCachedNumericPeerId, id);
      return id;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  final cached = prefs.getString(_kPrefsCachedNumericPeerId)?.trim() ?? '';
  if (cached.isNotEmpty && kDebugMode) {
    debugPrint(
        '[AgentHeartbeat] mainGetMyId still empty; using cached peer id');
  }
  return cached;
}

/// Windows 11 uses build >= 22000 but marketing strings still say "Windows 10".
int? _windowsBuildFromOperatingSystemVersion(String osVersion) {
  final parts = osVersion.trim().split('.');
  if (parts.length >= 3) {
    return int.tryParse(parts[2]);
  }
  return null;
}

int _windowsBuildNumberForHeartbeat(String osv, String combined) {
  if (!Platform.isWindows) return 0;
  try {
    final b = getWindowsTargetBuildNumber_();
    if (b >= 10240) return b;
  } catch (_) {}
  final fromOs = _windowsBuildFromOperatingSystemVersion(osv);
  if (fromOs != null && fromOs >= 10240) return fromOs;
  final m = RegExp(r'\b(\d{5,6})\b').allMatches(combined);
  for (final x in m) {
    final n = int.tryParse(x.group(1)!);
    if (n != null && n >= 22000 && n < 100000) return n;
  }
  return 0;
}

String _heartbeatOsVersionString() {
  try {
    final os = Platform.operatingSystem;
    final osv = Platform.operatingSystemVersion;
    var combined = '$os $osv'.trim();
    if (Platform.isWindows) {
      final build = _windowsBuildNumberForHeartbeat(osv, combined);
      if (build >= 22000) {
        combined = combined.replaceAll(
            RegExp(r'\bWindows\s*10\b', caseSensitive: false), 'Windows 11');
        combined = combined.replaceAll(
            RegExp(r'\bMicrosoft\s+Windows\s*10\b', caseSensitive: false),
            'Microsoft Windows 11');
      }
    }
    return combined;
  } catch (_) {
    return 'Unknown';
  }
}

/// Flat strings + optional [cpu_model], [ram_gb], [ram_slots], [disk_info] for VPS/UI parity.
/// [metrics] is decoded [bind.mainGetSysMetrics] (includes `hw_health`).
void applyHeartbeatFlatTelemetryFromSysMetrics(
  Map<String, dynamic> bodyMap,
  Map<String, dynamic> metrics,
) {
  Map<String, dynamic>? hwHealthMap;
  final hh = metrics['hw_health'];
  if (hh is Map) {
    hwHealthMap = Map<String, dynamic>.from(hh);
    bodyMap['hw_health'] = hwHealthMap;
  }

  final cpu = (metrics['cpu'] as num?)?.toDouble();
  if (cpu != null && cpu >= 0) {
    bodyMap['cpu_usage'] = '${cpu.round()}%';
  } else {
    bodyMap['cpu_usage'] = '—';
  }

  final ru = (metrics['ram_used_gb'] as num?)?.toDouble();
  final rt = (metrics['ram_total_gb'] as num?)?.toDouble();
  if (ru != null && rt != null && rt > 0) {
    final usedPct = (ru / rt * 100).clamp(0.0, 100.0);
    bodyMap['ram_usage'] =
        '${ru.toStringAsFixed(1)} GB / ${rt.toStringAsFixed(1)} GB (${usedPct.round()}%)';
  } else {
    bodyMap['ram_usage'] = '—';
  }

  final df = (metrics['disk_free_gb'] as num?)?.toDouble();
  final dt = (metrics['disk_total_gb'] as num?)?.toDouble();
  if (df != null && dt != null && dt > 0) {
    final freePct = (df / dt * 100).clamp(0.0, 100.0);
    bodyMap['disk_free'] =
        '${df.round()}GB free of ${dt.round()}GB (${freePct.round()}%)';
  } else {
    bodyMap['disk_free'] = '—';
  }

  if (hwHealthMap != null) {
    final cpuModel = hwHealthMap['cpu_model']?.toString().trim() ?? '';
    final cpuName = hwHealthMap['cpu_name']?.toString().trim() ?? '';
    if (cpuModel.isNotEmpty) {
      bodyMap['cpu_model'] = cpuModel;
    } else if (cpuName.isNotEmpty) {
      bodyMap['cpu_model'] = cpuName;
    }

    final ramGb = hwHealthMap['ram_gb'];
    if (ramGb is num) {
      bodyMap['ram_gb'] = ramGb.toDouble();
    }

    final ramSlotsUsage =
        hwHealthMap['ram_slots_usage']?.toString().trim() ?? '';
    if (ramSlotsUsage.isNotEmpty && ramSlotsUsage.toLowerCase() != 'unknown') {
      bodyMap['ram_slots'] = ramSlotsUsage;
    } else {
      final su = hwHealthMap['ram_slots_used'];
      final st = hwHealthMap['ram_slots_total'];
      if (su is num && st is num && st.toInt() > 0) {
        bodyMap['ram_slots'] = '${su.toInt()}/${st.toInt()}';
      }
    }

    final di = hwHealthMap['disk_info'];
    if (di is List && di.isNotEmpty) {
      bodyMap['disk_info'] = di;
    }
  }
}

// ---------------------------------------------------------------------------
// Singleton heartbeat sender
// ---------------------------------------------------------------------------

/// Sends periodic `POST /api/agent_heartbeat` (~45s). See `RMM_AGENT_HEARTBEAT.md`.
/// Call [start] once at app startup; idempotent.
class AgentHeartbeatManager {
  AgentHeartbeatManager._();
  static final AgentHeartbeatManager instance = AgentHeartbeatManager._();

  Timer? _timer;
  Timer? _dailyTimer;
  bool _tickInFlight = false;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_kHeartbeatInterval, (_) => unawaited(_tick()));
    unawaited(_tick());
    unawaited(_runDailyUpdateIfNeeded(startupCatchup: true));
    _scheduleNextMidnightUpdate();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _dailyTimer?.cancel();
    _dailyTimer = null;
  }

  String _todayLocalIsoDate() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  void _scheduleNextMidnightUpdate() {
    _dailyTimer?.cancel();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1);
    final wait = next.difference(now);
    _dailyTimer = Timer(wait, () async {
      await _runDailyUpdateIfNeeded(startupCatchup: false);
      _scheduleNextMidnightUpdate();
    });
  }

  Future<void> _runDailyUpdateIfNeeded({required bool startupCatchup}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = _todayLocalIsoDate();
      final last = prefs.getString(_kPrefsDailyRmmSyncDate)?.trim() ?? '';
      if (last == today) return;

      await sendHeartbeat(force: true);
      await prefs.setString(_kPrefsDailyRmmSyncDate, today);

      if (kDebugMode) {
        final src = startupCatchup ? 'startup' : 'midnight';
        debugPrint('[AgentHeartbeat] daily RMM refresh sent ($src)');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AgentHeartbeat] daily RMM refresh failed: $e');
      }
    }
  }

  /// Sends one heartbeat immediately (for testing / admin).
  /// [force] waits for any in-flight tick to finish, then runs (UI button).
  Future<void> sendHeartbeat({bool force = false}) async {
    if (_tickInFlight) {
      if (!force) {
        if (kDebugMode) {
          debugPrint('[AgentHeartbeat] sendHeartbeat skipped — tick in flight');
        }
        return;
      }
      var waited = 0;
      while (_tickInFlight && waited < 120000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        waited += 50;
      }
      if (_tickInFlight) return;
    }
    _tickInFlight = true;
    try {
      await _performHeartbeatOnce();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AgentHeartbeat] sendHeartbeat: $e');
      }
    } finally {
      _tickInFlight = false;
    }
  }

  Future<void> _tick() async {
    if (_tickInFlight) return;
    _tickInFlight = true;
    try {
      await _performHeartbeatOnce();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AgentHeartbeat] tick ignored: $e');
      }
    } finally {
      _tickInFlight = false;
    }
  }

  Future<void> _performHeartbeatOnce() async {
    final licenseKey = (await getSavedLicenseKey())?.trim() ?? '';
    if (licenseKey.isEmpty && kDebugMode) {
      debugPrint(
          '[AgentHeartbeat] no license_key -> sending unlicensed heartbeat');
    }

    // Same normalization as VPS: strip then remove spaces (UI "מזהה סוכן").
    final agentIdRaw = await _resolveNumericAgentIdForHeartbeat();
    final agentId = normalizeSeeDesktopId(agentIdRaw);
    if (agentId.isEmpty) {
      if (kDebugMode) {
        debugPrint(
            '[AgentHeartbeat] skip: no numeric peer id (mainGetMyId + cache empty)');
      }
      return;
    }

    String computerName = 'Unknown';
    try {
      final raw = bind.mainGetLoginDeviceInfo();
      if (raw.isNotEmpty) {
        final info = jsonDecode(raw) as Map<String, dynamic>;
        final n = info['name']?.toString().trim() ?? '';
        if (n.isNotEmpty) computerName = n;
      }
    } catch (_) {}

    final osVersion = _heartbeatOsVersionString();

    await _reconcileStalePeerMapAgainstRust();
    final outgoingSessions = await getActiveLicenseSessionCount();
    final incomingSessions = await _incomingConnectionManagerClients();
    final activeSessions = outgoingSessions + incomingSessions;
    final status = activeSessions > 0 ? 'in_session' : 'online';

    final bodyMap = <String, dynamic>{
      'agent_id': agentId,
      'license_key': licenseKey,
      'license_tier': await licenseTierForHeartbeatPayload(),
      'computer_name': computerName,
      'os_version': osVersion,
      'status': status,
    };

    try {
      final metrics =
          jsonDecode(bind.mainGetSysMetrics()) as Map<String, dynamic>;
      applyHeartbeatFlatTelemetryFromSysMetrics(bodyMap, metrics);
    } catch (_) {
      bodyMap['cpu_usage'] = '—';
      bodyMap['ram_usage'] = '—';
      bodyMap['disk_free'] = '—';
    }

    // Windows: S.M.A.R.T / physical disk health (supplement; flat usage comes from sys metrics).
    try {
      final winHw = await collectHardwareTelemetryForHeartbeat();
      final sm = winHw['smart_status']?.trim() ?? '';
      if (sm.isNotEmpty && sm != 'N/A' && sm.toLowerCase() != 'unknown') {
        bodyMap['smart_status'] = sm;
      }
    } catch (_) {}

    final body = jsonEncode(bodyMap);

    final response = await LicenseApiRouter.post(
      Uri.parse(kAgentHeartbeatEndpoint),
      headers: const {'Content-Type': 'application/json'},
      body: body,
      requestTimeout: const Duration(seconds: 15),
    );

    if (kDebugMode) {
      final safe = Map<String, dynamic>.from(bodyMap);
      safe['license_key'] = '***';
      debugPrint(
          '[AgentHeartbeat] ✓ sent: ${jsonEncode(safe)} status=${response.statusCode}');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final pt = decoded['pending_task'];
          if (pt != null) {
            final s = pt.toString().trim();
            if (s.isNotEmpty && s.toLowerCase() != 'null') {
              await handleInboundPendingTask(s);
            }
          }

          final exec = decoded['execute_command'];
          if (exec != null) {
            final cmd = exec.toString().trim();
            if (cmd.isNotEmpty && cmd.toLowerCase() != 'null') {
              try {
                await bind.executeSystemCommand(command: cmd);
                if (kDebugMode) {
                  debugPrint(
                      '[AgentHeartbeat] execute_command spawned via FFI (preview): ${cmd.length > 100 ? '${cmd.substring(0, 100)}…' : cmd}');
                }
              } catch (e) {
                if (kDebugMode) {
                  debugPrint('[AgentHeartbeat] execute_command FFI error: $e');
                }
              }
            }
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[AgentHeartbeat] response parse/handle: $e');
        }
      }
    }
  }
}

/// Clients in the connection manager (someone connected *to* this machine).
Future<int> _incomingConnectionManagerClients() async {
  if (!isDesktop) return 0;
  try {
    return await bind.cmGetClientsLength();
  } catch (_) {
    return 0;
  }
}

/// Drops stale `license_peer_sessions` entries when Rust has zero UI sessions for that peer
/// (avoids false `in_session` heartbeats after disconnect / crash).
Future<void> _reconcileStalePeerMapAgainstRust() async {
  try {
    final map = await loadPeerSessionMapPublic();
    if (map.isEmpty) return;
    final newMap = <String, List<String>>{};
    var changed = false;
    for (final e in map.entries) {
      final pid = e.key.trim();
      if (pid.isEmpty) continue;
      var total = 0;
      for (var ct = 0; ct < 6; ct++) {
        try {
          total += bind.peerGetSessionsCount(id: pid, connType: ct);
        } catch (_) {}
      }
      if (total > 0) {
        newMap[pid] = e.value;
      } else {
        changed = true;
      }
    }
    if (!changed) return;
    await savePeerSessionMapPublic(newMap);
    final prefs = await SharedPreferences.getInstance();
    final n = newMap.values.where((v) => v.isNotEmpty).length;
    if (n > 0) {
      await prefs.setInt('active_connections', n);
    } else {
      await prefs.remove('session_id');
      await prefs.setInt('active_connections', 0);
    }
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

/// Physical disk line from server `hw_health.disk_info` (`disk_model` / `disk_type` or legacy keys).
class DiskInfo {
  final String model;
  final String diskType;

  const DiskInfo({required this.model, required this.diskType});

  factory DiskInfo.fromJson(Map<String, dynamic> m) {
    final type = m['disk_type'] ?? m['type'];
    final modelRaw = m['disk_model'] ?? m['model'];
    return DiskInfo(
      model: modelRaw?.toString() ?? '',
      diskType: type?.toString() ?? '',
    );
  }
}

/// Volume entry from `hw_health.disks` (free space + `disk_model` / `disk_type` per mount).
class HwHealthDiskVolume {
  final String id;
  final double? totalGb;
  final double? freeGb;
  final double? freePct;
  final String diskModel;
  final String diskType;

  const HwHealthDiskVolume({
    required this.id,
    this.totalGb,
    this.freeGb,
    this.freePct,
    required this.diskModel,
    required this.diskType,
  });

  factory HwHealthDiskVolume.fromJson(Map<String, dynamic> m) {
    double? pFreePct;
    final fp = m['free_pct'];
    if (fp is num) {
      pFreePct = fp.toDouble();
    } else {
      pFreePct = double.tryParse(fp?.toString().trim() ?? '');
    }
    return HwHealthDiskVolume(
      id: m['id']?.toString() ?? '',
      totalGb: AgentInfo.parsePositiveDouble(m['total_gb']),
      freeGb: AgentInfo.parsePositiveDouble(m['free_gb']),
      freePct: pFreePct,
      diskModel: (m['disk_model'] ?? m['model'])?.toString().trim() ?? '',
      diskType: (m['disk_type'] ?? m['type'])?.toString().trim() ?? '',
    );
  }
}

/// Per-volume mapping from `hw_health.logical_disk_specs` (drive letter → physical disk).
class LogicalDiskSpec {
  final String id;
  final String diskModel;
  final String diskType;

  const LogicalDiskSpec({
    required this.id,
    required this.diskModel,
    required this.diskType,
  });

  factory LogicalDiskSpec.fromJson(Map<String, dynamic> m) {
    return LogicalDiskSpec(
      id: m['id']?.toString() ?? '',
      diskModel: (m['disk_model'] ?? m['model'])?.toString().trim() ?? '',
      diskType: (m['disk_type'] ?? m['type'])?.toString().trim() ?? '',
    );
  }
}

/// Dashboard device row from `get_all_agents` (alias for IDE/search clarity).
typedef Computer = AgentInfo;

/// Aligns with VPS/SQLite `REPLACE(agent_id,' ','')` + trim for matching SeeDesktop IDs.
String normalizeSeeDesktopId(String raw) {
  return raw.trim().replaceAll(RegExp(r'\s+'), '');
}

class AgentInfo {
  final String agentId;
  final String computerName;
  final String osVersion;
  final String status;
  final String lastSeen;

  /// Unix timestamp in seconds from server (`last_seen_ts`), if provided.
  final double? lastSeenUnix;

  final bool isOnline;

  /// Server-side queued task for this agent (e.g. chkdsk), if any.
  final String? pendingTask;

  /// Last submitted log text from the agent, if any.
  final String? lastLog;

  /// Hardware telemetry strings from last agent heartbeat (server echo).
  final String? cpuUsage;
  final String? ramUsage;
  final String? diskFree;
  final String? smartStatus;

  /// Rich hardware snapshot (temp, fan, disks, CPU id) from agent / server echo.
  final Map<String, dynamic>? hwHealth;

  /// Parsed from [hwHealth] (`cpu_model` from Rust / agent).
  final String? cpuModel;

  /// Total physical RAM in GB (`ram_gb`).
  final double? ramGb;

  /// Populated DIMM slots vs mainboard slots (`ram_slots_used` / `ram_slots_total`).
  final int? ramSlotsUsed;
  final int? ramSlotsTotal;

  /// RAM module speed label from `hw_health` (e.g. `3200MHz`).
  final String? ramSpeed;

  /// RAM generation from `hw_health` (e.g. `DDR4`).
  final String? ramType;

  /// Board usage string from `hw_health` (e.g. `2/4` populated / total slots).
  final String? ramSlotsUsage;

  /// Drives from `hw_health.disk_info`.
  final List<DiskInfo> diskInfo;

  /// Volumes from `hw_health.disks` (includes per-volume `disk_model` / `disk_type`).
  final List<HwHealthDiskVolume> hwVolumes;

  /// Drive → physical disk mapping from `hw_health.logical_disk_specs`.
  final List<LogicalDiskSpec> logicalDiskSpecs;

  AgentInfo({
    required this.agentId,
    required this.computerName,
    required this.osVersion,
    required this.status,
    required this.lastSeen,
    this.lastSeenUnix,
    required this.isOnline,
    this.pendingTask,
    this.lastLog,
    this.cpuUsage,
    this.ramUsage,
    this.diskFree,
    this.smartStatus,
    this.hwHealth,
    this.cpuModel,
    this.ramGb,
    this.ramSlotsUsed,
    this.ramSlotsTotal,
    this.ramSpeed,
    this.ramType,
    this.ramSlotsUsage,
    List<DiskInfo>? diskInfo,
    List<HwHealthDiskVolume>? hwVolumes,
    List<LogicalDiskSpec>? logicalDiskSpecs,
  })  : diskInfo = diskInfo ?? const [],
        hwVolumes = hwVolumes ?? const [],
        logicalDiskSpecs = logicalDiskSpecs ?? const [];

  bool get hasPendingTask {
    final p = pendingTask?.trim() ?? '';
    return p.isNotEmpty && p.toLowerCase() != 'null';
  }

  bool get hasLastLog {
    final l = lastLog?.trim() ?? '';
    return l.isNotEmpty;
  }

  factory AgentInfo.fromJson(Map<String, dynamic> j) {
    final hwHealth = _parseHwHealthMap(j['hw_health']);
    final cpuModel = _nullableString(hwHealth?['cpu_name']) ??
        _nullableString(hwHealth?['cpu_model']) ??
        _nullableString(j['cpu_model']);
    return AgentInfo(
      agentId: normalizeSeeDesktopId(j['agent_id']?.toString() ?? ''),
      computerName: j['computer_name']?.toString() ?? '—',
      osVersion: j['os_version']?.toString() ?? '—',
      status: _normalizeVpsAgentStatus(j['status']),
      lastSeen: _lastSeenDisplayFromJson(j['last_seen']),
      lastSeenUnix: _parseLastSeenUnix(
              j['last_seen_ts'] ?? j['lastSeenTs'] ?? j['last_seen']) ??
          _parseLastSeenUnixFromLoose(j['last_seen']),
      isOnline: _parseIsOnline(j),
      pendingTask: _nullableString(j['pending_task']),
      lastLog: _nullableString(j['last_log']),
      cpuUsage: _nullableString(j['cpu_usage']),
      ramUsage: _nullableString(j['ram_usage']),
      diskFree: _nullableString(j['disk_free']),
      smartStatus:
          _nullableString(j['smart_status']) ?? _nullableString(j['smart']),
      hwHealth: hwHealth,
      cpuModel: cpuModel,
      ramGb: _parsePositiveDouble(j['ram_gb']) ??
          _parsePositiveDouble(hwHealth?['ram_gb']),
      ramSlotsUsed: _parseNonNegativeInt(hwHealth?['ram_slots_used']),
      ramSlotsTotal: _parseNonNegativeInt(hwHealth?['ram_slots_total']),
      ramSpeed: _nullableString(hwHealth?['ram_speed']),
      ramType: _nullableString(hwHealth?['ram_type']),
      ramSlotsUsage: _nullableString(j['ram_slots']) ??
          _nullableString(hwHealth?['ram_slots_usage']),
      diskInfo: () {
        final fromH = _parseDiskInfoList(hwHealth?['disk_info']);
        if (fromH.isNotEmpty) return fromH;
        return _parseDiskInfoList(j['disk_info']);
      }(),
      hwVolumes: _parseHwVolumesList(hwHealth?['disks']),
      logicalDiskSpecs:
          _parseLogicalDiskSpecsList(hwHealth?['logical_disk_specs']),
    );
  }

  /// Shared parser for numeric GB fields in `hw_health`.
  static double? parsePositiveDouble(dynamic v) {
    if (v == null) return null;
    final n = v is num ? v.toDouble() : double.tryParse(v.toString().trim());
    if (n == null || !n.isFinite || n < 0) return null;
    return n;
  }

  static double? _parsePositiveDouble(dynamic v) => parsePositiveDouble(v);

  static int? _parseNonNegativeInt(dynamic v) {
    if (v == null) return null;
    final n = v is int ? v : int.tryParse(v.toString().trim());
    if (n == null || n < 0) return null;
    return n;
  }

  static List<DiskInfo> _parseDiskInfoList(dynamic v) {
    if (v is! List) return const [];
    final out = <DiskInfo>[];
    for (final e in v) {
      if (e is Map<String, dynamic>) {
        out.add(DiskInfo.fromJson(e));
      } else if (e is Map) {
        out.add(DiskInfo.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return out;
  }

  static List<HwHealthDiskVolume> _parseHwVolumesList(dynamic v) {
    if (v is! List) return const [];
    final out = <HwHealthDiskVolume>[];
    for (final e in v) {
      if (e is Map<String, dynamic>) {
        out.add(HwHealthDiskVolume.fromJson(e));
      } else if (e is Map) {
        out.add(HwHealthDiskVolume.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return out;
  }

  static List<LogicalDiskSpec> _parseLogicalDiskSpecsList(dynamic v) {
    if (v is! List) return const [];
    final out = <LogicalDiskSpec>[];
    for (final e in v) {
      if (e is Map<String, dynamic>) {
        out.add(LogicalDiskSpec.fromJson(e));
      } else if (e is Map) {
        out.add(LogicalDiskSpec.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return out;
  }

  static Map<String, dynamic>? _parseHwHealthMap(dynamic v) {
    if (v == null) return null;
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  /// Aligns with VPS: `is_online` is derived from `last_seen` window; when the key is
  /// present it wins. Otherwise fall back to `status` (online / in_session / offline).
  static bool _parseIsOnline(Map<String, dynamic> j) {
    final io = j['is_online'];
    if (io is bool) return io;
    if (io is num) return io != 0;
    final ios = io?.toString().trim().toLowerCase();
    if (ios == 'true' || ios == '1' || ios == 'yes') return true;
    if (ios == 'false' || ios == '0' || ios == 'no') return false;

    final s = j['status']?.toString().trim().toLowerCase() ?? '';
    if (s.isEmpty) return false;
    return s == 'online' || s == 'in_session';
  }

  static String _normalizeVpsAgentStatus(dynamic v) {
    final s = v?.toString().trim() ?? '';
    if (s.isEmpty || s.toLowerCase() == 'null') return 'offline';
    return s;
  }

  static String _lastSeenDisplayFromJson(dynamic v) {
    if (v == null) return '—';
    if (v is num) {
      if (v > 1e12) return (v.toDouble() / 1000.0).toString();
      return v.toString();
    }
    final s = v.toString().trim();
    return s.isEmpty ? '—' : s;
  }

  static String? _nullableString(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return null;
    return s;
  }

  static double? _parseLastSeenUnix(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }

  /// When the API puts Unix seconds in `last_seen` instead of `last_seen_ts`.
  static double? _parseLastSeenUnixFromLoose(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s == '—') return null;
    final d = double.tryParse(s);
    if (d == null) return null;
    if (d > 1e12) return d / 1000.0;
    if (d > 1e9) return d;
    return null;
  }
}

/// Live [AgentInfo] for **this** workstation (My Devices top row), using the same
/// payload shape as VPS `get_all_agents` / heartbeat — no server round-trip.
Future<AgentInfo?> buildLocalAgentInfoForMyDevicesTable() async {
  final agentIdRaw = await _resolveNumericAgentIdForHeartbeat();
  final agentId = normalizeSeeDesktopId(agentIdRaw);
  if (agentId.isEmpty) return null;

  String computerName = 'Unknown';
  try {
    final raw = bind.mainGetLoginDeviceInfo();
    if (raw.isNotEmpty) {
      final info = jsonDecode(raw) as Map<String, dynamic>;
      final n = info['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) computerName = n;
    }
  } catch (_) {}

  final osVersion = _heartbeatOsVersionString();
  final outgoingSessions = await getActiveLicenseSessionCount();
  final incomingSessions = await _incomingConnectionManagerClients();
  final activeSessions = outgoingSessions + incomingSessions;
  final status = activeSessions > 0 ? 'in_session' : 'online';

  final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
  final bodyMap = <String, dynamic>{
    'agent_id': agentId,
    'computer_name': computerName,
    'os_version': osVersion,
    'status': status,
    'is_online': true,
    'last_seen_ts': nowSec,
  };

  try {
    final metrics =
        jsonDecode(bind.mainGetSysMetrics()) as Map<String, dynamic>;
    applyHeartbeatFlatTelemetryFromSysMetrics(bodyMap, metrics);
  } catch (_) {
    bodyMap['cpu_usage'] = '—';
    bodyMap['ram_usage'] = '—';
    bodyMap['disk_free'] = '—';
  }

  try {
    final winHw = await collectHardwareTelemetryForHeartbeat();
    final sm = winHw['smart_status']?.trim() ?? '';
    if (sm.isNotEmpty && sm != 'N/A' && sm.toLowerCase() != 'unknown') {
      bodyMap['smart_status'] = sm;
    }
  } catch (_) {}

  return AgentInfo.fromJson(bodyMap);
}

/// POST /api/set_agent_task — queue a remote task for an agent (admin).
Future<void> setAgentTaskRemote({
  required String agentId,
  required String taskName,
}) async {
  final headers = <String, String>{
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $kVpsAdminBearerKey',
  };
  final body = jsonEncode({
    'agent_id': agentId,
    'task_name': taskName,
  });
  final resp = await LicenseApiRouter.post(
    Uri.parse(kSetAgentTaskEndpoint),
    headers: headers,
    body: body,
    requestTimeout: const Duration(seconds: 25),
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('set_agent_task ${resp.statusCode}: ${resp.body}');
  }
}

/// POST /api/queue_command — enqueue a shell/command for an agent (admin).
Future<void> queueCommandRemote({
  required String agentId,
  required String command,
}) async {
  final headers = <String, String>{
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $kVpsAdminBearerKey',
  };
  final body = jsonEncode({
    'agent_id': agentId,
    'command': command,
  });
  final resp = await LicenseApiRouter.post(
    Uri.parse(kQueueCommandEndpoint),
    headers: headers,
    body: body,
    requestTimeout: const Duration(seconds: 25),
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('queue_command ${resp.statusCode}: ${resp.body}');
  }
}

// ---------------------------------------------------------------------------
// Fetch helper
// ---------------------------------------------------------------------------

/// Peer IDs for VPS `requested_ids`, normalized like license/RMM tracking:
/// this workstation, **all** recent peers (including [Peers.restPeerIds] from deferred Windows batch load),
/// Address Book, **Device group** (hbbs accessible peers), and LAN — so RMM matches the server-side
/// device list, not only IDs that appear in Recent/Favorites locally.
Future<List<String>> buildRequestedIdsForAgentPull() async {
  try {
    await bind.mainLoadRecentPeers();
  } catch (_) {}

  try {
    if (gFFI.lanPeersModel.peers.isEmpty) {
      await bind.mainLoadLanPeers();
    }
  } catch (_) {}

  final ids = <String>{};

  void addRaw(String raw) {
    final n = normalizePeerIdForLicenseTracking(raw);
    if (n.isNotEmpty) ids.add(n);
  }

  try {
    addRaw((await bind.mainGetMyId()).trim());
  } catch (_) {}

  // Full recent list from disk (same source as AB) — avoids Flutter model lag after load_recent_peers.
  try {
    final peersJson = await bind.mainLoadRecentPeersForAb(filter: '[]');
    if (peersJson.isNotEmpty) {
      final list = jsonDecode(peersJson) as List<dynamic>?;
      if (list != null) {
        for (final e in list) {
          if (e is Map) {
            final id = e['id']?.toString();
            if (id != null && id.isNotEmpty) addRaw(id);
          }
        }
      }
    }
  } catch (_) {}

  try {
    final favs = await bind.mainGetFav();
    for (final id in favs) {
      addRaw(id);
    }
  } catch (_) {}

  try {
    for (final p in gFFI.recentPeersModel.peers) {
      addRaw(p.id);
    }
  } catch (_) {}

  try {
    for (final id in gFFI.recentPeersModel.restPeerIds) {
      addRaw(id);
    }
  } catch (_) {}

  try {
    for (final p in gFFI.abModel.allPeers()) {
      addRaw(p.id);
    }
  } catch (_) {}

  try {
    // Same list as the Group tab (hbbs). Ensures `requested_ids` includes devices that are not in Recent/AB.
    await gFFI.groupModel.pull(force: false, quiet: true);
    for (final p in gFFI.groupModel.peers) {
      addRaw(p.id);
    }
  } catch (_) {}

  try {
    for (final p in gFFI.lanPeersModel.peers) {
      addRaw(p.id);
    }
  } catch (_) {}

  final list = ids.toList()..sort();
  return list;
}

/// Align with VPS chunking (~800 placeholders per query after owner_license bind).
const int _kGetAllAgentsRequestedIdsBatchSize = 800;

/// Single POST /api/get_all_agents (see VPS: `remoteAgents` or `agents`, Unix `last_seen` / `last_seen_ts`).
Future<List<AgentInfo>> _fetchAllAgentsPost(
  String licenseKey,
  List<String> requestedIds,
) async {
  final headers = <String, String>{
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $kVpsAdminBearerKey',
  };

  final resp = await LicenseApiRouter.post(
    Uri.parse(kGetAllAgentsEndpoint),
    headers: headers,
    body: jsonEncode({
      'license_key': licenseKey,
      'requested_ids': requestedIds,
    }),
    requestTimeout: const Duration(seconds: 25),
  );

  if (resp.statusCode == 401) {
    throw Exception(
      'get_all_agents 401: VPS דחה את Bearer — ודא ש־kVpsAdminBearerKey תואם ל־API_KEY בשרת.',
    );
  }
  if (resp.statusCode == 400) {
    throw Exception(
      'get_all_agents 400 (חסר license_key או גוף לא תקין): ${resp.body}',
    );
  }
  if (resp.statusCode != 200) {
    throw Exception('Server ${resp.statusCode}: ${resp.body}');
  }

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final raw = data['remoteAgents'] as List<dynamic>? ??
      data['agents'] as List<dynamic>? ??
      [];
  return raw.map((e) => AgentInfo.fromJson(e as Map<String, dynamic>)).toList();
}

/// POST /api/get_all_agents — Bearer חובה; `license_key` חובה כש־[requestedIds] לא ריק (VPS).
/// רישיון לא תקף → 200 ו־agents ריק (לא שגיאה). מפצל בקשות גדולות ל־800 מזהים.
Future<List<AgentInfo>> fetchAllAgents() async {
  final licenseKey = (await getSavedLicenseKey())?.trim() ?? '';
  final requestedIds = await buildRequestedIdsForAgentPull();

  if (requestedIds.isNotEmpty && licenseKey.isEmpty) {
    throw Exception(
      'get_all_agents: נדרש license_key כשיש requested_ids. הזן/הפעל רישיון SeeDesktop תקף.',
    );
  }

  if (requestedIds.isEmpty) {
    return _fetchAllAgentsPost(licenseKey, []);
  }
  if (requestedIds.length <= _kGetAllAgentsRequestedIdsBatchSize) {
    return _fetchAllAgentsPost(licenseKey, requestedIds);
  }

  final byNorm = <String, AgentInfo>{};
  for (var i = 0;
      i < requestedIds.length;
      i += _kGetAllAgentsRequestedIdsBatchSize) {
    final end = i + _kGetAllAgentsRequestedIdsBatchSize;
    final chunk = requestedIds.sublist(
        i, end > requestedIds.length ? requestedIds.length : end);
    final part = await _fetchAllAgentsPost(licenseKey, chunk);
    for (final a in part) {
      var k = normalizePeerIdForLicenseTracking(a.agentId);
      if (k.isEmpty) k = normalizeSeeDesktopId(a.agentId);
      if (k.isEmpty) k = a.agentId.trim();
      if (k.isNotEmpty) {
        byNorm[k] = a;
      }
    }
  }
  return byNorm.values.toList();
}

/// VPS [fetchAllAgents] plus one [AgentInfo] per id from [buildRequestedIdsForAgentPull]
/// that the server omitted (e.g. license caps), using local peer files for display name.
///
/// This keeps **המכשירים שלי** aligned with Recent / AB / Group coverage instead of only VPS row count.
Future<List<AgentInfo>> fetchAllAgentsForMyDevicesTable() async {
  final vps = await fetchAllAgents();
  final byKey = <String, AgentInfo>{};

  void put(AgentInfo a) {
    var k = normalizePeerIdForLicenseTracking(a.agentId);
    if (k.isEmpty) k = normalizeSeeDesktopId(a.agentId);
    if (k.isEmpty) k = a.agentId.trim();
    if (k.isNotEmpty) {
      byKey[k] = a;
    }
  }

  for (final a in vps) {
    put(a);
  }

  final requested = await buildRequestedIdsForAgentPull();
  for (final normId in requested) {
    if (byKey.containsKey(normId)) continue;
    byKey[normId] = buildAgentInfoPlaceholderForKnownPeer(normId);
  }

  return byKey.values.toList();
}

/// Local-only row when the peer is known (Recent/disk) but missing from `get_all_agents`.
AgentInfo buildAgentInfoPlaceholderForKnownPeer(String normalizedPeerId) {
  var computerName = normalizedPeerId;
  var displayId = normalizedPeerId;
  try {
    final raw = bind.mainGetPeerSync(id: normalizedPeerId).trim();
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final m = Map<String, dynamic>.from(decoded);
        final opts = m['options'];
        var alias = '';
        if (opts is Map) {
          alias = (opts['alias'] ?? opts['Alias'])?.toString().trim() ?? '';
        }
        final info = m['info'];
        var hostname = '';
        var username = '';
        if (info is Map) {
          final im = Map<String, dynamic>.from(info);
          hostname = im['hostname']?.toString().trim() ?? '';
          username = im['username']?.toString().trim() ?? '';
        }
        if (alias.isNotEmpty) {
          computerName = alias;
        } else if (hostname.isNotEmpty) {
          computerName = hostname;
        } else if (username.isNotEmpty) {
          computerName = username;
        }
      }
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint(
          'buildAgentInfoPlaceholderForKnownPeer($normalizedPeerId): $e');
    }
  }

  return AgentInfo(
    agentId: displayId,
    computerName: computerName.isNotEmpty ? computerName : normalizedPeerId,
    osVersion: '—',
    status: 'offline',
    lastSeen: '—',
    isOnline: false,
  );
}

/// Minimal [AgentInfo] when this PC is not yet in the VPS heartbeat list.
Future<AgentInfo> buildLocalAgentPlaceholder() async {
  final agentId = (await bind.mainGetMyId()).trim();
  var computerName = 'מחשב זה';
  try {
    final raw = bind.mainGetLoginDeviceInfo();
    if (raw.isNotEmpty) {
      final info = jsonDecode(raw) as Map<String, dynamic>;
      final n = info['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) computerName = n;
    }
  } catch (_) {}
  return AgentInfo(
    agentId: agentId.isEmpty ? '—' : agentId,
    computerName: computerName,
    osVersion: '—',
    status: 'online',
    lastSeen: '—',
    isOnline: true,
  );
}

/// Local workstation row from [fetchAllAgents] — same telemetry as My Devices (agent heartbeat).
Future<AgentInfo?> fetchThisMachineAgentInfo() async {
  final myId = (await bind.mainGetMyId()).trim();
  if (myId.isEmpty) return null;
  final norm = normalizePeerIdForLicenseTracking(myId);
  if (norm.isEmpty) return null;
  final agents = await fetchAllAgents();
  for (final a in agents) {
    if (normalizePeerIdForLicenseTracking(a.agentId) == norm) return a;
  }
  return null;
}
