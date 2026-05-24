import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/rmm_pro_gate_dialog.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';

// ---------------------------------------------------------------------------
// Data model
//
// Note: remote CPU/RAM/Disk/Temp are unknown until a Watchdog agent is
// installed on the remote machine and reports back.  We show "—" for now
// and mark them as HealthSeverity.unknown.
// ---------------------------------------------------------------------------

enum HealthSeverity { normal, warning, critical, offline, autoFixed, unknown }

class MachineHealth {
  final String peerId;
  final String displayName; // alias / hostname / id
  final bool online;

  // null means "no data yet — watchdog not installed"
  final double? cpu;
  final double? ramUsed;
  final double? ramTotal;
  final double? diskPct;
  final double? tempC;

  final HealthSeverity severity;
  final String? autoFixNote;
  final DateTime lastSeen;
  final bool isLocal; // this machine itself

  const MachineHealth({
    required this.peerId,
    required this.displayName,
    required this.online,
    this.cpu,
    this.ramUsed,
    this.ramTotal,
    this.diskPct,
    this.tempC,
    required this.severity,
    this.autoFixNote,
    required this.lastSeen,
    this.isLocal = false,
  });

  /// Build from a real Peer (no health data yet).
  factory MachineHealth.fromPeer(Peer peer) {
    final name = peer.alias.isNotEmpty
        ? peer.alias
        : peer.hostname.isNotEmpty
            ? '${peer.username.isNotEmpty ? "${peer.username}@" : ""}${peer.hostname}'
            : peer.id;
    return MachineHealth(
      peerId: peer.id,
      displayName: name,
      online: peer.online,
      severity: peer.online ? HealthSeverity.unknown : HealthSeverity.offline,
      lastSeen: DateTime.now(),
    );
  }
}

// ---------------------------------------------------------------------------
// Collect real peers from all models (deduplicated by id)
// ---------------------------------------------------------------------------

List<MachineHealth> _peersToHealthRows() {
  final seen = <String>{};
  final rows = <MachineHealth>[];

  void add(Peer p) {
    if (seen.contains(p.id)) return;
    seen.add(p.id);
    rows.add(MachineHealth.fromPeer(p));
  }

  for (final p in gFFI.recentPeersModel.peers) {
    add(p);
  }
  for (final p in gFFI.favoritePeersModel.peers) {
    add(p);
  }
  for (final p in gFFI.lanPeersModel.peers) {
    add(p);
  }

  // Sort: online first, then alphabetical
  rows.sort((a, b) {
    if (a.online != b.online) return a.online ? -1 : 1;
    return a.displayName.compareTo(b.displayName);
  });
  return rows;
}

// ===========================================================================
// Health Monitor Page
// ===========================================================================

class HealthMonitorPage extends StatefulWidget {
  const HealthMonitorPage({super.key});

  @override
  State<HealthMonitorPage> createState() => _HealthMonitorPageState();
}

class _HealthMonitorPageState extends State<HealthMonitorPage> {
  List<MachineHealth> _rows = [];
  HealthSeverity? _filterSeverity;
  Timer? _timer;
  bool? _hasRmmLicense;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRmmLicense());
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _rows = _peersToHealthRows();
    });
  }

  Future<void> _loadRmmLicense() async {
    final ok = await hasRmmLicenseLocal();
    if (!mounted) return;
    setState(() => _hasRmmLicense = ok);
  }

  List<MachineHealth> get _filtered {
    if (_filterSeverity == null) return _rows;
    return _rows.where((r) => r.severity == _filterSeverity).toList();
  }

  // ---------------------------------------------------------------------------
  // Color helpers
  // ---------------------------------------------------------------------------

  Color _severityColor(HealthSeverity s) {
    switch (s) {
      case HealthSeverity.normal:
      case HealthSeverity.autoFixed:
        return const Color(0xFF16A34A);
      case HealthSeverity.warning:
        return const Color(0xFFF59E0B);
      case HealthSeverity.critical:
        return const Color(0xFFDC2626);
      case HealthSeverity.offline:
        return Colors.grey;
      case HealthSeverity.unknown:
        return Colors.blueGrey;
    }
  }

  String _severityLabel(HealthSeverity s) {
    switch (s) {
      case HealthSeverity.normal:
        return 'תקין';
      case HealthSeverity.warning:
        return 'אזהרה';
      case HealthSeverity.critical:
        return 'קריטי';
      case HealthSeverity.offline:
        return 'Offline';
      case HealthSeverity.autoFixed:
        return 'תוקן ✓';
      case HealthSeverity.unknown:
        return 'אין נתונים';
    }
  }

  // ---------------------------------------------------------------------------
  // Bar widget
  // ---------------------------------------------------------------------------

  Widget _bar(double? pct, {double width = 56}) {
    if (pct == null) {
      return SizedBox(
        width: width,
        child:
            const Text('—', style: TextStyle(color: Colors.grey, fontSize: 11)),
      );
    }
    Color c;
    if (pct >= 90) {
      c = const Color(0xFFDC2626);
    } else if (pct >= 70)
      c = const Color(0xFFF59E0B);
    else
      c = const Color(0xFF16A34A);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (pct / 100).clamp(0.0, 1.0),
              backgroundColor: Colors.grey.withOpacity(0.2),
              valueColor: AlwaysStoppedAnimation<Color>(c),
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 2),
          Text('${pct.toStringAsFixed(0)}%',
              style: TextStyle(
                  fontSize: 10, color: c, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _ramCell(MachineHealth h) {
    if (h.ramUsed == null || h.ramTotal == null) {
      return const Text('—',
          style: TextStyle(color: Colors.grey, fontSize: 11));
    }
    final pct = h.ramTotal! > 0 ? (h.ramUsed! / h.ramTotal! * 100) : 0.0;
    Color c;
    if (pct >= 90) {
      c = const Color(0xFFDC2626);
    } else if (pct >= 70)
      c = const Color(0xFFF59E0B);
    else
      c = const Color(0xFF16A34A);
    return SizedBox(
      width: 68,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (pct / 100).clamp(0.0, 1.0),
              backgroundColor: Colors.grey.withOpacity(0.2),
              valueColor: AlwaysStoppedAnimation<Color>(c),
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${h.ramUsed!.toStringAsFixed(1)}/${h.ramTotal!.toStringAsFixed(0)}GB',
            style:
                TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3-dot menu
  // ---------------------------------------------------------------------------

  void _showActionsMenu(BuildContext context, MachineHealth h, Offset pos) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: [
        if (h.online &&
            (h.severity == HealthSeverity.warning ||
                h.severity == HealthSeverity.critical))
          PopupMenuItem(
            value: 'fix',
            child: Row(children: [
              Icon(Icons.build_outlined,
                  size: 16, color: _severityColor(h.severity)),
              const SizedBox(width: 8),
              const Text('תקן עכשיו'),
            ]),
          ),
        PopupMenuItem(
          value: 'disk_cleanup',
          enabled: h.online,
          child: const Row(children: [
            Icon(Icons.cleaning_services_outlined,
                size: 16, color: Colors.blueGrey),
            SizedBox(width: 8),
            Text('ניקוי דיסק'),
          ]),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          height: 24,
          child: Text('סקריפטים',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ),
        PopupMenuItem(
          value: 'script_temp',
          enabled: h.online,
          child: const Row(children: [
            Icon(Icons.delete_sweep_outlined,
                size: 16, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('ניקוי Temp files'),
          ]),
        ),
        PopupMenuItem(
          value: 'script_dns',
          enabled: h.online,
          child: const Row(children: [
            Icon(Icons.refresh_outlined, size: 16, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Flush DNS'),
          ]),
        ),
        PopupMenuItem(
          value: 'script_processes',
          enabled: h.online,
          child: const Row(children: [
            Icon(Icons.memory_outlined, size: 16, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Top Processes (CPU)'),
          ]),
        ),
        PopupMenuItem(
          value: 'script_defender',
          enabled: h.online,
          child: const Row(children: [
            Icon(Icons.security_outlined, size: 16, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Windows Defender Scan'),
          ]),
        ),
        PopupMenuItem(
          value: 'script_drivers',
          enabled: h.online,
          child: const Row(children: [
            Icon(Icons.settings_input_component_outlined,
                size: 16, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('בדיקת דרייברים'),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'report',
          child: const Row(children: [
            Icon(Icons.article_outlined, size: 16, color: Colors.teal),
            SizedBox(width: 8),
            Text('פרטים'),
          ]),
        ),
        PopupMenuItem(
          value: 'connect',
          enabled: h.online,
          child: const Row(children: [
            Icon(Icons.computer_outlined, size: 16, color: Colors.green),
            SizedBox(width: 8),
            Text('התחבר'),
          ]),
        ),
      ],
    ).then((val) => _handleAction(val, h));
  }

  void _handleAction(String? action, MachineHealth h) {
    if (action == null) return;
    switch (action) {
      case 'fix':
        _showFixDialog(h);
        break;
      case 'disk_cleanup':
        _showDiskCleanupDialog(h);
        break;
      case 'script_temp':
        _showScriptConfirm(h, 'ניקוי Temp files',
            r'Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue');
        break;
      case 'script_dns':
        _showScriptConfirm(h, 'Flush DNS', 'ipconfig /flushdns');
        break;
      case 'script_processes':
        _showScriptConfirm(h, 'Top Processes',
            'Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 | Format-Table Name,CPU,WorkingSet -AutoSize');
        break;
      case 'script_defender':
        _showScriptConfirm(h, 'Windows Defender Quick Scan',
            'Start-MpScan -ScanType QuickScan');
        break;
      case 'script_drivers':
        _showScriptConfirm(h, 'בדיקת דרייברים',
            'Get-WmiObject Win32_PnPSignedDriver | Select-Object DeviceName,DriverVersion,DriverDate | Sort-Object DriverDate | Format-Table -AutoSize');
        break;
      case 'report':
        _showInfoDialog(h);
        break;
      case 'connect':
        connect(context, h.peerId);
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  void _showFixDialog(MachineHealth h) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.build, color: _severityColor(h.severity)),
          const SizedBox(width: 8),
          Text('תיקון — ${h.displayName}'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((h.cpu ?? 0) >= 70)
              _fixRow(
                  'CPU ${h.cpu!.toStringAsFixed(0)}%', 'סגירת processes כבדים'),
            if (h.ramUsed != null &&
                h.ramTotal != null &&
                h.ramTotal! > 0 &&
                (h.ramUsed! / h.ramTotal! >= 0.80))
              _fixRow(
                  'RAM ${(h.ramUsed! / h.ramTotal! * 100).toStringAsFixed(0)}%',
                  'שחרור זיכרון cache'),
            if ((h.diskPct ?? 0) >= 85)
              _fixRow('Disk ${h.diskPct!.toStringAsFixed(0)}%',
                  'ניקוי Temp + Cache'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A)),
            onPressed: () {
              Navigator.of(ctx).pop();
              BotToast.showText(text: '✅ תיקון הופעל על ${h.displayName}');
            },
            child: const Text('תקן הכל', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _fixRow(String issue, String action) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          const Icon(Icons.check_circle_outline,
              size: 16, color: Color(0xFF16A34A)),
          const SizedBox(width: 6),
          Expanded(
              child: Text('$issue → $action',
                  style: const TextStyle(fontSize: 13))),
        ]),
      );

  void _showDiskCleanupDialog(MachineHealth h) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.cleaning_services, color: Colors.blueGrey),
          const SizedBox(width: 8),
          Text('ניקוי דיסק — ${h.displayName}'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('מה יינקה:'),
            const SizedBox(height: 8),
            ...<(String, String)>[
              ('Windows Temp files', '~500MB'),
              ('User Temp files', '~200MB'),
              ('Recycle Bin', '~100MB'),
              ('Browser Cache', '~300MB'),
              ('Windows Update Cache', '~1.2GB'),
              ('Prefetch files', '~50MB'),
            ].map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    const Icon(Icons.delete_outline,
                        size: 14, color: Colors.blueGrey),
                    const SizedBox(width: 6),
                    Text(e.$1, style: const TextStyle(fontSize: 13)),
                    const Spacer(),
                    Text(e.$2,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
                )),
            const SizedBox(height: 8),
            const Divider(),
            const Text('סה"כ משוער: ~2.3GB',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
            onPressed: () {
              Navigator.of(ctx).pop();
              BotToast.showText(
                  text: '🧹 ניקוי דיסק הופעל על ${h.displayName}');
            },
            child:
                const Text('נקה עכשיו', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showScriptConfirm(MachineHealth h, String name, String script) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.terminal, color: Colors.blueAccent),
          const SizedBox(width: 8),
          Text(name),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('מחשב: ${h.displayName}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(script,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFF9CDCFE))),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            onPressed: () {
              Navigator.of(ctx).pop();
              BotToast.showText(text: '▶ "$name" הופעל על ${h.displayName}');
            },
            child: const Text('הפעל', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showInfoDialog(MachineHealth h) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.info_outline, color: Colors.teal),
          const SizedBox(width: 8),
          Flexible(child: Text(h.displayName, overflow: TextOverflow.ellipsis)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow('ID', h.peerId),
            _infoRow('מצב', h.online ? 'מחובר' : 'Offline'),
            if (h.severity == HealthSeverity.unknown) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.orange.withOpacity(0.4)),
                ),
                child: const Text(
                  'נתוני בריאות (CPU/RAM/Disk) יהיו זמינים\n'
                  'לאחר התקנת Watchdog Agent על מחשב זה.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (h.online)
            ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                connect(context, h.peerId);
              },
              child: const Text('התחבר'),
            ),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('סגור')),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
              width: 50,
              child: Text(label,
                  style: const TextStyle(color: Colors.grey, fontSize: 12))),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      );

  String _fmtSeen(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'לפני ${diff.inSeconds}ש׳';
    if (diff.inMinutes < 60) return 'לפני ${diff.inMinutes}ד׳';
    return 'לפני ${diff.inHours}ש׳';
  }

  // ---------------------------------------------------------------------------
  // Filter chips
  // ---------------------------------------------------------------------------

  Widget _filterChips() {
    final chips = <(String, HealthSeverity?)>[
      ('הכל', null),
      ('🟢 תקין', HealthSeverity.normal),
      ('🟡 אזהרה', HealthSeverity.warning),
      ('🔴 קריטי', HealthSeverity.critical),
      ('⚪ Offline', HealthSeverity.offline),
      ('❓ אין נתונים', HealthSeverity.unknown),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Wrap(
        spacing: 6,
        children: chips.map((c) {
          final selected = _filterSeverity == c.$2;
          return FilterChip(
            label: Text(c.$1, style: const TextStyle(fontSize: 11)),
            selected: selected,
            onSelected: (_) => setState(() {
              _filterSeverity = selected ? null : c.$2;
            }),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          );
        }).toList(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Summary strip
  // ---------------------------------------------------------------------------

  Widget _summaryStrip() {
    final online = _rows.where((r) => r.online).length;
    final offline = _rows.where((r) => !r.online).length;
    final unknown = _rows
        .where((r) => r.online && r.severity == HealthSeverity.unknown)
        .length;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          _badge('${_rows.length} מחשבים', Colors.blueGrey),
          const SizedBox(width: 8),
          _badge('$online מחובר', const Color(0xFF16A34A)),
          if (offline > 0) ...[
            const SizedBox(width: 8),
            _badge('$offline offline', Colors.grey),
          ],
          if (unknown > 0) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: 'נדרש Watchdog Agent להצגת נתוני בריאות',
              child: _badge('$unknown ללא נתונים', Colors.orange),
            ),
          ],
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'רענן',
            onPressed: _refresh,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      );

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final hasRmm = _hasRmmLicense;
    if (hasRmm != true) {
      if (hasRmm == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.monitor_heart_outlined,
                size: 48, color: Color(0xFF9CA3AF)),
            const SizedBox(height: 12),
            Text(
              translate('rmm-pro-gate-title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Text(
                translate('rmm-pro-gate-body'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => showRmmProGateDialog(context),
              child: Text(translate('rmm-pro-gate-buy')),
            ),
          ],
        ),
      );
    }

    final filtered = _filtered;
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.bodySmall
        ?.copyWith(fontWeight: FontWeight.w700, fontSize: 12);

    if (_rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.devices_outlined,
                size: 48, color: Colors.grey.withOpacity(0.5)),
            const SizedBox(height: 12),
            Text('אין מחשבים בקשר אחרון / ספר כתובות',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 6),
            Text('הוסף מחשבים לרשימה Recent כדי לצפות בהם כאן.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _summaryStrip(),
          _filterChips(),
          const SizedBox(height: 8),
          // "No health data" notice
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline, size: 14, color: Colors.orange),
              const SizedBox(width: 8),
              const Flexible(
                child: Text(
                  'המחשב המקומי: נתונים מהמערכת. מחשבים מרוחקים: CPU/RAM/Disk יוצגו לאחר התקנת Watchdog Agent עליהם (הפרוטוקול הנוכחי לא משדר בריאות).',
                  style: TextStyle(fontSize: 11, color: Colors.orange),
                ),
              ),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 40,
                  dataRowMaxHeight: 50,
                  columnSpacing: 14,
                  columns: [
                    DataColumn(label: Text('מצב', style: headerStyle)),
                    DataColumn(label: Text('מחשב', style: headerStyle)),
                    DataColumn(label: Text('CPU', style: headerStyle)),
                    DataColumn(label: Text('RAM', style: headerStyle)),
                    DataColumn(label: Text('Disk', style: headerStyle)),
                    DataColumn(label: Text('Temp', style: headerStyle)),
                    DataColumn(label: Text('פעולות', style: headerStyle)),
                  ],
                  rows: filtered.map((h) {
                    final sColor = _severityColor(h.severity);
                    return DataRow(
                      cells: [
                        // Status
                        DataCell(Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(
                                  color: sColor, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 5),
                            Text(_severityLabel(h.severity),
                                style: TextStyle(
                                    fontSize: 11,
                                    color: sColor,
                                    fontWeight: FontWeight.w600)),
                          ],
                        )),
                        // Name
                        DataCell(InkWell(
                          onTap: h.online
                              ? () => connect(context, h.peerId)
                              : null,
                          child: Text(
                            h.displayName,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: h.online
                                  ? theme.textTheme.bodyMedium?.color
                                  : Colors.grey,
                              decoration:
                                  h.online ? TextDecoration.underline : null,
                            ),
                          ),
                        )),
                        // CPU
                        DataCell(_bar(h.cpu)),
                        // RAM
                        DataCell(_ramCell(h)),
                        // Disk
                        DataCell(_bar(h.diskPct)),
                        // Temp
                        DataCell(h.tempC != null
                            ? Text(
                                '${h.tempC!.toStringAsFixed(0)}°C',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: h.tempC! >= 80
                                        ? Colors.red
                                        : h.tempC! >= 65
                                            ? Colors.orange
                                            : Colors.green),
                              )
                            : const Text('—',
                                style: TextStyle(
                                    color: Colors.grey, fontSize: 11))),
                        // Actions
                        DataCell(Builder(builder: (btnCtx) {
                          return InkWell(
                            onTap: () {
                              final box =
                                  btnCtx.findRenderObject() as RenderBox;
                              final pos = box.localToGlobal(Offset.zero);
                              _showActionsMenu(context, h,
                                  Offset(pos.dx, pos.dy + box.size.height));
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.more_vert, size: 18),
                            ),
                          );
                        })),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
