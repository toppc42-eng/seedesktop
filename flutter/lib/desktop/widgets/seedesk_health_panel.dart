import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/windows_terminal_health.dart';

/// Structured SeeDesk health from VPS `seedesk_health` (`checks`, `errors`).
class SeedeskHealthPanel extends StatelessWidget {
  const SeedeskHealthPanel({
    super.key,
    this.seedeskHealth,
    this.compact = false,
  });

  final Map<String, dynamic>? seedeskHealth;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final sh = seedeskHealth;
    if (sh == null || sh.isEmpty) {
      if (compact) return const SizedBox.shrink();
      return Text(
        'אין נתוני בריאות מובנים מהשרת.',
        style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
      );
    }

    final errs = sh['errors'];
    final errList = <String>[];
    if (errs is List) {
      for (final e in errs) {
        final t = e?.toString().trim() ?? '';
        if (t.isNotEmpty) errList.add(t);
      }
    }

    final rawChecks = sh['checks'];
    final rows = <Map<String, dynamic>>[];
    if (rawChecks is List) {
      for (final e in rawChecks) {
        if (e is Map<String, dynamic>) {
          rows.add(e);
        } else if (e is Map) {
          rows.add(Map<String, dynamic>.from(e));
        }
      }
    }

    if (rows.isEmpty && errList.isEmpty) {
      if (compact) return const SizedBox.shrink();
      return Text(
        'דוח ריק או בלי בדיקות.',
        style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
      );
    }

    final pad = compact
        ? const EdgeInsets.only(top: 4)
        : const EdgeInsets.only(top: 6);

    return Padding(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact)
            Text(
              'בדיקות SeeDesk',
              style: TextStyle(
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w700,
                color: Colors.blueGrey.shade800,
              ),
            ),
          if (!compact) const SizedBox(height: 4),
          if (errList.isNotEmpty) ...[
            Text(
              'שגיאות איסוף:',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            ...errList.map(
              (e) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  e,
                  style: TextStyle(
                    fontSize: 9,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
            SizedBox(height: compact ? 4 : 6),
          ],
          ...rows.map((c) {
            final id = c['id']?.toString() ?? 'unknown';
            final st = (c['status']?.toString() ?? 'ok').toLowerCase();
            final detail = c['detail']?.toString() ?? '';
            final remediated = c['remediated'] == true;
            return Padding(
              padding: EdgeInsets.only(bottom: compact ? 4 : 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      healthStatusIcon(st),
                      size: compact ? 10 : 12,
                      color: healthStatusColor(st, context),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                healthCheckLabelHe(id),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: compact ? 10 : 11,
                                ),
                              ),
                            ),
                            if (remediated)
                              Text(
                                'תוקן',
                                style: TextStyle(
                                  fontSize: 8,
                                  color: Colors.teal.shade700,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                        if (detail.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            detail,
                            style: TextStyle(
                              fontSize: compact ? 9 : 10,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// סטטוס בריאות מובנה (`health_verdict` מהשרת — `ok` / `warn` / `error`).
class HealthVerdict {
  const HealthVerdict({
    required this.status,
    this.labelHe = '',
    this.detailHe = '',
  });

  final String status;
  final String labelHe;
  final String detailHe;

  static const String kStatusOk = 'ok';
  static const String kStatusWarn = 'warn';
  static const String kStatusError = 'error';
}

/// `health_verdict` — ירוק / כתום / אדום / אפור (משמש סרגל צד וטבלת מכשירים).
class RmmHealthVerdictStrip extends StatelessWidget {
  const RmmHealthVerdictStrip({
    super.key,
    required this.verdict,
    this.dense = false,
  });

  final HealthVerdict verdict;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color border;
    Color fg;
    switch (verdict.status) {
      case HealthVerdict.kStatusOk:
        bg = const Color(0xFFDCFCE7);
        border = const Color(0xFF86EFAC);
        fg = const Color(0xFF166534);
        break;
      case HealthVerdict.kStatusWarn:
        bg = Colors.orange.shade50;
        border = Colors.orange.shade200;
        fg = Colors.orange.shade900;
        break;
      case HealthVerdict.kStatusError:
        bg = Colors.red.shade50;
        border = Colors.red.shade200;
        fg = Colors.red.shade900;
        break;
      default:
        bg = Colors.blueGrey.shade50;
        border = Colors.blueGrey.shade200;
        fg = Colors.blueGrey.shade800;
    }

    final title = verdict.labelHe.trim().isNotEmpty
        ? verdict.labelHe.trim()
        : _fallbackTitle(verdict.status);
    final detail = verdict.detailHe.trim();

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
          if (detail.isNotEmpty) ...[
            SizedBox(height: dense ? 1 : 2),
            Text(
              detail,
              style: TextStyle(
                fontSize: dense ? 9 : 10,
                height: 1.25,
                color: fg.withOpacity(0.92),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _fallbackTitle(String status) {
    switch (status) {
      case HealthVerdict.kStatusOk:
        return 'תקין';
      case HealthVerdict.kStatusWarn:
        return 'אזהרה';
      case HealthVerdict.kStatusError:
        return 'יש בעיה';
      default:
        return 'אין נתוני בריאות';
    }
  }
}

/// התראות שרת (`alerts`) — למשל `cpu_high`.
class RmmServerAlertsStrip extends StatelessWidget {
  const RmmServerAlertsStrip({
    super.key,
    required this.alerts,
    this.dense = false,
  });

  final List<Map<String, dynamic>> alerts;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (alerts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: dense ? 6 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: alerts.map((al) {
          final id = al['id']?.toString() ?? 'alert';
          final msg = al['message']?.toString() ?? '';
          final sev =
              (al['severity'] ?? al['level'] ?? '').toString().toLowerCase();
          final critical = sev == 'critical' || sev == 'error' || sev == 'fatal';
          final bg = critical
              ? Colors.red.shade50
              : Colors.amber.shade50;
          final br = critical
              ? Colors.red.shade200
              : Colors.amber.shade200;
          final fg = critical
              ? Colors.red.shade900
              : Colors.amber.shade900;
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: br),
              ),
              child: Text(
                msg.isNotEmpty ? '$id: $msg' : id,
                style: TextStyle(
                  fontSize: dense ? 9 : 10,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
