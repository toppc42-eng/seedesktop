import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';

/// Visualizes `hw_health` JSON (temp, fan, processor id, disks + traffic lights).
class HardwareHealthView extends StatefulWidget {
  const HardwareHealthView({
    super.key,
    required this.hwHealth,
    this.padding = const EdgeInsets.fromLTRB(12, 4, 10, 8),
    this.showTitle = true,
    this.ramUsageLine,
  });

  final Map<String, dynamic>? hwHealth;
  final EdgeInsets padding;
  final bool showTitle;

  /// Second line under RAM specs (e.g. server `ram_usage` or local `ram_used_gb` / `ram_total_gb` summary).
  final String? ramUsageLine;

  @override
  State<HardwareHealthView> createState() => _HardwareHealthViewState();
}

class _HardwareHealthViewState extends State<HardwareHealthView>
    with SingleTickerProviderStateMixin {
  late AnimationController _fanRotation;

  @override
  void initState() {
    super.initState();
    _fanRotation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    _syncFan(widget.hwHealth);
  }

  @override
  void didUpdateWidget(covariant HardwareHealthView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hwHealth != widget.hwHealth) {
      _syncFan(widget.hwHealth);
    }
  }

  void _syncFan(Map<String, dynamic>? hw) {
    final rpm = _readFanRpm(hw);
    if (rpm != null && rpm > 0) {
      if (!_fanRotation.isAnimating) _fanRotation.repeat();
    } else {
      _fanRotation.stop();
      _fanRotation.reset();
    }
  }

  @override
  void dispose() {
    _fanRotation.dispose();
    super.dispose();
  }

  int? _readFanRpm(Map<String, dynamic>? hw) {
    if (hw == null) return null;
    final v = hw['fan_rpm'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  String? _hwStrDetail(dynamic v) {
    final s = v?.toString().trim() ?? '';
    if (s.isEmpty || s.toLowerCase() == 'unknown') return null;
    return s;
  }

  String? _slotsFromHw(Map<String, dynamic> hw) {
    final u = _hwStrDetail(hw['ram_slots_usage']);
    if (u != null) return u;
    final su = hw['ram_slots_used'];
    final st = hw['ram_slots_total'];
    int? iu;
    int? it;
    if (su is int) {
      iu = su;
    } else if (su is num) {
      iu = su.toInt();
    } else {
      iu = int.tryParse(su?.toString() ?? '');
    }
    if (st is int) {
      it = st;
    } else if (st is num) {
      it = st.toInt();
    } else {
      it = int.tryParse(st?.toString() ?? '');
    }
    if (iu != null && it != null) return '$iu/$it';
    if (iu != null) return '$iu';
    return null;
  }

  String _fmtGbSidebar(double? g) {
    if (g == null) return '—';
    if ((g - g.roundToDouble()).abs() < 0.05) return g.round().toString();
    return g.toStringAsFixed(1);
  }

  Widget _ramSpecsColumn(Map<String, dynamic> hw) {
    final t = _hwStrDetail(hw['ram_type']);
    final s = _hwStrDetail(hw['ram_speed']);
    final slots = _slotsFromHw(hw);
    final line1 =
        '${t ?? 'Unknown'} @ ${s ?? 'Unknown'} (Slots: ${slots ?? '—'})';
    final line2 = widget.ramUsageLine?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          line1,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
          ),
        ),
        Text(
          (line2 != null && line2.isNotEmpty) ? line2 : '—',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 9,
            color: Colors.blueGrey.shade600,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }

  Color _statusDot(String? status) {
    switch (status) {
      case 'green':
        return const Color(0xFF16A34A);
      case 'yellow':
        return const Color(0xFFF59E0B);
      case 'red':
        return const Color(0xFFDC2626);
      default:
        return Colors.blueGrey.shade400;
    }
  }

  Widget _dot(Color c) => Container(
        width: 8,
        height: 8,
        margin: const EdgeInsets.only(top: 3),
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: c.withOpacity(0.45),
              blurRadius: 3,
            ),
          ],
        ),
      );

  /// Per-core temperatures from `hw_health.cpu_cores_temp_c` (LibreHardwareMonitor).
  /// Returns SizedBox.shrink() when empty (e.g. non-elevated process or no LHM driver).
  Widget _buildCoreTempsList(Map<String, dynamic> hw) {
    final raw = hw['cpu_cores_temp_c'];
    if (raw is! List || raw.isEmpty) return const SizedBox.shrink();

    final entries = <(String, double)>[];
    for (final c in raw) {
      if (c is! Map) continue;
      final name = c['name']?.toString().trim() ?? '';
      final t = c['temp_c'];
      double? tempC;
      if (t is num) tempC = t.toDouble();
      if (tempC == null) continue;
      entries.add((name.isEmpty ? 'Core' : name, tempC));
    }
    if (entries.isEmpty) return const SizedBox.shrink();

    Color colorForTemp(double t) {
      if (t < 70) return const Color(0xFF16A34A);
      if (t <= 85) return const Color(0xFFF59E0B);
      return const Color(0xFFDC2626);
    }

    return Padding(
      padding: const EdgeInsets.only(left: 14, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (name, temp) in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colorForTemp(temp),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.blueGrey.shade700,
                      ),
                    ),
                  ),
                  Text(
                    '${temp.toStringAsFixed(0)}°C',
                    style: const TextStyle(
                      fontSize: 9,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _metricRow({
    required String label,
    required String? status,
    required Widget child,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dot(_statusDot(status)),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.blueGrey.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child,
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hw = widget.hwHealth;
    if (hw == null || hw.isEmpty) {
      return const SizedBox.shrink();
    }

    final disksRaw = hw['disks'];
    final diskList = disksRaw is List ? disksRaw : const <dynamic>[];
    final procId = hw['cpu_processor_id']?.toString();
    final hasProcId = procId != null && procId.isNotEmpty;

    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showTitle) ...[
            Row(
              children: [
                Icon(Icons.memory, size: 14, color: Colors.blueGrey.shade600),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    translate('hw-sidebar-title'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          _metricRow(
            label: translate('hw-cpu-temp'),
            status: hw['temp_status'] as String?,
            child: Text(
              hw['cpu_temp_c'] != null
                  ? '${(hw['cpu_temp_c'] as num).toStringAsFixed(1)} °C'
                  : '—',
              style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
            ),
          ),
          _buildCoreTempsList(hw),
          const SizedBox(height: 6),
          _metricRow(
            label: translate('hw-cpu-fan'),
            status: hw['fan_status'] as String?,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RotationTransition(
                  turns: _fanRotation,
                  child: Icon(Icons.air,
                      size: 16, color: Colors.blueGrey.shade700),
                ),
                const SizedBox(width: 4),
                Text(
                  _readFanRpm(hw) != null
                      ? '${_readFanRpm(hw)} ${translate('hw-rpm')}'
                      : '—',
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          _metricRow(
            label: 'RAM',
            status: null,
            child: _ramSpecsColumn(hw),
          ),
          if (hasProcId) ...[
            const SizedBox(height: 6),
            Text(
              translate('hw-processor-id'),
              style: TextStyle(fontSize: 9, color: Colors.blueGrey.shade600),
            ),
            const SizedBox(height: 2),
            SelectableText(
              procId,
              style: const TextStyle(fontSize: 9, fontFamily: 'monospace'),
            ),
          ],
          if (diskList.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              translate('hw-disks'),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            ...diskList.map((dynamic d) {
              if (d is! Map) return const SizedBox.shrink();
              final m = Map<String, dynamic>.from(d);
              final id = m['id']?.toString() ?? '';
              final freePct = (m['free_pct'] as num?)?.toDouble() ?? 0.0;
              final health = m['health']?.toString();
              var dm =
                  (m['disk_model'] ?? m['model'])?.toString().trim() ?? '';
              var dt =
                  (m['disk_type'] ?? m['type'])?.toString().trim() ?? '';
              if (dm.isEmpty || dm.toLowerCase() == 'unknown') {
                dm = 'Unknown';
              }
              if (dt.isEmpty || dt.toLowerCase() == 'unknown') {
                dt = 'Unknown';
              }
              final totalGb = (m['total_gb'] as num?)?.toDouble();
              final freeGb = (m['free_gb'] as num?)?.toDouble();
              final line2 =
                  '${_fmtGbSidebar(freeGb)}GB free of ${_fmtGbSidebar(totalGb)}GB (${freePct.toStringAsFixed(0)}%)';
              final line1Prefix = id.isEmpty ? '' : '$id · ';
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _dot(_statusDot(health)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '$line1Prefix$dt - $dm',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            line2,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.blueGrey.shade600,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}
