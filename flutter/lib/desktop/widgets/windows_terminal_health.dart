import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Markers must match the PowerShell script output exactly.
const String kSeedeskHealthStart = '<<<SEEDESK_HEALTH_START>>>';
const String kSeedeskHealthEnd = '<<<SEEDESK_HEALTH_END>>>';

/// **דוח מצב מחשב (Windows)** — העתקה ידנית / תיעוד.
/// מריץ ב-PowerShell על המחשב המרוחק; הפלט בין המרקרים נסרק בצד הלקוח.
///
/// שימוש מקוצר אחרי encoding ל־UTF-16LE: ראה [buildWindowsHealthPowershellCommand].
const String kWindowsHealthDashboardScript = r'''
$ErrorActionPreference='SilentlyContinue'
$r=[ordered]@{generated_at=(Get-Date -Format s);checks=@()}
$os=Get-CimInstance Win32_OperatingSystem
$tot=[double]$os.TotalVisibleMemorySize*1024
$free=[double]$os.FreePhysicalMemory*1024
$upct=0;if($tot -gt 0){$upct=[math]::Round(100*($tot-$free)/$tot,1)}
$ms='ok';if($upct -ge 85){$ms='warn'};if($upct -ge 92){$ms='critical'}
$r.checks+=@{id='memory';status=$ms;detail=($upct.ToString()+' pct used');v=$upct}
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'|ForEach-Object{
  $dv=($_.DeviceID -replace '\\$','')
  if($_.Size -gt 0){
    $fp=[math]::Round(100*$_.FreeSpace/$_.Size,1)
    $ds='ok';if($fp -lt 15){$ds='warn'};if($fp -lt 10){$ds='critical'}
    $id=('disk_'+$dv)
    $r.checks+=@{id=$id;status=$ds;detail=($_.DeviceID+' '+$fp.ToString()+' pct free');v=$fp}
  }
}
$upt=([datetime]::Now-$os.LastBootUpTime).TotalHours
$r.checks+=@{id='uptime';status='ok';detail=([string]::Format('{0:N1} hours',$upt));v=$upt}
$cap=($os.Caption+' '+$os.Version).Trim()
$r.checks+=@{id='os';status='ok';detail=$cap;v=0}
$j=$r|ConvertTo-Json -Depth 8 -Compress
Write-Output '<<<SEEDESK_HEALTH_START>>>'
Write-Output $j
Write-Output '<<<SEEDESK_HEALTH_END>>>'
''';

/// PowerShell -EncodedCommand expects UTF-16LE (BMP safe for this script).
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

/// Full command line to paste into the remote shell (includes trailing newline caller).
String buildWindowsHealthPowershellCommand() {
  final enc = base64Encode(_utf16LeBytes(kWindowsHealthDashboardScript));
  return 'powershell.exe -NoProfile -NonInteractive -EncodedCommand $enc';
}

String stripAnsiTerminal(String s) {
  return s
      .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\x1b\][^\x07]*\x07'), '');
}

class HealthCheckRow {
  HealthCheckRow({
    required this.id,
    required this.status,
    required this.detail,
  });

  final String id;
  final String status;
  final String detail;
}

class WindowsHealthReport {
  WindowsHealthReport({
    required this.generatedAt,
    required this.checks,
  });

  final String generatedAt;
  final List<HealthCheckRow> checks;
}

WindowsHealthReport? parseWindowsHealthCapture(String raw) {
  final stripped = stripAnsiTerminal(raw);
  final si = stripped.lastIndexOf(kSeedeskHealthStart);
  final ei = stripped.lastIndexOf(kSeedeskHealthEnd);
  if (si < 0 || ei < 0 || ei <= si) return null;
  var jsonStr = stripped.substring(si + kSeedeskHealthStart.length, ei).trim();
  jsonStr = jsonStr.replaceAll(RegExp(r'^\uFEFF'), '');
  // Prompt noise before JSON (e.g. PS C:\>)
  final brace = jsonStr.indexOf('{');
  if (brace > 0) jsonStr = jsonStr.substring(brace);
  if (jsonStr.isEmpty) return null;
  try {
    final obj = jsonDecode(jsonStr) as Map<String, dynamic>;
    final rawChecks = obj['checks'];
    final checks = <HealthCheckRow>[];
    void addCheckFromMap(Map<String, dynamic> m) {
      checks.add(HealthCheckRow(
        id: m['id']?.toString() ?? 'unknown',
        status: (m['status']?.toString() ?? 'ok').toLowerCase(),
        detail: m['detail']?.toString() ?? '',
      ));
    }

    if (rawChecks is List) {
      for (final e in rawChecks) {
        if (e is! Map) continue;
        addCheckFromMap(Map<String, dynamic>.from(e));
      }
    } else if (rawChecks is Map) {
      // PowerShell ConvertTo-Json may emit a single object instead of [object]
      addCheckFromMap(Map<String, dynamic>.from(rawChecks));
    }
    return WindowsHealthReport(
      generatedAt: obj['generated_at']?.toString() ?? '',
      checks: checks,
    );
  } catch (_) {
    return null;
  }
}

String healthCheckLabelHe(String id) {
  switch (id) {
    case 'memory':
      return 'זיכרון';
    case 'uptime':
      return 'זמן פעילות';
    case 'os':
      return 'מערכת הפעלה';
    default:
      if (id.startsWith('disk_')) {
        final letter = id.substring(5);
        return 'דיסק $letter';
      }
      return id;
  }
}

Color healthStatusColor(String status, BuildContext context) {
  switch (status) {
    case 'critical':
      return Colors.red.shade700;
    case 'warn':
    case 'warning':
      return Colors.amber.shade800;
    default:
      return Colors.green.shade700;
  }
}

IconData healthStatusIcon(String status) {
  switch (status) {
    case 'critical':
      return Icons.circle;
    case 'warn':
    case 'warning':
      return Icons.circle;
    default:
      return Icons.circle;
  }
}

/// Fixed-width left rail for Windows remote health summary.
class WindowsHealthSidebar extends StatelessWidget {
  const WindowsHealthSidebar({
    super.key,
    required this.report,
    required this.error,
    required this.loading,
    required this.onRefresh,
    this.width = 300,
  });

  final WindowsHealthReport? report;
  final String? error;
  final bool loading;
  final VoidCallback onRefresh;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Material(
        elevation: 1,
        color: theme.colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: theme.dividerColor, width: 1),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.monitor_heart_outlined,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'מצב מחשב (Windows)',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'רענן נתונים',
                    icon: loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 20),
                    onPressed: loading ? null : onRefresh,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _buildBody(context, theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ThemeData theme) {
    if (loading && report == null && (error == null || error!.isEmpty)) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (error != null && error!.isNotEmpty && report == null) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Text(
          error!,
          style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
        ),
      );
    }
    if (report == null) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Text(
          'לחץ «רענן נתונים» לטעינת דוח',
          style: TextStyle(color: theme.hintColor, fontSize: 12),
        ),
      );
    }
    final r = report!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      children: [
        if (r.generatedAt.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'עודכן: ${r.generatedAt}',
              style: TextStyle(fontSize: 10, color: theme.hintColor),
            ),
          ),
        ...r.checks.map((c) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      healthStatusIcon(c.status),
                      size: 12,
                      color: healthStatusColor(c.status, context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          healthCheckLabelHe(c.id),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          c.detail,
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )),
        if (loading)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        if (error != null && error!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 11),
            ),
          ),
      ],
    );
  }
}
