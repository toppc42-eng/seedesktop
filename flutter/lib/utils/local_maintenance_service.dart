import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Directory, File, Platform, Process, ProcessStartMode, SocketException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'local_maintenance_ps_scripts.dart';

/// When to run scheduled cleanup (non–run-now modes register a Windows task).
enum CleanupScheduleMode {
  runNow,
  daily,
  weekly,
  monthly,
}

/// Options for the Advanced System Cleaner (Windows, PowerShell script file).
class LocalMaintenanceCleanOptions {
  // Group 1 — קבצים זמניים ומטמון כללי
  final bool userTemp;
  final bool windowsTemp;
  final bool inetCache;
  final bool explorerCache;
  final bool recycleBin;

  // Group 2 — עדכונים ושירותים
  final bool dnsCache;
  final bool wer;
  final bool deliveryOptimization;
  final bool directXShader;
  final bool windowsLogs;
  final bool winSxS;
  final bool microsoftStoreCache;
  final bool windowsBt;
  final bool prefetch;

  // Group 3 — דפדפנים
  final bool chromeCache;
  final bool edgeCache;
  final bool firefoxCache;
  final bool cookiesLocalStorage;
  final bool historyDb;

  // Group 4 — אפליקציות
  final bool spotifyCache;
  final bool teamsCache;
  final bool oneDriveCache;
  final bool discordCache;

  const LocalMaintenanceCleanOptions({
    this.userTemp = true,
    this.windowsTemp = true,
    this.inetCache = true,
    this.explorerCache = true,
    this.recycleBin = false,
    this.dnsCache = true,
    this.wer = true,
    this.deliveryOptimization = false,
    this.directXShader = true,
    this.windowsLogs = false,
    this.winSxS = false,
    this.microsoftStoreCache = false,
    this.windowsBt = false,
    this.prefetch = false,
    this.chromeCache = false,
    this.edgeCache = false,
    this.firefoxCache = false,
    this.cookiesLocalStorage = false,
    this.historyDb = false,
    this.spotifyCache = false,
    this.teamsCache = false,
    this.oneDriveCache = false,
    this.discordCache = false,
  });

  bool get hasAnySelected =>
      userTemp ||
      windowsTemp ||
      inetCache ||
      explorerCache ||
      recycleBin ||
      dnsCache ||
      wer ||
      deliveryOptimization ||
      directXShader ||
      windowsLogs ||
      winSxS ||
      microsoftStoreCache ||
      windowsBt ||
      prefetch ||
      chromeCache ||
      edgeCache ||
      firefoxCache ||
      cookiesLocalStorage ||
      historyDb ||
      spotifyCache ||
      teamsCache ||
      oneDriveCache ||
      discordCache;

  Map<String, dynamic> toJson() => {
        'userTemp': userTemp,
        'windowsTemp': windowsTemp,
        'inetCache': inetCache,
        'explorerCache': explorerCache,
        'recycleBin': recycleBin,
        'dnsCache': dnsCache,
        'wer': wer,
        'deliveryOptimization': deliveryOptimization,
        'directXShader': directXShader,
        'windowsLogs': windowsLogs,
        'winSxS': winSxS,
        'microsoftStoreCache': microsoftStoreCache,
        'windowsBt': windowsBt,
        'prefetch': prefetch,
        'chromeCache': chromeCache,
        'edgeCache': edgeCache,
        'firefoxCache': firefoxCache,
        'cookiesLocalStorage': cookiesLocalStorage,
        'historyDb': historyDb,
        'spotifyCache': spotifyCache,
        'teamsCache': teamsCache,
        'oneDriveCache': oneDriveCache,
        'discordCache': discordCache,
      };

  factory LocalMaintenanceCleanOptions.fromJson(Map<String, dynamic> m) {
    if (m.containsKey('cleanUserTemp') && !m.containsKey('userTemp')) {
      return LocalMaintenanceCleanOptions(
        userTemp: m['cleanUserTemp'] as bool? ?? true,
        windowsTemp: m['cleanWinTemp'] as bool? ?? true,
        inetCache: true,
        explorerCache: true,
        recycleBin: m['cleanRecycleBin'] as bool? ?? false,
        dnsCache: m['cleanDnsCache'] as bool? ?? true,
        wer: true,
        deliveryOptimization: false,
        directXShader: true,
        windowsLogs: false,
        winSxS: false,
        microsoftStoreCache: false,
        windowsBt: false,
        prefetch: false,
        chromeCache: m['cleanChrome'] as bool? ?? false,
        edgeCache: m['cleanEdge'] as bool? ?? false,
        firefoxCache: false,
        cookiesLocalStorage: false,
        historyDb: false,
        spotifyCache: false,
        teamsCache: false,
        oneDriveCache: false,
        discordCache: false,
      );
    }
    bool b(String k, bool d) => m[k] is bool ? m[k] as bool : d;
    return LocalMaintenanceCleanOptions(
      userTemp: b('userTemp', true),
      windowsTemp: b('windowsTemp', true),
      inetCache: b('inetCache', true),
      explorerCache: b('explorerCache', true),
      recycleBin: b('recycleBin', false),
      dnsCache: b('dnsCache', true),
      wer: b('wer', true),
      deliveryOptimization: b('deliveryOptimization', false),
      directXShader: b('directXShader', true),
      windowsLogs: b('windowsLogs', false),
      winSxS: b('winSxS', false),
      microsoftStoreCache: b('microsoftStoreCache', false),
      windowsBt: b('windowsBt', false),
      prefetch: b('prefetch', false),
      chromeCache: b('chromeCache', false),
      edgeCache: b('edgeCache', false),
      firefoxCache: b('firefoxCache', false),
      cookiesLocalStorage: b('cookiesLocalStorage', false),
      historyDb: b('historyDb', false),
      spotifyCache: b('spotifyCache', false),
      teamsCache: b('teamsCache', false),
      oneDriveCache: b('oneDriveCache', false),
      discordCache: b('discordCache', false),
    );
  }
}

/// Windows Event Log + WMI snapshot for the local maintenance dashboard.
class LocalMaintenanceForensicSnapshot {
  const LocalMaintenanceForensicSnapshot({
    required this.osCaption,
    required this.bsod1001,
    required this.unexpectedShutdown41,
    required this.appError1000,
    required this.topCrashApp,
    required this.failedLogon4625,
  });

  /// e.g. `Microsoft Windows 11 Pro`
  final String osCaption;
  final int bsod1001;
  final int unexpectedShutdown41;
  final int appError1000;
  final String topCrashApp;

  /// `-1` if the Security log is not readable (permissions).
  final int failedLogon4625;

  factory LocalMaintenanceForensicSnapshot.fromJson(Map<String, dynamic> m) {
    int n(String k) => (m[k] as num?)?.round() ?? 0;
    final fl = (m['failed_logon_4625'] as num?)?.round() ?? -1;
    return LocalMaintenanceForensicSnapshot(
      osCaption: m['os_caption']?.toString() ?? '',
      bsod1001: n('bsod_1001'),
      unexpectedShutdown41: n('unexpected_shutdown_41'),
      appError1000: n('app_error_1000'),
      topCrashApp: m['top_crash_app']?.toString() ?? '',
      failedLogon4625: fl,
    );
  }

  Map<String, dynamic> toJson() => {
        'os_caption': osCaption,
        'bsod_1001': bsod1001,
        'unexpected_shutdown_41': unexpectedShutdown41,
        'app_error_1000': appError1000,
        'top_crash_app': topCrashApp,
        'failed_logon_4625': failedLogon4625,
      };
}

/// Windows Experience Index / WinSAT scores (`Win32_WinSAT`).
class LocalMaintenanceWinSatSnapshot {
  const LocalMaintenanceWinSatSnapshot({
    required this.cpuScore,
    required this.d3dScore,
    required this.diskScore,
    required this.graphicsScore,
    required this.memoryScore,
    required this.winSprLevel,
    required this.assessmentState,
    required this.timeTaken,
  });

  final double? cpuScore;
  final double? d3dScore;
  final double? diskScore;
  final double? graphicsScore;
  final double? memoryScore;
  final double? winSprLevel;
  final int assessmentState;
  final String timeTaken;

  double? get effectiveScore {
    if (winSprLevel != null && winSprLevel! > 0) return winSprLevel;
    final scores = <double>[
      if (cpuScore != null && cpuScore! > 0) cpuScore!,
      if (d3dScore != null && d3dScore! > 0) d3dScore!,
      if (diskScore != null && diskScore! > 0) diskScore!,
      if (graphicsScore != null && graphicsScore! > 0) graphicsScore!,
      if (memoryScore != null && memoryScore! > 0) memoryScore!,
    ];
    if (scores.isEmpty) return null;
    scores.sort();
    return scores.first;
  }

  factory LocalMaintenanceWinSatSnapshot.fromJson(Map<String, dynamic> m) {
    double? d(String k) {
      final v = (m[k] as num?)?.toDouble();
      if (v == null || v <= 0) return null;
      return v;
    }

    return LocalMaintenanceWinSatSnapshot(
      cpuScore: d('cpu_score'),
      d3dScore: d('d3d_score'),
      diskScore: d('disk_score'),
      graphicsScore: d('graphics_score'),
      memoryScore: d('memory_score'),
      winSprLevel: d('winspr_level'),
      assessmentState: (m['assessment_state'] as num?)?.round() ?? -1,
      timeTaken: m['time_taken']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'cpu_score': cpuScore,
        'd3d_score': d3dScore,
        'disk_score': diskScore,
        'graphics_score': graphicsScore,
        'memory_score': memoryScore,
        'winspr_level': winSprLevel,
        'assessment_state': assessmentState,
        'time_taken': timeTaken,
      };
}

/// תהליך מוביל לפי CPU (דוח עומס בזמן אמת).
class LocalMaintenanceRealTimeProcCpu {
  const LocalMaintenanceRealTimeProcCpu({
    required this.name,
    required this.id,
    required this.cpu,
  });

  final String name;
  final int id;

  /// ערך `CPU` של `Get-Process` (יחידות זמן מעבד מעוגלות).
  final double cpu;

  factory LocalMaintenanceRealTimeProcCpu.fromMap(Map<String, dynamic> m) {
    return LocalMaintenanceRealTimeProcCpu(
      name: m['Name']?.toString() ?? '',
      id: (m['ID'] as num?)?.round() ?? (m['Id'] as num?)?.round() ?? 0,
      cpu: (m['CPU'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// תהליך מוביל לפי RAM (דוח עומס בזמן אמת).
class LocalMaintenanceRealTimeProcRam {
  const LocalMaintenanceRealTimeProcRam({
    required this.name,
    required this.id,
    required this.ramMb,
  });

  final String name;
  final int id;
  final double ramMb;

  factory LocalMaintenanceRealTimeProcRam.fromMap(Map<String, dynamic> m) {
    return LocalMaintenanceRealTimeProcRam(
      name: m['Name']?.toString() ?? '',
      id: (m['ID'] as num?)?.round() ?? (m['Id'] as num?)?.round() ?? 0,
      ramMb: (m['RAM_MB'] as num?)?.toDouble() ??
          (m['Ram_MB'] as num?)?.toDouble() ??
          0,
    );
  }
}

/// תמונת עומס מערכת (JSON מ־[psRealTimeLoadJson]).
class LocalMaintenanceRealTimeLoad {
  const LocalMaintenanceRealTimeLoad({
    required this.totalCpu,
    required this.totalRamPct,
    required this.uptime,
    required this.topCpu,
    required this.topRam,
    this.swapTotalMb,
    this.swapUsedMb,
  });

  final double? totalCpu;
  final double totalRamPct;
  final String uptime;
  final List<LocalMaintenanceRealTimeProcCpu> topCpu;
  final List<LocalMaintenanceRealTimeProcRam> topRam;

  /// גודל קובץ ההחלפה (MB) לפי WMI; `null` אם לא הוחזר מהסקריפט.
  final double? swapTotalMb;

  /// נפח קובץ ההחלפה בשימוש (MB).
  final double? swapUsedMb;

  factory LocalMaintenanceRealTimeLoad.fromJson(Map<String, dynamic> m) {
    return LocalMaintenanceRealTimeLoad(
      totalCpu: (m['TotalCPU'] as num?)?.toDouble(),
      totalRamPct: (m['TotalRAM'] as num?)?.toDouble() ?? 0,
      uptime: m['Uptime']?.toString() ?? '—',
      topCpu: _parseCpuProcs(m['TopCPU']),
      topRam: _parseRamProcs(m['TopRAM']),
      swapTotalMb: (m['SwapTotalMB'] as num?)?.toDouble(),
      swapUsedMb: (m['SwapUsedMB'] as num?)?.toDouble(),
    );
  }

  static List<LocalMaintenanceRealTimeProcCpu> _parseCpuProcs(dynamic v) {
    if (v == null) return [];
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => LocalMaintenanceRealTimeProcCpu.fromMap(
                Map<String, dynamic>.from(e),
              ))
          .toList();
    }
    if (v is Map) {
      return [
        LocalMaintenanceRealTimeProcCpu.fromMap(Map<String, dynamic>.from(v)),
      ];
    }
    return [];
  }

  static List<LocalMaintenanceRealTimeProcRam> _parseRamProcs(dynamic v) {
    if (v == null) return [];
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => LocalMaintenanceRealTimeProcRam.fromMap(
                Map<String, dynamic>.from(e),
              ))
          .toList();
    }
    if (v is Map) {
      return [
        LocalMaintenanceRealTimeProcRam.fromMap(Map<String, dynamic>.from(v)),
      ];
    }
    return [];
  }
}

/// תוצאת [psNetworkEndpointIpsJson] — IPv4 מקומי ו־IP ציבורי.
class LocalMaintenanceNetworkIps {
  const LocalMaintenanceNetworkIps({
    this.localIpv4,
    this.publicIp,
  });

  final String? localIpv4;
  final String? publicIp;

  factory LocalMaintenanceNetworkIps.fromJson(Map<String, dynamic> m) {
    String? s(dynamic k) {
      final v = m[k]?.toString().trim();
      if (v == null || v.isEmpty) return null;
      return v;
    }

    return LocalMaintenanceNetworkIps(
      localIpv4: s('local_ipv4'),
      publicIp: s('public_ip'),
    );
  }
}

/// שורה מיומן Application (שגיאה).
class LocalMaintenanceAppErrorRow {
  const LocalMaintenanceAppErrorRow({
    required this.time,
    required this.source,
    required this.message,
  });

  final String time;
  final String source;
  final String message;

  factory LocalMaintenanceAppErrorRow.fromMap(Map<String, dynamic> m) {
    return LocalMaintenanceAppErrorRow(
      time: m['Time']?.toString() ?? '',
      source: m['Source']?.toString() ?? '',
      message: m['Message']?.toString() ?? '',
    );
  }
}

/// שורת אירוע כיבוי בלתי צפוי (System / Event ID 41).
class LocalMaintenanceUnexpectedShutdownRow {
  const LocalMaintenanceUnexpectedShutdownRow({
    required this.time,
    required this.provider,
    required this.level,
    required this.message,
  });

  final String time;
  final String provider;
  final String level;
  final String message;

  factory LocalMaintenanceUnexpectedShutdownRow.fromMap(
    Map<String, dynamic> m,
  ) {
    return LocalMaintenanceUnexpectedShutdownRow(
      time: m['Time']?.toString() ?? '',
      provider: m['ProviderName']?.toString() ?? '',
      level: m['LevelDisplayName']?.toString() ?? '',
      message: m['Message']?.toString() ?? '',
    );
  }
}

/// שורת GPU מ־WMI (Win32_VideoController).
class LocalMaintenanceGpuAdapter {
  const LocalMaintenanceGpuAdapter({
    required this.name,
    required this.adapterRamMb,
    required this.driverVersion,
    required this.videoMode,
    required this.status,
    required this.width,
    required this.height,
    required this.refreshHz,
  });

  final String name;
  final int adapterRamMb;
  final String driverVersion;
  final String videoMode;
  final String status;
  final int width;
  final int height;
  final String refreshHz;

  factory LocalMaintenanceGpuAdapter.fromMap(Map<String, dynamic> m) {
    return LocalMaintenanceGpuAdapter(
      name: m['name']?.toString() ?? '—',
      adapterRamMb: (m['adapter_ram_mb'] as num?)?.round() ?? 0,
      driverVersion: m['driver_version']?.toString() ?? '',
      videoMode: m['video_mode']?.toString() ?? '',
      status: m['status']?.toString() ?? '',
      width: (m['width'] as num?)?.round() ?? 0,
      height: (m['height'] as num?)?.round() ?? 0,
      refreshHz: m['refresh_hz']?.toString() ?? '',
    );
  }
}

class LocalMaintenanceDiskPartition {
  const LocalMaintenanceDiskPartition({
    required this.id,
    required this.label,
    required this.totalGb,
    required this.freeGb,
  });

  final String id;
  final String label;
  final double? totalGb;
  final double? freeGb;

  factory LocalMaintenanceDiskPartition.fromMap(Map<String, dynamic> m) {
    return LocalMaintenanceDiskPartition(
      id: m['id']?.toString() ?? '',
      label: m['label']?.toString() ?? '',
      totalGb: (m['total_gb'] as num?)?.toDouble(),
      freeGb: (m['free_gb'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'total_gb': totalGb,
        'free_gb': freeGb,
      };
}

class LocalMaintenancePhysicalDisk {
  const LocalMaintenancePhysicalDisk({
    required this.index,
    required this.model,
    required this.diskType,
    required this.busType,
    required this.port,
    required this.smartStatus,
    required this.partitions,
  });

  final int index;
  final String model;
  final String diskType;
  final String busType;
  final String port;
  final String smartStatus;
  final List<LocalMaintenanceDiskPartition> partitions;

  factory LocalMaintenancePhysicalDisk.fromMap(Map<String, dynamic> m) {
    final parts = <LocalMaintenanceDiskPartition>[];
    final rawParts = m['partitions'];
    if (rawParts is List) {
      for (final x in rawParts) {
        if (x is! Map) continue;
        parts.add(LocalMaintenanceDiskPartition.fromMap(
          Map<String, dynamic>.from(x),
        ));
      }
    }
    return LocalMaintenancePhysicalDisk(
      index: (m['index'] as num?)?.round() ?? 0,
      model: m['model']?.toString() ?? '',
      diskType: m['disk_type']?.toString() ?? '',
      busType: m['bus_type']?.toString() ?? '',
      port: m['port']?.toString() ?? '',
      smartStatus: m['smart_status']?.toString() ?? '',
      partitions: parts,
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'model': model,
        'disk_type': diskType,
        'bus_type': busType,
        'port': port,
        'smart_status': smartStatus,
        'partitions': partitions.map((p) => p.toJson()).toList(),
      };
}

/// Extended WMI / SecurityCenter audit for dashboard cards (single PS JSON fetch).
class LocalMaintenanceAuditSnapshot {
  const LocalMaintenanceAuditSnapshot({
    required this.ramSlots,
    required this.primaryMac,
    required this.netUpCount,
    required this.arpNeighbors,
    required this.antivirusName,
    required this.localUsersActive,
    required this.localUsers,
    required this.computerName,
    required this.logonUser,
    required this.motherboard,
    required this.biosVersion,
    required this.usbControllerCount,
    required this.usbHubCount,
    required this.storageControllerMode,
    required this.secureBoot,
    required this.osLicense,
    required this.officeProducts,
    required this.microsoftProducts,
    required this.audioDevices,
    required this.primaryGpu,
    required this.gpuAdapters,
    required this.physicalDisks,
    required this.printers,
    required this.usbStorageRecent,
  });

  factory LocalMaintenanceAuditSnapshot.empty() =>
      const LocalMaintenanceAuditSnapshot(
        ramSlots: [],
        primaryMac: '',
        netUpCount: 0,
        arpNeighbors: [],
        antivirusName: '',
        localUsersActive: 0,
        localUsers: [],
        computerName: '',
        logonUser: '',
        motherboard: '',
        biosVersion: '',
        usbControllerCount: 0,
        usbHubCount: 0,
        storageControllerMode: '',
        secureBoot: 'Unknown',
        osLicense: '',
        officeProducts: [],
        microsoftProducts: [],
        audioDevices: [],
        primaryGpu: '',
        gpuAdapters: [],
        physicalDisks: [],
        printers: [],
        usbStorageRecent: [],
      );

  final List<({String label, int capacityMb})> ramSlots;
  final String primaryMac;
  final int netUpCount;
  final List<({String ip, String name, String mac})> arpNeighbors;
  final String antivirusName;
  final int localUsersActive;
  final List<({String name, String lastLogon, bool enabled})> localUsers;
  final String computerName;
  final String logonUser;
  final String motherboard;
  final String biosVersion;
  final int usbControllerCount;
  final int usbHubCount;
  final String storageControllerMode;

  /// `On` | `Off` | `Unknown`
  final String secureBoot;
  final String osLicense;
  final List<String> officeProducts;
  final List<String> microsoftProducts;
  final List<String> audioDevices;
  final String primaryGpu;
  final List<LocalMaintenanceGpuAdapter> gpuAdapters;
  final List<LocalMaintenancePhysicalDisk> physicalDisks;
  final List<({String name, String port})> printers;
  final List<String> usbStorageRecent;

  factory LocalMaintenanceAuditSnapshot.fromJson(Map<String, dynamic> m) {
    List<({String label, int capacityMb})> slots = [];
    final rs = m['ram_slots'];
    if (rs is List) {
      for (final x in rs) {
        if (x is! Map) continue;
        final xm = Map<String, dynamic>.from(x);
        slots.add((
          label: xm['label']?.toString() ?? '',
          capacityMb: (xm['capacity_mb'] as num?)?.round() ?? 0,
        ));
      }
    }
    List<({String ip, String name, String mac})> arp = [];
    final an = m['arp_neighbors'];
    if (an is List) {
      for (final x in an) {
        if (x is! Map) continue;
        final xm = Map<String, dynamic>.from(x);
        arp.add((
          ip: xm['ip']?.toString() ?? '',
          name: xm['name']?.toString() ?? '',
          mac: xm['mac']?.toString() ?? '',
        ));
      }
    }
    List<({String name, String lastLogon, bool enabled})> users = [];
    final lu = m['local_users'];
    if (lu is List) {
      for (final x in lu) {
        if (x is! Map) continue;
        final xm = Map<String, dynamic>.from(x);
        users.add((
          name: xm['name']?.toString() ?? '',
          lastLogon: xm['last_logon']?.toString() ?? '',
          enabled: xm['enabled'] as bool? ?? true,
        ));
      }
    }
    List<({String name, String port})> pr = [];
    final prs = m['printers'];
    if (prs is List) {
      for (final x in prs) {
        if (x is! Map) continue;
        final xm = Map<String, dynamic>.from(x);
        pr.add((
          name: xm['name']?.toString() ?? '',
          port: xm['port']?.toString() ?? '',
        ));
      }
    }
    List<String> usb = [];
    final us = m['usb_storage_recent'];
    if (us is List) {
      for (final x in us) {
        final s = x?.toString() ?? '';
        if (s.isNotEmpty) usb.add(s);
      }
    }
    final gpuList = <LocalMaintenanceGpuAdapter>[];
    final ga = m['gpu_adapters'];
    if (ga is List) {
      for (final x in ga) {
        if (x is! Map) continue;
        gpuList.add(
          LocalMaintenanceGpuAdapter.fromMap(Map<String, dynamic>.from(x)),
        );
      }
    }
    final officeProducts = <String>[];
    final op = m['office_products'];
    if (op is List) {
      for (final x in op) {
        final s = x?.toString().trim() ?? '';
        if (s.isNotEmpty) officeProducts.add(s);
      }
    }
    final microsoftProducts = <String>[];
    final mp = m['microsoft_products'];
    if (mp is List) {
      for (final x in mp) {
        final s = x?.toString().trim() ?? '';
        if (s.isNotEmpty) microsoftProducts.add(s);
      }
    }
    final audioDevices = <String>[];
    final ad = m['audio_devices'];
    if (ad is List) {
      for (final x in ad) {
        final s = x?.toString().trim() ?? '';
        if (s.isNotEmpty) audioDevices.add(s);
      }
    }
    final physicalDisks = <LocalMaintenancePhysicalDisk>[];
    final pd = m['physical_disks'];
    if (pd is List) {
      for (final x in pd) {
        if (x is! Map) continue;
        physicalDisks.add(LocalMaintenancePhysicalDisk.fromMap(
          Map<String, dynamic>.from(x),
        ));
      }
    }
    return LocalMaintenanceAuditSnapshot(
      ramSlots: slots,
      primaryMac: m['primary_mac']?.toString() ?? '',
      netUpCount: (m['net_up_count'] as num?)?.round() ?? 0,
      arpNeighbors: arp,
      antivirusName: m['antivirus']?.toString() ?? '',
      localUsersActive: (m['local_users_active'] as num?)?.round() ?? 0,
      localUsers: users,
      computerName: m['computer_name']?.toString() ?? '',
      logonUser: m['logon_user']?.toString() ?? '',
      motherboard: m['motherboard']?.toString() ?? '',
      biosVersion: m['bios_version']?.toString() ?? '',
      usbControllerCount: (m['usb_controller_count'] as num?)?.round() ?? 0,
      usbHubCount: (m['usb_hub_count'] as num?)?.round() ?? 0,
      storageControllerMode: m['storage_controller_mode']?.toString() ?? '',
      secureBoot: m['secure_boot']?.toString() ?? 'Unknown',
      osLicense: m['os_license']?.toString() ?? '',
      officeProducts: officeProducts,
      microsoftProducts: microsoftProducts,
      audioDevices: audioDevices,
      primaryGpu: m['primary_gpu']?.toString() ?? '',
      gpuAdapters: gpuList,
      physicalDisks: physicalDisks,
      printers: pr,
      usbStorageRecent: usb,
    );
  }

  Map<String, dynamic> toJson() => {
        'ram_slots': ramSlots
            .map(
              (s) => {
                'label': s.label,
                'capacity_mb': s.capacityMb,
              },
            )
            .toList(),
        'primary_mac': primaryMac,
        'net_up_count': netUpCount,
        'arp_neighbors': arpNeighbors
            .map(
              (a) => {
                'ip': a.ip,
                'name': a.name,
                'mac': a.mac,
              },
            )
            .toList(),
        'antivirus': antivirusName,
        'local_users_active': localUsersActive,
        'local_users': localUsers
            .map(
              (u) => {
                'name': u.name,
                'last_logon': u.lastLogon,
                'enabled': u.enabled,
              },
            )
            .toList(),
        'computer_name': computerName,
        'logon_user': logonUser,
        'motherboard': motherboard,
        'bios_version': biosVersion,
        'usb_controller_count': usbControllerCount,
        'usb_hub_count': usbHubCount,
        'storage_controller_mode': storageControllerMode,
        'secure_boot': secureBoot,
        'os_license': osLicense,
        'office_products': officeProducts,
        'microsoft_products': microsoftProducts,
        'audio_devices': audioDevices,
        'primary_gpu': primaryGpu,
        'gpu_adapters': gpuAdapters
            .map(
              (g) => {
                'name': g.name,
                'adapter_ram_mb': g.adapterRamMb,
                'driver_version': g.driverVersion,
                'video_mode': g.videoMode,
                'status': g.status,
                'width': g.width,
                'height': g.height,
                'refresh_hz': g.refreshHz,
              },
            )
            .toList(),
        'physical_disks': physicalDisks.map((d) => d.toJson()).toList(),
        'printers': printers
            .map(
              (p) => {
                'name': p.name,
                'port': p.port,
              },
            )
            .toList(),
        'usb_storage_recent': usbStorageRecent,
      };
}

/// Result of one admin-IPC invocation (stdout/stderr from JSON body).
class _AdminIpcResult {
  _AdminIpcResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.rawBody,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
  final String rawBody;

  String get combinedOutput {
    final parts = [stdout, stderr].where((s) => s.trim().isNotEmpty).toList();
    return parts.join('\n');
  }
}

/// Builds and runs cleanup scripts on Windows.
///
/// **Architecture:** Dashboard **data** uses [_fetchDataSilently] (IPC, then local
/// PowerShell **without** UAC). Explicit **user actions** use [_executeActionWithUAC]
/// (IPC, then UAC `RunAs` fallback) — never from timers/polling.
class LocalMaintenanceService {
  LocalMaintenanceService._();

  static const _scheduledScriptName = 'SeeDesktop_scheduled_cleanup.ps1';

  /// Sentinel [stdout] from [_fetchDataSilently] local fallback when elevation is
  /// required but must not prompt (dashboard polling). UI should show a muted warning.
  static const String kErrorRequiresAdmin = 'ERROR_REQUIRES_ADMIN';

  /// Returns true if [e] was thrown because [_fetchDataSilently] reported
  /// [kErrorRequiresAdmin] (IPC down + local PS denied / insufficient rights).
  static bool isRequiresAdminDataError(Object e) =>
      e.toString().contains(kErrorRequiresAdmin);

  /// One-shot hint for UI: show a generic SnackBar after a successful UAC fallback
  /// on an **explicit user action** ([_executeActionWithUAC] only).
  static bool _pendingUacFallbackUiHint = false;

  /// Returns and clears [true] if the last successful admin script ran via UAC
  /// fallback (IPC was unavailable). Call from UI after `await` user actions only.
  static bool takePendingUacFallbackCompletionHint() {
    final v = _pendingUacFallbackUiHint;
    _pendingUacFallbackUiHint = false;
    return v;
  }

  /// Serialize UAC prompts so parallel IPC failures do not stack multiple elevation dialogs.
  static Future<void> _uacFallbackQueue = Future<void>.value();

  static String _psSingleQuotedPath(String absolutePath) {
    return "'${absolutePath.replaceAll("'", "''")}'";
  }

  /// Runs [trimmed] elevated, captures child stdout/stderr to a temp file, returns parsed result.
  static Future<_AdminIpcResult> _runPowershellViaUacFallbackImpl(
    String trimmed,
  ) async {
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final userPath = p.join(tmp.path, 'seedesk_uac_$stamp.ps1');
    final outPath = p.join(tmp.path, 'seedesk_uac_${stamp}_out.txt');
    final helperPath = p.join(tmp.path, 'seedesk_uac_${stamp}_elev.ps1');

    await File(userPath).writeAsString(trimmed, encoding: utf8);

    final uLit = _psSingleQuotedPath(userPath);
    final oLit = _psSingleQuotedPath(outPath);
    final helper = StringBuffer()
      ..writeln(r"$ErrorActionPreference = 'Continue'")
      ..writeln(r'$u = ' + uLit)
      ..writeln(r'$o = ' + oLit)
      ..writeln(
        r'$output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $u 2>&1',
      )
      ..writeln(r'$code = $LASTEXITCODE')
      ..writeln(r'$output | Set-Content -LiteralPath $o -Encoding UTF8')
      ..writeln(r'exit $code');

    await File(helperPath).writeAsString(helper.toString(), encoding: utf8);

    final hLit = _psSingleQuotedPath(helperPath);
    final startCmd =
        "Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$hLit -Verb RunAs -Wait";

    final pr = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', startCmd],
    );

    try {
      await File(userPath).delete();
      await File(helperPath).delete();
    } catch (_) {}

    final errLauncher = pr.stderr.toString().trim();
    final outLauncher = pr.stdout.toString().trim();
    if (pr.exitCode != 0 && errLauncher.isNotEmpty) {
      debugPrint('UAC launcher stderr: $errLauncher');
    }

    final outFile = File(outPath);
    if (!await outFile.exists()) {
      throw StateError(
        'UAC fallback: no output (elevation cancelled or failed). '
        'exit=${pr.exitCode} out=$outLauncher err=$errLauncher',
      );
    }
    final text = await outFile.readAsString(encoding: utf8);
    try {
      await outFile.delete();
    } catch (_) {}

    return _AdminIpcResult(
      stdout: text,
      stderr: '',
      exitCode: pr.exitCode,
      rawBody: '',
    );
  }

  static Future<_AdminIpcResult> _runPowershellViaUacFallback(String trimmed) {
    final completer = Completer<_AdminIpcResult>();
    _uacFallbackQueue = _uacFallbackQueue.then((_) async {
      try {
        final r = await _runPowershellViaUacFallbackImpl(trimmed);
        if (!completer.isCompleted) completer.complete(r);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// CMD argument quoting for schtasks batch lines.
  static String _cmdQuote(String s) {
    if (!s.contains(' ') && !s.contains('"') && !s.contains('\t')) {
      return s;
    }
    return '"${s.replaceAll('"', '""')}"';
  }

  static String _schtasksBatchLine(List<String> args) {
    final parts = <String>[r'%SystemRoot%\System32\schtasks.exe'];
    for (final a in args) {
      parts.add(_cmdQuote(a));
    }
    return parts.join(' ');
  }

  /// Elevates a CMD batch via PowerShell [Start-Process -Verb RunAs -Wait].
  ///
  /// PowerShell is used ONLY as the UAC launcher for cmd.exe.
  /// The actual schtasks commands run inside cmd.exe via the batch file.
  /// Using -Wait means PowerShell blocks until cmd.exe finishes — no polling
  /// needed, and the job file can be safely deleted afterwards.
  static Future<_AdminIpcResult> _runCmdBatViaUacFallbackImpl(
    String batchBody,
  ) async {
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final jobPath = p.join(tmp.path, 'seedesk_cmd_$stamp.cmd');
    final psPath = p.join(tmp.path, 'seedesk_cmd_${stamp}_elev.ps1');
    final outPath = p.join(tmp.path, 'seedesk_cmd_${stamp}_out.txt');

    // Flat batch: %SEEDESK_OUT% is set by this wrapper, body appends to it.
    // EXITCODE is always written last so the caller can detect success/failure.
    final outQ = outPath.replaceAll('"', '""');
    final jobContent = StringBuffer()
      ..writeln('@echo off')
      ..writeln('setlocal EnableExtensions')
      ..writeln('set "SEEDESK_OUT=$outQ"')
      ..writeln(batchBody.trim())
      ..writeln('set "SEEDESK_RC=%ERRORLEVEL%"')
      ..writeln('echo EXITCODE=%SEEDESK_RC%>>"%SEEDESK_OUT%"')
      ..writeln('exit /b %SEEDESK_RC%');

    await File(jobPath).writeAsString(jobContent.toString(), encoding: utf8);

    // PS1: Start-Process cmd.exe -Verb RunAs -Wait.
    // UAC dialog is shown by Windows; -Wait blocks PS until cmd.exe exits.
    // catch{exit 1} handles UAC cancellation (Win32Exception).
    final jobPS = jobPath.replaceAll("'", "''");
    final psContent = "\$j = '$jobPS'\r\n"
        'try {'
        ' Start-Process cmd.exe -ArgumentList "/c `"\$j`"" -Verb RunAs -WindowStyle Hidden -Wait;'
        ' exit 0'
        ' } catch {'
        ' exit 1'
        " }\r\n";

    await File(psPath).writeAsString(psContent, encoding: utf8);

    final pr = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        psPath,
      ],
    );

    try { await File(psPath).delete(); } catch (_) {}
    try { await File(jobPath).delete(); } catch (_) {}

    if (pr.exitCode != 0) {
      try { await File(outPath).delete(); } catch (_) {}
      // UAC cancelled → Start-Process throws Win32Exception → catch{exit 1}
      throw StateError(
        'elevation cancelled or failed (UAC exit ${pr.exitCode})',
      );
    }

    final outFile = File(outPath);
    if (!await outFile.exists()) {
      throw StateError(
        'UAC fallback: no output (elevation cancelled or cmd failed).',
      );
    }
    final text = await outFile.readAsString(encoding: utf8);
    try { await outFile.delete(); } catch (_) {}

    final m = RegExp(r'EXITCODE=(\d+)', caseSensitive: false).firstMatch(text);
    final code = m != null ? int.parse(m.group(1)!) : 0;
    return _AdminIpcResult(
      stdout: text,
      stderr: '',
      exitCode: code,
      rawBody: '',
    );
  }

  static Future<_AdminIpcResult> _runCmdBatViaUacFallback(String batchBody) {
    final completer = Completer<_AdminIpcResult>();
    _uacFallbackQueue = _uacFallbackQueue.then((_) async {
      try {
        final r = await _runCmdBatViaUacFallbackImpl(batchBody);
        if (!completer.isCompleted) completer.complete(r);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Delete then create a scheduled task via elevated CMD only (OTA register button).
  ///
  /// The batch body uses the %SEEDESK_OUT% variable (set by the wrapper) to
  /// append schtasks output so error messages are visible on failure.
  static Future<void> runSchtasksElevatedDeleteAndCreate({
    required List<String> deleteArgs,
    required List<String> createArgs,
  }) async {
    if (kIsWeb || !Platform.isWindows) {
      throw UnsupportedError('schtasks is Windows only.');
    }
    // Delete is best-effort (task may not exist yet) — redirect to nul.
    // Create output is captured via %SEEDESK_OUT% for error reporting.
    // No "exit /b" inside the body: the wrapper always writes EXITCODE last.
    final body = StringBuffer()
      ..writeln('${_schtasksBatchLine(deleteArgs)} >nul 2>&1')
      ..writeln('${_schtasksBatchLine(createArgs)} >>"%SEEDESK_OUT%" 2>&1');
    final r = await _runCmdBatViaUacFallback(body.toString());
    if (r.exitCode != 0) {
      final detail = r.combinedOutput
          .replaceAll(RegExp(r'EXITCODE=\d+', caseSensitive: false), '')
          .trim();
      throw StateError(
        detail.isEmpty
            ? 'schtasks failed after UAC (exit ${r.exitCode})'
            : detail,
      );
    }
  }

  /// Single elevated schtasks invocation via CMD (no PowerShell).
  static Future<void> runSchtasksElevated(List<String> args) async {
    if (kIsWeb || !Platform.isWindows) {
      throw UnsupportedError('schtasks is Windows only.');
    }
    if (args.isEmpty) {
      throw ArgumentError('schtasks args empty.');
    }
    final body = StringBuffer()
      ..writeln('${_schtasksBatchLine(args)} >>"%SEEDESK_OUT%" 2>&1');
    final r = await _runCmdBatViaUacFallback(body.toString());
    if (r.exitCode != 0) {
      final detail = r.combinedOutput
          .replaceAll(RegExp(r'EXITCODE=\d+', caseSensitive: false), '')
          .trim();
      throw StateError(
        detail.isEmpty
            ? 'schtasks failed after UAC (exit ${r.exitCode})'
            : detail,
      );
    }
  }

  /// Registers a daily scheduled task as SYSTEM/Highest via an elevated
  /// PowerShell [Register-ScheduledTask] call.
  ///
  /// Using a PowerShell cmdlet (not schtasks.exe) avoids CMD-level quoting
  /// issues that occur when the exe path contains spaces.
  /// Elevation uses the same [Start-Process -Verb RunAs -Wait] pattern as
  /// the other elevated helpers — the UAC dialog is shown by Windows, not PS.
  static Future<void> elevatedRegisterScheduledTask({
    required String taskName,
    required String exePath,
    required String argument,
    required String startTime, // "HH:MM"
  }) async {
    if (kIsWeb || !Platform.isWindows) {
      throw UnsupportedError('Register-ScheduledTask is Windows only.');
    }

    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final outPath = p.join(tmp.path, 'seedesk_ota_${stamp}_out.txt');
    final innerPath = p.join(tmp.path, 'seedesk_ota_${stamp}_inner.ps1');
    final outerPath = p.join(tmp.path, 'seedesk_ota_${stamp}_outer.ps1');

    // Single-quote escape for PowerShell string literals.
    String ps(String s) => s.replaceAll("'", "''");

    // Inner PS1 runs ELEVATED and creates the task via Register-ScheduledTask.
    // No quoting issues: exe path is passed as a separate PowerShell variable.
    // Battery-related options are set via object properties (not cmdlet
    // parameters) because older Windows/PS versions don't expose them as
    // -DisallowStartIfOnBatteries / -StopIfGoingOnBatteries parameters.
    final innerContent = "\$ErrorActionPreference = 'Stop'\r\n"
        'try {\r\n'
        "  \$action   = New-ScheduledTaskAction -Execute '${ps(exePath)}'"
        " -Argument '${ps(argument)}'\r\n"
        "  \$trigger  = New-ScheduledTaskTrigger -Daily -At '$startTime'\r\n"
        '  \$principal = New-ScheduledTaskPrincipal'
        " -UserId 'S-1-5-18' -RunLevel Highest\r\n"
        '  \$settings = New-ScheduledTaskSettingsSet'
        ' -MultipleInstances IgnoreNew'
        ' -ExecutionTimeLimit (New-TimeSpan -Hours 1)\r\n'
        '  try { \$settings.DisallowStartIfOnBatteries = \$false } catch {}\r\n'
        '  try { \$settings.StopIfGoingOnBatteries = \$false } catch {}\r\n'
        "  Unregister-ScheduledTask -TaskName '${ps(taskName)}'"
        " -Confirm:\$false -ErrorAction SilentlyContinue\r\n"
        "  Register-ScheduledTask -TaskName '${ps(taskName)}'"
        ' -Action \$action -Trigger \$trigger'
        ' -Principal \$principal -Settings \$settings'
        " -Force | Out-Null\r\n"
        "  'EXITCODE=0' | Out-File -FilePath '${ps(outPath)}'"
        " -Encoding UTF8\r\n"
        '  exit 0\r\n'
        '} catch {\r\n'
        "  \$_.Exception.Message | Out-File -FilePath '${ps(outPath)}'"
        " -Encoding UTF8\r\n"
        "  'EXITCODE=1' | Out-File -FilePath '${ps(outPath)}'"
        " -Encoding UTF8 -Append\r\n"
        '  exit 1\r\n'
        '}\r\n';

    await File(innerPath).writeAsString(innerContent, encoding: utf8);

    // Outer PS1 launches the inner PS1 elevated via Start-Process -Verb RunAs.
    final outerContent = 'try {\r\n'
        '  Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait'
        " -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy',"
        "'Bypass','-File','${ps(innerPath)}')\r\n"
        '  exit 0\r\n'
        '} catch { exit 1 }\r\n';

    await File(outerPath).writeAsString(outerContent, encoding: utf8);

    final pr = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        outerPath,
      ],
    );

    try { await File(outerPath).delete(); } catch (_) {}
    try { await File(innerPath).delete(); } catch (_) {}

    if (pr.exitCode != 0) {
      try { await File(outPath).delete(); } catch (_) {}
      throw StateError(
        'elevation cancelled or failed (UAC exit ${pr.exitCode})',
      );
    }

    final outFile = File(outPath);
    if (!await outFile.exists()) {
      throw StateError(
        'UAC fallback: no output (elevation cancelled or task registration failed).',
      );
    }
    final text = await outFile.readAsString(encoding: utf8);
    try { await outFile.delete(); } catch (_) {}

    final m = RegExp(r'EXITCODE=(\d+)', caseSensitive: false).firstMatch(text);
    final code = m != null ? int.parse(m.group(1)!) : 1;
    if (code != 0) {
      final detail = text
          .replaceAll(RegExp(r'EXITCODE=\d+', caseSensitive: false), '')
          .trim();
      throw StateError(
        detail.isEmpty ? 'Register-ScheduledTask failed (exit $code)' : detail,
      );
    }
  }

  /// Task name registered with `schtasks` for scheduled cleanup (must match native tooling).
  static const _kSchtasksCleanupTaskName = 'SeeDesktopSystemClean';

  // ---------------------------------------------------------------------------
  // IPC to elevated background service (placeholder URL)
  // ---------------------------------------------------------------------------

  /// **Placeholder:** local HTTP endpoint where the native admin/SYSTEM service
  /// accepts execute requests. Replace `defaultValue` (or pass
  /// `--dart-define=SEEDESKTOP_ADMIN_IPC_URL=...`) with your real pipe/HTTP bridge.
  ///
  /// If your stack uses **named pipes, FFI, or MethodChannel to Rust** instead,
  /// replace [_postAdminIpc] / [_fetchDataSilently] internals only — keep the
  /// public [LocalMaintenanceService] API unchanged.
  static const String _kAdminIpcExecuteUrl = String.fromEnvironment(
    'SEEDESKTOP_ADMIN_IPC_URL',
    defaultValue: 'http://127.0.0.1:59821/execute',
  );

  /// Response JSON from the admin service (expected shape).
  /// `{ "stdout": "...", "stderr": "...", "exit_code": 0 }`
  static _AdminIpcResult _parseAdminIpcResponse(String body) {
    try {
      final m = jsonDecode(body) as Map<String, dynamic>;
      final out = m['stdout']?.toString() ?? '';
      final err = m['stderr']?.toString() ?? '';
      final code = (m['exit_code'] as num?)?.toInt() ??
          (m['exitCode'] as num?)?.toInt() ??
          0;
      return _AdminIpcResult(
        stdout: out,
        stderr: err,
        exitCode: code,
        rawBody: body,
      );
    } catch (_) {
      final t = body.trim();
      return _AdminIpcResult(
        stdout: t,
        stderr: '',
        exitCode: t.isEmpty ? 1 : 0,
        rawBody: body,
      );
    }
  }

  /// Low-level POST to the admin service. [payload] must include `command` and `args`.
  static Future<_AdminIpcResult> _postAdminIpc(
      Map<String, dynamic> payload) async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    if (!Platform.isWindows) {
      throw UnsupportedError('Local maintenance is only supported on Windows.');
    }
    final uri = Uri.parse(_kAdminIpcExecuteUrl);
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(payload),
    );
    final body = resp.body;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError(
        'Admin IPC HTTP ${resp.statusCode} at $_kAdminIpcExecuteUrl: $body',
      );
    }
    return _parseAdminIpcResponse(body);
  }

  static bool _localPsSuggestsAccessDenied(String out, String err) {
    final t = ('$out $err').toLowerCase();
    if (t.contains('access is denied') || t.contains('access denied')) {
      return true;
    }
    if (t.contains('denied') &&
        (t.contains('privileges') || t.contains('privileged'))) {
      return true;
    }
    if (t.contains('elevation') && t.contains('required')) return true;
    if (t.contains('requested operation requires elevation')) return true;
    if (t.contains('requires administrator')) return true;
    if (t.contains('הגישה') && t.contains('נדחתה')) return true;
    return false;
  }

  /// Local PowerShell only — **never** UAC. Used when IPC is down for dashboard reads.
  static Future<_AdminIpcResult> _runPowershellLocalSilent(
      String trimmed) async {
    try {
      final pr = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          trimmed,
        ],
      );
      final out = pr.stdout.toString();
      final err = pr.stderr.toString();
      if (pr.exitCode != 0 && _localPsSuggestsAccessDenied(out, err)) {
        return _AdminIpcResult(
          stdout: kErrorRequiresAdmin,
          stderr: '',
          exitCode: pr.exitCode,
          rawBody: '',
        );
      }
      return _AdminIpcResult(
        stdout: out,
        stderr: err,
        exitCode: pr.exitCode,
        rawBody: '',
      );
    } catch (e) {
      debugPrint('Silent PowerShell run failed: $e');
      return _AdminIpcResult(
        stdout: kErrorRequiresAdmin,
        stderr: e.toString(),
        exitCode: -1,
        rawBody: '',
      );
    }
  }

  static void _throwIfRequiresAdmin(_AdminIpcResult r) {
    if (r.stdout.trim() == kErrorRequiresAdmin) {
      throw StateError(kErrorRequiresAdmin);
    }
  }

  /// Dashboard / polling: IPC first; if unreachable, local `powershell` **without** UAC.
  static Future<_AdminIpcResult> _fetchDataSilently(String script) async {
    final trimmed = script.trim();
    if (trimmed.isEmpty) {
      throw StateError('Empty PowerShell script.');
    }
    try {
      return await _postAdminIpc({
        'command': 'powershell.exe',
        'args': <String>[
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          trimmed,
        ],
      });
    } on SocketException catch (e) {
      debugPrint('IPC unavailable; local PowerShell (no UAC): $e');
      return _runPowershellLocalSilent(trimmed);
    } on http.ClientException catch (e) {
      debugPrint('IPC unavailable; local PowerShell (no UAC): $e');
      return _runPowershellLocalSilent(trimmed);
    }
  }

  /// Explicit user actions: IPC first; if unreachable, UAC `RunAs` fallback (never from timers).
  static Future<_AdminIpcResult> _executeActionWithUAC(String script) async {
    final trimmed = script.trim();
    if (trimmed.isEmpty) {
      throw StateError('Empty PowerShell script.');
    }
    try {
      return await _postAdminIpc({
        'command': 'powershell.exe',
        'args': <String>[
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          trimmed,
        ],
      });
    } on SocketException catch (e) {
      debugPrint('IPC failed, falling back to UAC prompt: $e');
      final r = await _runPowershellViaUacFallback(trimmed);
      _pendingUacFallbackUiHint = true;
      return r;
    } on http.ClientException catch (e) {
      debugPrint('IPC failed, falling back to UAC prompt: $e');
      final r = await _runPowershellViaUacFallback(trimmed);
      _pendingUacFallbackUiHint = true;
      return r;
    }
  }

  /// Runs one-line PowerShell or CMD command with elevation (RunAs fallback).
  ///
  /// Intended for explicit user actions only (for example, "play command" in UI).
  static Future<String> runOneLinerAsAdmin({
    required String command,
    required bool usePowerShell,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows only.');
    }
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Empty command.');
    }
    final script = usePowerShell ? trimmed : 'cmd.exe /c "$trimmed"';
    final r = await _executeActionWithUAC(script);
    return _combinedLenient(r);
  }

  /// Opens a real elevated Windows PowerShell window and runs the command there.
  ///
  /// The window remains open (`-NoExit`) so the user sees live output directly
  /// in PowerShell, not inside the app UI.
  static Future<void> openPowerShellWindowAsAdmin({
    required String command,
    required bool sourceIsPowerShell,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows only.');
    }
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Empty command.');
    }

    final commandForPowerShell =
        sourceIsPowerShell ? trimmed : 'cmd.exe /c "$trimmed"';
    final cmdLit =
        "'${commandForPowerShell.replaceAll("'", "''").replaceAll('\r', ' ').replaceAll('\n', ' ')}'";

    final startCmd =
        "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoExit','-ExecutionPolicy','Bypass','-Command',$cmdLit)";

    final pr = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', startCmd],
    );

    if (pr.exitCode != 0) {
      final err = pr.stderr.toString().trim();
      final out = pr.stdout.toString().trim();
      final detail = [err, out].where((s) => s.isNotEmpty).join(' | ');
      throw StateError(
        detail.isEmpty ? 'Failed to open elevated PowerShell window.' : detail,
      );
    }
  }

  /// Runs `schtasks.exe` with [args]: SeeDesktop service (SYSTEM) → local process → optional UAC.
  static Future<void> runSchtasks(
    List<String> args, {
    bool allowUacFallback = false,
    bool skipAdminIpc = false,
  }) async {
    if (kIsWeb || !Platform.isWindows) {
      throw UnsupportedError('schtasks is Windows only.');
    }
    if (args.isEmpty) {
      throw ArgumentError('schtasks args empty.');
    }

    if (!skipAdminIpc) {
      Future<_AdminIpcResult> viaService() => _executeViaAdminNative(
            command: 'schtasks.exe',
            args: args,
          );

      try {
        final r = await viaService();
        if (r.exitCode == 0) return;
        final detail =
            r.combinedOutput.isEmpty ? 'exit ${r.exitCode}' : r.combinedOutput;
        if (!allowUacFallback ||
            !_localPsSuggestsAccessDenied(r.stdout, r.stderr)) {
          throw StateError(detail);
        }
      } on SocketException catch (_) {
        if (!allowUacFallback) rethrow;
      } on http.ClientException catch (_) {
        if (!allowUacFallback) rethrow;
      } on StateError catch (e) {
        if (!allowUacFallback) rethrow;
        if (!_localPsSuggestsAccessDenied(e.message, '')) rethrow;
      }
    }

    final pr = await Process.run('schtasks', args, runInShell: true);
    if (pr.exitCode == 0) return;
    final out = '${pr.stdout}${pr.stderr}'.trim();
    if (!allowUacFallback ||
        !_localPsSuggestsAccessDenied('${pr.stdout}', '${pr.stderr}')) {
      throw StateError(out.isEmpty ? 'schtasks exit ${pr.exitCode}' : out);
    }

    final ps = StringBuffer(r'$ErrorActionPreference = "Stop"');
    ps.write(r'$a = @(');
    for (var i = 0; i < args.length; i++) {
      if (i > 0) ps.write(',');
      ps.write("'");
      ps.write(args[i].replaceAll("'", "''"));
      ps.write("'");
    }
    ps.writeln(')');
    ps.writeln(
        r'& "$env:SystemRoot\System32\schtasks.exe" @a; exit $LASTEXITCODE');
    final uac = await _runPowershellViaUacFallback(ps.toString());
    if (uac.exitCode != 0) {
      final detail = uac.combinedOutput.trim();
      throw StateError(
        detail.isEmpty
            ? 'schtasks failed after UAC (exit ${uac.exitCode})'
            : detail,
      );
    }
  }

  /// Runs an arbitrary executable with arguments (e.g. `schtasks.exe`) via the same service.
  static Future<_AdminIpcResult> _executeViaAdminNative({
    required String command,
    required List<String> args,
  }) async {
    final c = command.trim();
    if (c.isEmpty) {
      throw StateError('Empty command.');
    }
    return _postAdminIpc({
      'command': c,
      'args': args,
    });
  }

  static String _combinedLenient(_AdminIpcResult r) {
    final combined = r.combinedOutput;
    if (combined.isEmpty && r.exitCode != 0) {
      throw StateError(
        'PowerShell exited with code ${r.exitCode} (no output).',
      );
    }
    if (combined.isEmpty) {
      return 'הפעולה הושלמה.';
    }
    return combined;
  }

  static Future<Directory> _maintenanceDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'maintenance'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Full PowerShell script body (saved to `.ps1` and executed with `-File`).
  static String buildPowerShellFileBody(LocalMaintenanceCleanOptions o) {
    final b = StringBuffer();
    b.writeln(r"$ErrorActionPreference = 'SilentlyContinue'");
    b.writeln(r"$ProgressPreference = 'SilentlyContinue'");

    if (o.userTemp) {
      b.writeln(
        r'Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue',
      );
    }
    if (o.windowsTemp) {
      b.writeln(
        r'Remove-Item -Path "$env:windir\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue',
      );
    }
    if (o.inetCache) {
      b.writeln(
        r'$p = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\INetCache"; if (Test-Path $p) { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }',
      );
    }
    if (o.explorerCache) {
      b.writeln(
        r'$p = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer"; if (Test-Path $p) { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }',
      );
    }
    if (o.recycleBin) {
      b.writeln(r'Clear-RecycleBin -Force -ErrorAction SilentlyContinue');
    }

    if (o.dnsCache) {
      b.writeln(r'ipconfig /flushdns | Out-Null');
    }
    if (o.wer) {
      b.writeln(
        r'$wer = Join-Path $env:ProgramData "Microsoft\Windows\WER"; if (Test-Path $wer) { Get-ChildItem -LiteralPath $wer -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }',
      );
    }
    if (o.deliveryOptimization) {
      b.writeln(
        r'$do = Join-Path $env:ProgramData "Microsoft\Windows\DeliveryOptimization\Cache"; if (Test-Path $do) { Get-ChildItem -LiteralPath $do -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }',
      );
    }
    if (o.directXShader) {
      b.writeln(
        r'$d3 = Join-Path $env:LOCALAPPDATA "D3DSCache"; if (Test-Path $d3) { Get-ChildItem -LiteralPath $d3 -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }',
      );
    }
    if (o.windowsLogs) {
      b.writeln(
        r'@("Application","System","Security") | ForEach-Object { & wevtutil cl $_ 2>$null }',
      );
    }
    if (o.winSxS) {
      b.writeln(
        r'Start-Process -FilePath "$env:windir\System32\dism.exe" -ArgumentList "/Online","/Cleanup-Image","/StartComponentCleanup","/NoRestart" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue',
      );
    }
    if (o.microsoftStoreCache) {
      b.writeln(
        r'$sc = Join-Path $env:LOCALAPPDATA "Packages"; Get-ChildItem -Path $sc -Filter "Microsoft.WindowsStore*" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $lc = Join-Path $_.FullName "LocalCache"; if (Test-Path $lc) { Remove-Item -LiteralPath $lc -Recurse -Force -ErrorAction SilentlyContinue } }',
      );
    }
    if (o.windowsBt) {
      b.writeln(
        r"$bt = Join-Path $env:SystemDrive ([char]36 + 'Windows.~BT'); "
        r'if (Test-Path -LiteralPath $bt) { Remove-Item -LiteralPath $bt -Recurse -Force -ErrorAction SilentlyContinue }',
      );
    }
    if (o.prefetch) {
      b.writeln(
        r'$pf = Join-Path $env:windir "Prefetch"; if (Test-Path $pf) { Get-ChildItem -LiteralPath $pf -Filter "*.pf" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }',
      );
    }

    if (o.chromeCache) {
      b.writeln(
        r'$chromeBase = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data\Default"; @("Cache","Code Cache","GPUCache") | ForEach-Object { $p = Join-Path $chromeBase $_; if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }',
      );
    }
    if (o.edgeCache) {
      b.writeln(
        r'$edgeBase = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Default"; @("Cache","Code Cache","GPUCache") | ForEach-Object { $p = Join-Path $edgeBase $_; if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }',
      );
    }
    if (o.firefoxCache) {
      b.writeln(
        r'$ffRoot = Join-Path $env:LOCALAPPDATA "Mozilla\Firefox\Profiles"; if (Test-Path $ffRoot) { Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $prof = $_.FullName; @("cache2","startupCache") | ForEach-Object { $sub = Join-Path $prof $_; if (Test-Path $sub) { Remove-Item -LiteralPath $sub -Recurse -Force -ErrorAction SilentlyContinue } } } }',
      );
    }
    if (o.cookiesLocalStorage) {
      b.writeln(
        r'$chromeBase = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data\Default"; @("Cookies","Local Storage","IndexedDB") | ForEach-Object { $p = Join-Path $chromeBase $_; if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }',
      );
      b.writeln(
        r'$edgeBase = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Default"; @("Cookies","Local Storage","IndexedDB") | ForEach-Object { $p = Join-Path $edgeBase $_; if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }',
      );
    }
    if (o.historyDb) {
      b.writeln(
        r'$chromeBase = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data\Default"; @("History","History-journal") | ForEach-Object { $p = Join-Path $chromeBase $_; if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } }',
      );
      b.writeln(
        r'$edgeBase = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Default"; @("History","History-journal") | ForEach-Object { $p = Join-Path $edgeBase $_; if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } }',
      );
    }

    if (o.spotifyCache) {
      b.writeln(
        r'$sp = Join-Path $env:APPDATA "Spotify"; if (Test-Path $sp) { @("Storage","Browser","Users") | ForEach-Object { $x = Join-Path $sp $_; if (Test-Path $x) { Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue } } }',
      );
    }
    if (o.teamsCache) {
      b.writeln(
        r'$tm = Join-Path $env:APPDATA "Microsoft\Teams"; if (Test-Path $tm) { @("Cache","blob_storage","GPUCache","Code Cache","Service Worker") | ForEach-Object { $x = Join-Path $tm $_; if (Test-Path $x) { Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue } } }',
      );
    }
    if (o.oneDriveCache) {
      b.writeln(
        r'$od = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\logs"; if (Test-Path $od) { Remove-Item -LiteralPath $od -Recurse -Force -ErrorAction SilentlyContinue }',
      );
    }
    if (o.discordCache) {
      b.writeln(
        r'foreach ($root in @((Join-Path $env:APPDATA "discord"), (Join-Path $env:LOCALAPPDATA "Discord"))) { if (Test-Path $root) { @("Cache","Code Cache","GPUCache","Service Worker") | ForEach-Object { $p = Join-Path $root $_; if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } } } }',
      );
    }

    b.writeln(r'Write-Output "SeeDesktop cleanup script finished."');
    return b.toString();
  }

  /// Runs cleanup immediately (script executed by elevated service via IPC).
  static Future<void> runSystemCleaner(
      LocalMaintenanceCleanOptions options) async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final body = buildPowerShellFileBody(options).trim();
    if (body.isEmpty) {
      throw StateError('No cleaner steps selected.');
    }
    final r = await _executeActionWithUAC(body);
    if (r.exitCode != 0) {
      final detail =
          r.combinedOutput.isEmpty ? 'exit ${r.exitCode}' : r.combinedOutput;
      throw StateError(
        detail.isEmpty
            ? 'PowerShell exited with code ${r.exitCode}'
            : 'PowerShell (${r.exitCode}): $detail',
      );
    }
  }

  /// Writes the script under app support and registers [CleanupScheduleMode] via `schtasks`.
  static Future<void> scheduleCleanup(
    LocalMaintenanceCleanOptions options,
    CleanupScheduleMode mode,
  ) async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    if (mode == CleanupScheduleMode.runNow) {
      throw ArgumentError('Use runSystemCleaner for run now.');
    }
    final body = buildPowerShellFileBody(options).trim();
    if (body.isEmpty) {
      throw StateError('No cleaner steps selected.');
    }
    final mdir = await _maintenanceDir();
    final scriptFile = File(p.join(mdir.path, _scheduledScriptName));
    await scriptFile.writeAsString(body, encoding: utf8);
    final sc = switch (mode) {
      CleanupScheduleMode.daily => 'DAILY',
      CleanupScheduleMode.weekly => 'WEEKLY',
      CleanupScheduleMode.monthly => 'MONTHLY',
      CleanupScheduleMode.runNow => 'DAILY',
    };
    await _registerScheduledCleanupTaskIpc(scriptFile.path, sc);
  }

  /// Registers the cleanup `.ps1` with `schtasks` via the admin service (native process).
  static Future<void> _registerScheduledCleanupTaskIpc(
    String scriptPath,
    String scheduleType,
  ) async {
    await _executeViaAdminNative(
      command: 'schtasks.exe',
      args: ['/Delete', '/TN', _kSchtasksCleanupTaskName, '/F'],
    );

    final inner = scriptPath.replaceAll('"', r'\"');
    final tr =
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$inner"';

    final args = <String>[
      '/Create',
      '/TN',
      _kSchtasksCleanupTaskName,
      '/TR',
      tr,
      '/F',
    ];
    if (scheduleType == 'DAILY') {
      args.addAll(['/SC', 'DAILY', '/ST', '03:00']);
    } else if (scheduleType == 'WEEKLY') {
      args.addAll(['/SC', 'WEEKLY', '/D', 'SUN', '/ST', '03:00']);
    } else if (scheduleType == 'MONTHLY') {
      args.addAll(['/SC', 'MONTHLY', '/D', '1', '/ST', '03:00']);
    } else {
      args.addAll(['/SC', 'DAILY', '/ST', '03:00']);
    }

    final r = await _executeViaAdminNative(command: 'schtasks.exe', args: args);
    if (r.exitCode != 0) {
      final detail =
          r.combinedOutput.isEmpty ? 'exit ${r.exitCode}' : r.combinedOutput;
      throw StateError(
        'schtasks failed (${r.exitCode}): $detail',
      );
    }
  }

  /// User + Windows Temp folder sizes (bytes). Windows only; can take noticeable time.
  static Future<({int userBytes, int winBytes})>
      estimateTempFolderSizes() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psEstimateTempFoldersJson());
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty) {
      throw StateError('Empty output from temp size estimate.');
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    int read(String k) => (m[k] as num?)?.toInt() ?? 0;
    return (
      userBytes: read('user_temp_bytes'),
      winBytes: read('win_temp_bytes'),
    );
  }

  /// Cumulative received/sent bytes (all adapters). Windows: via PowerShell.
  static Future<({int rx, int tx})> getNetworkAdapterByteCounters() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psNetworkAdapterBytesJson());
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty) {
      throw StateError('Empty output from network counters.');
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    int read(String k) => (m[k] as num?)?.toInt() ?? 0;
    return (rx: read('rx'), tx: read('tx'));
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const u = 1024.0;
    var v = bytes.toDouble();
    if (v < u) return '$bytes B';
    v /= u;
    if (v < u) return '${v.toStringAsFixed(1)} KB';
    v /= u;
    if (v < u) return '${v.toStringAsFixed(1)} MB';
    v /= u;
    return '${v.toStringAsFixed(2)} GB';
  }

  /// איפוס רשת: DNS, שחרור וחידוש IP (שקט).
  static Future<String> resetNetwork() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    const script =
        r'ipconfig /flushdns | Out-Null; ipconfig /release | Out-Null; ipconfig /renew | Out-Null; Write-Output "רשת אופסה וכתובת IP חודשה בהצלחה."';
    final r = await _executeActionWithUAC(script);
    return _combinedLenient(r);
  }

  /// Event log forensics + OS caption (PowerShell JSON). Can take several seconds.
  static Future<LocalMaintenanceForensicSnapshot>
      fetchForensicSnapshot() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psForensicMetricsJson());
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty || !raw.startsWith('{')) {
      throw StateError(
        r.stderr.trim().isEmpty
            ? 'Forensic script produced no JSON.'
            : 'Forensic script: ${r.stderr.trim()}',
      );
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return LocalMaintenanceForensicSnapshot.fromJson(m);
  }

  /// Windows Experience Index / WinSAT scores (`Get-CimInstance Win32_WinSAT`).
  static Future<LocalMaintenanceWinSatSnapshot> fetchWinSatSnapshot() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psWinSatScoresJson());
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty || !raw.startsWith('{')) {
      throw StateError(
        r.stderr.trim().isEmpty
            ? 'WinSAT script produced no JSON.'
            : 'WinSAT script: ${r.stderr.trim()}',
      );
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return LocalMaintenanceWinSatSnapshot.fromJson(m);
  }

  /// Extended audit (RAM slots, network, AV, users, SMB, printers, USB) for dashboard cards.
  static Future<LocalMaintenanceAuditSnapshot> fetchAuditSnapshot() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psDashboardExtendedAuditJson());
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty || !raw.startsWith('{')) {
      return LocalMaintenanceAuditSnapshot.empty();
    }
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return LocalMaintenanceAuditSnapshot.fromJson(m);
    } catch (_) {
      return LocalMaintenanceAuditSnapshot.empty();
    }
  }

  /// Read-only disk check (`Repair-Volume -Scan` or `chkdsk`). Result text for UI.
  static Future<String> runChkdskScan({String driveLetter = 'C'}) async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final dl = driveLetter.trim().toUpperCase();
    if (dl.isEmpty || dl.length != 1 || RegExp(r'[^A-Z]').hasMatch(dl)) {
      throw ArgumentError('Invalid drive letter: $driveLetter');
    }
    final script = psChkdskVolumeScanTemplate().replaceAll('DLCHAR', dl);
    final r = await _executeActionWithUAC(script);
    var combined = r.combinedOutput;
    if (combined.isEmpty) {
      return 'הבדיקה הושלמה ללא פלט טקסט.';
    }
    if (combined.length > 14000) {
      combined = '${combined.substring(0, 14000)}\n…';
    }
    return combined;
  }

  /// Opens the built-in Windows Memory Diagnostic (`mdsched.exe`).
  static Future<void> launchWindowsMemoryDiagnostic() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final root = Platform.environment['SYSTEMROOT'] ??
        Platform.environment['SystemRoot'] ??
        r'C:\Windows';
    final exe = p.join(root, 'System32', 'mdsched.exe');
    final f = File(exe);
    if (!await f.exists()) {
      throw StateError('לא נמצא mdsched.exe (אבחון זיכרון של Windows).');
    }
    final proc = await Process.start(
      exe,
      const <String>[],
      mode: ProcessStartMode.detached,
    );
    if (proc.pid == 0) {
      throw StateError('לא ניתן להפעיל את אבחון הזיכרון.');
    }
  }

  /// Print Spooler service status: `Running`, `Stopped`, or `Unknown`.
  static Future<String> fetchPrintSpoolerStatus() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psPrintSpoolerStatusJson());
    _throwIfRequiresAdmin(r);
    var raw = r.stdout.trim();
    if (raw.isEmpty || !raw.startsWith('{')) {
      return 'Unknown';
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return (m['state'] as String?)?.trim() ?? 'Unknown';
  }

  /// Lists PnP signed drivers (WMI) — requires elevated session; uses IPC.
  static Future<String> checkDrivers() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    const script = r'''
Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
  Select-Object DeviceName, DriverVersion, DriverDate |
  ConvertTo-Json -Compress
''';
    final r = await _fetchDataSilently(script);
    _throwIfRequiresAdmin(r);
    final out = r.stdout.trim();
    if (out.isNotEmpty) return out;
    return r.combinedOutput.isEmpty ? 'לא התקבל פלט.' : r.combinedOutput;
  }

  /// Restarts the Windows Print Spooler service.
  static Future<String> restartPrintSpooler() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _executeActionWithUAC(psRestartPrintSpooler());
    final out = r.stdout.toString().trim();
    final err = r.stderr.toString().trim();
    final combined = [out, err].where((s) => s.isNotEmpty).join('\n');
    if (combined.isEmpty) {
      return r.exitCode == 0 ? 'OK' : 'לא ניתן להפעיל מחדש (ייתכן שדרוש מנהל).';
    }
    return combined.length > 800 ? '${combined.substring(0, 800)}…' : combined;
  }

  /// Windows short service name (e.g. `Spooler`, `LanmanServer`).
  static bool isValidWatchdogServiceName(String s) {
    final t = s.trim();
    if (t.isEmpty || t.length > 80) return false;
    return RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(t);
  }

  /// Status map: service name → `Running` / `Stopped` / `Unknown`.
  static Future<Map<String, String>> fetchWindowsServicesStatusBatch(
    List<String> names,
  ) async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final valid = <String>[];
    for (final n in names) {
      final t = n.trim();
      if (isValidWatchdogServiceName(t) && !valid.contains(t)) {
        valid.add(t);
      }
    }
    if (valid.isEmpty) return {};
    final r = await _fetchDataSilently(psWindowsServicesStatusBatchJson(valid));
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty || !raw.startsWith('{')) {
      return {for (final n in valid) n: 'Unknown'};
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final sv = m['services'];
    final out = <String, String>{};
    void addEntry(Map<String, dynamic> row) {
      final name = (row['name']?.toString() ?? '').trim();
      final state = (row['state']?.toString() ?? 'Unknown').trim();
      if (name.isNotEmpty) {
        out[name] = state;
      }
    }

    if (sv is List) {
      for (final e in sv) {
        if (e is Map) {
          addEntry(Map<String, dynamic>.from(e));
        }
      }
    } else if (sv is Map) {
      addEntry(Map<String, dynamic>.from(sv));
    }
    for (final n in valid) {
      out.putIfAbsent(n, () => 'Unknown');
    }
    return out;
  }

  /// Starts listed services that are not [Running] (elevated when needed).
  static Future<String> startWindowsServicesIfStopped(
    List<String> names,
  ) async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final valid = <String>[];
    for (final n in names) {
      final t = n.trim();
      if (isValidWatchdogServiceName(t) && !valid.contains(t)) {
        valid.add(t);
      }
    }
    if (valid.isEmpty) {
      return 'OK';
    }
    final r =
        await _executeActionWithUAC(psStartWindowsServicesIfStopped(valid));
    final out = r.stdout.toString().trim();
    final err = r.stderr.toString().trim();
    final combined = [out, err].where((s) => s.isNotEmpty).join('\n');
    if (combined.isEmpty) {
      return r.exitCode == 0
          ? 'OK'
          : 'לא ניתן להפעיל שירותים (ייתכן שדרוש מנהל).';
    }
    return combined.length > 800 ? '${combined.substring(0, 800)}…' : combined;
  }

  /// עומס מעבד/זיכרון, זמן פעולה, קובץ החלפה, ועשרת התהליכים המובילים לפי CPU ו־RAM.
  static Future<LocalMaintenanceRealTimeLoad> fetchRealTimeLoad() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psRealTimeLoadJson());
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty || !raw.startsWith('{')) {
      throw StateError(
        r.stderr.trim().isEmpty
            ? 'Real-time load script produced no JSON.'
            : r.stderr.trim(),
      );
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return LocalMaintenanceRealTimeLoad.fromJson(m);
  }

  /// כתובת IPv4 פנימית וכתובת IP ציבורית (מחוץ לראוטר), לפי PowerShell + ipify.
  static Future<LocalMaintenanceNetworkIps> fetchNetworkEndpointIps() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psNetworkEndpointIpsJson());
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty || !raw.startsWith('{')) {
      throw StateError(
        r.stderr.trim().isEmpty
            ? 'Network endpoint IP script produced no JSON.'
            : r.stderr.trim(),
      );
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return LocalMaintenanceNetworkIps.fromJson(m);
  }

  /// חמש שגיאות Application אחרונות (יומן Windows).
  static Future<List<LocalMaintenanceAppErrorRow>>
      fetchApplicationErrorsLast5() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psApplicationErrorsLast5Json());
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty) {
      return [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) =>
              LocalMaintenanceAppErrorRow.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    }
    if (decoded is Map) {
      return [
        LocalMaintenanceAppErrorRow.fromMap(Map<String, dynamic>.from(decoded))
      ];
    }
    return [];
  }

  /// חמש רשומות אחרונות של כיבוי בלתי צפוי (System Event ID 41).
  static Future<List<LocalMaintenanceUnexpectedShutdownRow>>
      fetchUnexpectedShutdownsLast5() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    final r = await _fetchDataSilently(psUnexpectedShutdownsLast5Json());
    _throwIfRequiresAdmin(r);
    final raw = r.stdout.trim();
    if (raw.isEmpty) {
      return [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map(
            (e) => LocalMaintenanceUnexpectedShutdownRow.fromMap(
              Map<String, dynamic>.from(e),
            ),
          )
          .toList();
    }
    if (decoded is Map) {
      return [
        LocalMaintenanceUnexpectedShutdownRow.fromMap(
          Map<String, dynamic>.from(decoded),
        )
      ];
    }
    return [];
  }

  /// `cmd /c start "" <arg>` — אמין יותר ל־`ms-settings:` ול־`.cpl` מתוך אפליקציית Flutter.
  static Future<void> _windowsCmdStart(String argument) async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows only.');
    }
    if (argument.trim().isEmpty) {
      throw ArgumentError('Empty start target.');
    }
    final proc = await Process.start(
      'cmd.exe',
      ['/c', 'start', '', argument],
      mode: ProcessStartMode.detached,
    );
    if (proc.pid == 0) {
      throw StateError('לא ניתן להפעיל: $argument');
    }
  }

  /// הגדרות שימוש בנתונים (לפי אפליקציה).
  static Future<void> openWindowsDataUsageSettings() async {
    await _windowsCmdStart('ms-settings:datausage');
  }

  /// פותח את הגדרות «שימוש באחסון» / Storage Sense ב-Windows.
  static Future<void> openWindowsStorageSenseSettings() async {
    await _windowsCmdStart('ms-settings:storagesense');
  }

  /// חיבורי רשת (לוח הבקרה הישן — `ncpa.cpl`).
  static Future<void> openWindowsNetworkConnectionsNcpa() async {
    await _windowsCmdStart('ncpa.cpl');
  }

  /// תיקיית מדפסות (מדפסות זמינות — Explorer).
  static Future<void> openWindowsPrintersFolder() async {
    if (kIsWeb) {
      throw UnsupportedError('Local maintenance is not available on web.');
    }
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows only.');
    }
    final proc = await Process.start(
      'explorer.exe',
      const ['shell:PrintersFolder'],
      mode: ProcessStartMode.detached,
    );
    if (proc.pid == 0) {
      throw StateError('לא ניתן לפתוח מדפסות.');
    }
  }
}
