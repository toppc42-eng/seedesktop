import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_hbb/common.dart' show translate;
import 'package:flutter_hbb/consts.dart' show kCommConfKeyLang;
import 'package:flutter_hbb/models/platform_model.dart' show bind;
import 'package:flutter_hbb/utils/freemium_guard.dart'
    show canUseRmmItTroubleshootingChatLocal;
import 'package:flutter_hbb/utils/local_maintenance_service.dart';

const Color _kItHelpAccent = Color(0xFF2F65BA);

/// Renders IT Support chat **only for Pro-R-MM** (`SD-PRORMM-*`).
/// Mounted on RMM dashboards (e.g. [LocalMaintenancePage]); not on end-user-only home.
class ItTroubleshootingChatIfRmm extends StatefulWidget {
  const ItTroubleshootingChatIfRmm({
    super.key,
    this.panelBelowTrigger = false,
    this.compactTrigger = false,
  });

  final bool panelBelowTrigger;
  final bool compactTrigger;

  @override
  State<ItTroubleshootingChatIfRmm> createState() =>
      _ItTroubleshootingChatIfRmmState();
}

class _ItTroubleshootingChatIfRmmState extends State<ItTroubleshootingChatIfRmm>
    with WidgetsBindingObserver {
  bool? _hasRmm;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshRmm());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshRmm());
    }
  }

  Future<void> _refreshRmm() async {
    final v = await canUseRmmItTroubleshootingChatLocal();
    if (mounted) setState(() => _hasRmm = v);
  }

  @override
  Widget build(BuildContext context) {
    if (_hasRmm != true) {
      return const SizedBox.shrink();
    }
    return ItTroubleshootingFloatingChat(
      panelBelowTrigger: widget.panelBelowTrigger,
      compactTrigger: widget.compactTrigger,
    );
  }
}

/// Floating IT troubleshooting chat — Pro-RMM technicians (RMM dashboard placement).
class ItTroubleshootingFloatingChat extends StatefulWidget {
  const ItTroubleshootingFloatingChat({
    super.key,
    this.panelBelowTrigger = false,
    this.compactTrigger = false,
  });

  final bool panelBelowTrigger;
  final bool compactTrigger;

  @override
  State<ItTroubleshootingFloatingChat> createState() =>
      _ItTroubleshootingFloatingChatState();
}

class _ChatMsg {
  _ChatMsg({
    required this.isUser,
    required this.text,
    this.isKbSolution = false,
  });
  final bool isUser;
  final String text;
  final bool isKbSolution;
}

class _KbEntry {
  _KbEntry({required this.issue, required this.solution});
  final String issue;
  final String solution;

  Map<String, String> toJson() => <String, String>{
        'issue': issue,
        'solution': solution,
      };

  static _KbEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final issue = value['issue'];
    final solution = value['solution'];
    if (issue is! String || solution is! String) return null;
    final trimmedIssue = issue.trim();
    if (trimmedIssue.isEmpty) return null;
    return _KbEntry(issue: trimmedIssue, solution: solution.trim());
  }
}

class _KbSearchResult {
  _KbSearchResult({
    required this.entry,
    required this.score,
    required this.matchedSolution,
    required this.solutionSnippet,
  });

  final _KbEntry entry;
  final int score;
  final bool matchedSolution;
  final String solutionSnippet;
}

class _DetectedCommand {
  const _DetectedCommand({
    required this.text,
    required this.isPowerShell,
  });
  final String text;
  final bool isPowerShell;
}

/// One numbered step block parsed out of an assistant solution message
/// (e.g. "שלב 1: 'זיהוי'\n<description>"). Rendered as a card with a
/// numbered badge, bold title, body, and an optional "הפעל" action.
class _StepBlock {
  _StepBlock({
    required this.number,
    required this.title,
    required this.body,
  });
  final String number;
  final String title;
  final String body;
}

class _ItTroubleshootingFloatingChatState
    extends State<ItTroubleshootingFloatingChat> {
  final ScrollController _scroll = ScrollController();
  final List<_ChatMsg> _messages = <_ChatMsg>[];
  final TextEditingController _kbSearchController = TextEditingController();
  final TextEditingController _kbWildcardFilterController =
      TextEditingController();

  bool _panelOpen = false;
  bool _maximized = false;
  bool _kbLoading = false;
  bool _kbSearchAttempted = false;
  List<_KbEntry> _kbEntries = <_KbEntry>[];
  List<_KbSearchResult> _kbSearchResults = <_KbSearchResult>[];
  _KbEntry? _selectedKbEntry;
  String _appliedKbQuery = '';
  String _kbWildcardFilter = '';
  String? _kbSearchError;

  /// Dynamic size for message bubbles (user + assistant).
  double _chatMessageFontSize = 14.0;

  static const double _fontMin = 12.0;
  static const double _fontMax = 24.0;
  static final RegExp _hebrewChars = RegExp(r'[\u0590-\u05FF\uFB1D-\uFB4F]');

  /// "שלב 1", "שלב2", etc. — highlighted in assistant bubbles for scanability.
  static final RegExp _hebrewStepMarker = RegExp(r'שלב\s*\d+');

  /// Inline step header: matches "שלב N" / "Step N" anywhere in the message,
  /// requiring a non-letter boundary before so we don't match "בשלב" / "השלב".
  /// AI responses often pack all steps into a single line, so a line anchor
  /// would only catch the first one.
  static final RegExp _stepHeaderRe = RegExp(
    r'(?<![\u0590-\u05FFa-zA-Z_])(?:\*\*|##\s*)?(?:שלב|Step)\s*(\d+)',
    caseSensitive: false,
  );

  /// Captures a quoted step title followed by a separator (`'זיהוי' ->`,
  /// `"Identify": ...`, etc.) at the start of a step's body.
  static final RegExp _stepQuotedTitleRe = RegExp(
    "^['\u2018\u2019\u201C\u201D\"]([^'\u2018\u2019\u201C\u201D\"\n]+?)['\u2018\u2019\u201C\u201D\"]\\s*(?:->|→|:|—|\\n|\$)",
  );
  static const String _kbEndpoint =
      'https://seedesktop.com/wp-admin/admin-ajax.php?action=sd_get_rmm_it_kb';
  static const String _kbCacheEntriesPrefsKey = 'rmm_it_kb_entries_cache_v1';
  static const String _kbCacheFetchedAtPrefsKey =
      'rmm_it_kb_entries_cache_at_ms_v1';
  static const Duration _kbCacheMaxAge = Duration(days: 1);
  static const List<String> _cmdStarters = <String>[
    'cmd',
    'cmd.exe',
    'ipconfig',
    'netsh',
    'sc',
    'tasklist',
    'taskkill',
    'chkdsk',
    'sfc',
    'dism',
    'powercfg',
    'reg',
    'wmic',
    'shutdown',
    'gpupdate',
    'whoami',
    'ping',
    'tracert',
    'nslookup',
    'net',
  ];

  @override
  void initState() {
    super.initState();
    _kbSearchController.addListener(_onKbSearchChanged);
  }

  bool get _he =>
      bind.mainGetLocalOption(key: kCommConfKeyLang).trim().toLowerCase() ==
      'he';

  @override
  void dispose() {
    _kbSearchController.removeListener(_onKbSearchChanged);
    _scroll.dispose();
    _kbSearchController.dispose();
    _kbWildcardFilterController.dispose();
    super.dispose();
  }

  void _onKbSearchChanged() {
    if (mounted) setState(() {});
  }

  bool _containsHebrew(String text) => _hebrewChars.hasMatch(text);

  Widget _selectableChatBody(
    String text,
    TextStyle baseStyle,
    bool hasHebrew,
  ) {
    if (!_hebrewStepMarker.hasMatch(text)) {
      return SelectableText(
        text,
        textDirection: hasHebrew ? TextDirection.rtl : TextDirection.ltr,
        textAlign: hasHebrew ? TextAlign.right : TextAlign.left,
        style: baseStyle,
      );
    }
    const stepBlue = Color(0xFF1565C0);
    final stepStyle = baseStyle.copyWith(
      color: stepBlue,
      fontWeight: FontWeight.w600,
    );
    final spans = <TextSpan>[];
    var start = 0;
    for (final m in _hebrewStepMarker.allMatches(text)) {
      if (m.start > start) {
        spans.add(
          TextSpan(text: text.substring(start, m.start), style: baseStyle),
        );
      }
      spans.add(
        TextSpan(text: text.substring(m.start, m.end), style: stepStyle),
      );
      start = m.end;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: baseStyle));
    }
    return SelectableText.rich(
      TextSpan(children: spans),
      textDirection: hasHebrew ? TextDirection.rtl : TextDirection.ltr,
      textAlign: hasHebrew ? TextAlign.right : TextAlign.left,
    );
  }

  /// Parse an assistant message into a leading paragraph + numbered step
  /// blocks. Returns `(preamble: '', steps: [])` when there are no step
  /// headers — caller falls back to a regular chat bubble.
  ///
  /// Handles both layouts seen in production:
  ///   • One paragraph: "שלב 1: 'X' -> ... שלב 2: 'Y' -> ..."
  ///   • Multi-line:    "שלב 1: 'X'\n<body>\n\nשלב 2: ..."
  ({String preamble, List<_StepBlock> steps}) _parseStepBlocks(String text) {
    final matches = _stepHeaderRe.allMatches(text).toList();
    if (matches.isEmpty) {
      return (preamble: '', steps: const <_StepBlock>[]);
    }
    final preamble = text.substring(0, matches.first.start).trim();
    final blocks = <_StepBlock>[];
    final stripLeadingSepRe = RegExp(r'^[\s:.\-–,;]+');
    final trailingSentenceDotRe = RegExp(r'\.\s*$');
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final number = m.group(1) ?? '';
      final contentStart = m.end;
      final contentEnd =
          i + 1 < matches.length ? matches[i + 1].start : text.length;
      var content = text.substring(contentStart, contentEnd).trim();
      content = content.replaceFirst(stripLeadingSepRe, '');

      String title = '';
      String body = content;
      final quoted = _stepQuotedTitleRe.firstMatch(content);
      if (quoted != null) {
        title = (quoted.group(1) ?? '').trim();
        body = content.substring(quoted.end).trim();
      }
      // Trim the trailing "." that separates this step from the next sentence.
      body = body.replaceFirst(trailingSentenceDotRe, '').trim();
      blocks.add(_StepBlock(number: number, title: title, body: body));
    }
    return (preamble: preamble, steps: blocks);
  }

  /// Builds the "stepped solution" layout (numbered cards + הפעל buttons),
  /// matching the boxed step UX from the KB design.
  Widget _buildStepCards({
    required String preamble,
    required List<_StepBlock> steps,
    required ColorScheme cs,
    required double maxBubble,
    required bool hasHebrew,
  }) {
    final children = <Widget>[];
    if (preamble.isNotEmpty) {
      children.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          constraints: BoxConstraints(maxWidth: maxBubble),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh.withOpacity(0.95),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(10),
              topRight: Radius.circular(10),
              bottomLeft: Radius.circular(2),
              bottomRight: Radius.circular(10),
            ),
          ),
          child: _selectableChatBody(
            preamble,
            TextStyle(
              fontSize: _chatMessageFontSize,
              height: 1.35,
              color: cs.onSurface,
            ),
            hasHebrew,
          ),
        ),
      );
      children.add(const SizedBox(height: 8));
    }
    for (var i = 0; i < steps.length; i++) {
      children.add(_stepCard(steps[i], cs, maxBubble, hasHebrew));
      if (i != steps.length - 1) children.add(const SizedBox(height: 8));
    }
    return Column(
      crossAxisAlignment:
          hasHebrew ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _stepCard(
    _StepBlock step,
    ColorScheme cs,
    double maxBubble,
    bool hasHebrew,
  ) {
    final cmds = _detectCommands('${step.title}\n${step.body}');
    final titleStyle = TextStyle(
      fontSize: _chatMessageFontSize + 1,
      fontWeight: FontWeight.w700,
      color: cs.onSurface,
      height: 1.3,
    );
    final bodyStyle = TextStyle(
      fontSize: _chatMessageFontSize,
      color: cs.onSurfaceVariant,
      height: 1.4,
    );
    final card = Container(
      width: maxBubble,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: _kItHelpAccent,
              shape: BoxShape.circle,
            ),
            child: Text(
              step.number,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (step.title.isNotEmpty)
                  SelectableText(
                    _formatStepTitle(step),
                    textDirection:
                        hasHebrew ? TextDirection.rtl : TextDirection.ltr,
                    textAlign: hasHebrew ? TextAlign.right : TextAlign.left,
                    style: titleStyle,
                  ),
                if (step.body.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _selectableChatBody(step.body, bodyStyle, hasHebrew),
                ],
                if (cmds.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final cmd in cmds) _stepCommandRow(cmd, cs),
                ],
                const SizedBox(height: 6),
                Align(
                  alignment:
                      hasHebrew ? Alignment.centerLeft : Alignment.centerRight,
                  child: cmds.isNotEmpty
                      ? FilledButton.icon(
                          onPressed: () =>
                              unawaited(_runCommandAsAdmin(cmds.first)),
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: Text(_he ? 'הפעל' : 'Run'),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: const Color(0xFF2D7C3B),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return Directionality(
      textDirection: hasHebrew ? TextDirection.rtl : TextDirection.ltr,
      child: card,
    );
  }

  String _formatStepTitle(_StepBlock step) {
    if (step.title.isEmpty) {
      return _he ? 'שלב ${step.number}' : 'Step ${step.number}';
    }
    final prefix = _he ? 'שלב ${step.number}' : 'Step ${step.number}';
    return "$prefix: '${step.title}'";
  }

  Widget _stepCommandRow(_DetectedCommand cmd, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF060A06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF1A5D1A), width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                cmd.text,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: math.max(12, _chatMessageFontSize - 1),
                  color: const Color(0xFF66FF88),
                  height: 1.25,
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: _he ? 'העתק' : 'Copy',
              onPressed: () => unawaited(_copyCommand(cmd)),
              icon: const Icon(Icons.copy, size: 16, color: Color(0xFF66FF88)),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  static const List<String> _psVerbs = <String>[
    'get',
    'set',
    'new',
    'add',
    'remove',
    'start',
    'stop',
    'restart',
    'enable',
    'disable',
    'connect',
    'disconnect',
    'invoke',
    'update',
    'out',
    'write',
    'read',
    'test',
    'measure',
    'resolve',
    'clear',
    'copy',
    'move',
    'rename',
    'export',
    'import',
    'format',
    'select',
    'where',
    'foreach',
    'sort',
    'group',
    'compare',
    'register',
    'unregister'
  ];

  bool _looksLikePowerShell(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    final lower = t.toLowerCase();
    if (lower.startsWith('powershell')) return true;

    for (final verb in _psVerbs) {
      if (lower.contains('$verb-')) return true;
    }

    if (lower.contains('select-object') ||
        lower.contains('convertto-json') ||
        lower.contains('where-object')) {
      return true;
    }
    if (t.contains('|') && RegExp(r'[A-Za-z]+-[A-Za-z]+').hasMatch(t)) {
      return true;
    }
    return false;
  }

  bool _looksLikeCmd(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    final lower = t.toLowerCase();
    for (final starter in _cmdStarters) {
      if (lower.startsWith('$starter ') || lower == starter) return true;
    }
    return false;
  }

  String _trimDetectedCommand(String s) {
    var out = s.trim();
    bool changed = true;
    while (changed) {
      changed = false;
      final startChar = out.isNotEmpty ? out[0] : '';
      if (['.', ',', ';', ':', '!', '?', '(', '[', ')', ']', '"', "'"]
          .contains(startChar)) {
        if (startChar == '(') {
          int openCount = out.split('(').length - 1;
          int closeCount = out.split(')').length - 1;
          if (openCount > closeCount) {
            out = out.substring(1).trimLeft();
            changed = true;
          }
        } else if (startChar == '"' || startChar == "'") {
          int qCount = out.split(startChar).length - 1;
          if (qCount % 2 != 0) {
            out = out.substring(1).trimLeft();
            changed = true;
          }
        } else {
          out = out.substring(1).trimLeft();
          changed = true;
        }
      }

      final endChar = out.isNotEmpty ? out[out.length - 1] : '';
      if (['.', ',', ';', ':', '!', '?', '(', '[', ')', ']', '"', "'"]
          .contains(endChar)) {
        if (endChar == ')') {
          int openCount = out.split('(').length - 1;
          int closeCount = out.split(')').length - 1;
          if (closeCount > openCount) {
            out = out.substring(0, out.length - 1).trimRight();
            changed = true;
          }
        } else if (endChar == ']') {
          int openCount = out.split('[').length - 1;
          int closeCount = out.split(']').length - 1;
          if (closeCount > openCount) {
            out = out.substring(0, out.length - 1).trimRight();
            changed = true;
          }
        } else if (endChar == '"' || endChar == "'") {
          int qCount = out.split(endChar).length - 1;
          if (qCount % 2 != 0) {
            out = out.substring(0, out.length - 1).trimRight();
            changed = true;
          }
        } else {
          out = out.substring(0, out.length - 1).trimRight();
          changed = true;
        }
      }
    }
    out = out.replaceFirst(RegExp(r'^[->]\s+'), '');
    return out.trim();
  }

  bool _isWordBoundaryBefore(String line, int idx) {
    if (idx <= 0) return true;
    final ch = line[idx - 1];
    return !RegExp(r'[A-Za-z0-9_\-]').hasMatch(ch);
  }

  _DetectedCommand? _extractInlineCommand(String line) {
    final lower = line.toLowerCase();
    for (final starter in _cmdStarters) {
      var searchFrom = 0;
      while (searchFrom < lower.length) {
        final idx = lower.indexOf(starter, searchFrom);
        if (idx < 0) break;
        searchFrom = idx + starter.length;
        if (!_isWordBoundaryBefore(line, idx)) continue;
        final raw = _trimDetectedCommand(line.substring(idx));
        if (raw.isEmpty) continue;
        if (_looksLikeCmd(raw)) {
          return _DetectedCommand(text: raw, isPowerShell: false);
        }
      }
    }
    return null;
  }

  List<_DetectedCommand> _detectCommands(String text) {
    final found = <_DetectedCommand>[];
    final seen = <String>{};

    void addCmd(String rawCmd, bool isPs) {
      final cmd = _trimDetectedCommand(rawCmd);
      if (cmd.isEmpty) return;
      if (cmd.toLowerCase() == 'wi-fi' || cmd.toLowerCase() == 'e-mail') return;
      if (cmd.length < 3) return;

      final key = '${isPs ? 'ps' : 'cmd'}:${cmd.toLowerCase()}';
      if (!seen.contains(key)) {
        seen.add(key);
        found.add(_DetectedCommand(text: cmd, isPowerShell: isPs));
      }
    }

    // 1. Check for markdown code blocks
    final codeBlockRegex =
        RegExp(r'```(?:powershell|cmd|bat|ps1)?\s*\n(.*?)\n```', dotAll: true);
    for (final match in codeBlockRegex.allMatches(text)) {
      final code = match.group(1)?.trim() ?? '';
      if (code.isNotEmpty) {
        final isPs =
            _looksLikePowerShell(code) || !code.toLowerCase().startsWith('cmd');
        addCmd(code, isPs);
      }
    }

    // 2. Check for inline backticks
    final inlineCodeRegex = RegExp(r'`([^`]+)`');
    for (final match in inlineCodeRegex.allMatches(text)) {
      final code = match.group(1)?.trim() ?? '';
      if (code.isNotEmpty) {
        if (_looksLikePowerShell(code)) {
          addCmd(code, true);
        } else if (_looksLikeCmd(code)) {
          addCmd(code, false);
        }
      }
    }

    // 3. Extract from non-Hebrew blocks
    final nonHebrewRegex = RegExp(r'[^\u0590-\u05FF\uFB1D-\uFB4F\n]+');
    for (final match in nonHebrewRegex.allMatches(text)) {
      final block = match.group(0) ?? '';
      final trimmed = _trimDetectedCommand(block);
      if (trimmed.isEmpty) continue;

      if (_looksLikePowerShell(trimmed)) {
        addCmd(trimmed, true);
      } else if (_looksLikeCmd(trimmed)) {
        addCmd(trimmed, false);
      } else {
        // Fallback for CMD inside English text
        final inline = _extractInlineCommand(trimmed);
        if (inline != null) {
          addCmd(inline.text, inline.isPowerShell);
        }
      }
    }

    return found;
  }

  Future<void> _copyCommand(_DetectedCommand cmd) async {
    await Clipboard.setData(ClipboardData(text: cmd.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_he ? 'הפקודה הועתקה' : 'Command copied'),
        duration: const Duration(milliseconds: 1300),
      ),
    );
  }

  Future<void> _runCommandAsAdmin(_DetectedCommand cmd) async {
    try {
      await LocalMaintenanceService.openPowerShellWindowAsAdmin(
        command: cmd.text,
        sourceIsPowerShell: cmd.isPowerShell,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _he
                ? 'PowerShell נפתח כמנהל והפקודה הורצה שם.'
                : 'PowerShell opened as admin and command was sent there.',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (_he ? 'שגיאה בהרצת פקודה: ' : 'Command failed: ') + e.toString(),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<bool> _ensureKbEntriesForSearch() async {
    if (_kbEntries.isNotEmpty) return true;
    if (await _loadKbCache()) return true;

    if (mounted) {
      setState(() {
        _kbLoading = true;
        _kbSearchError = null;
      });
    }
    try {
      final entries = await _fetchKbIssuesFromServer();
      if (entries.isEmpty) {
        return await _loadKbCache(freshOnly: false);
      }
      await _saveKbCache(entries);
      if (!mounted) return true;
      setState(() => _setKbEntries(entries));
      return true;
    } catch (_) {
      final hasStaleCache = await _loadKbCache(freshOnly: false);
      if (!hasStaleCache && mounted) {
        setState(() {
          _kbSearchError = _he
              ? 'לא ניתן לטעון את מאגר התקלות כרגע'
              : 'Could not load the troubleshooting knowledge base';
        });
      }
      return hasStaleCache;
    } finally {
      if (mounted) setState(() => _kbLoading = false);
    }
  }

  Future<void> _loadKbEntriesOnStartup() async {
    if (mounted) {
      setState(() {
        _kbLoading = true;
        _kbSearchError = null;
      });
    }
    await _loadKbCache(freshOnly: false);
    try {
      final entries = await _fetchKbIssuesFromServer();
      if (entries.isNotEmpty) {
        await _saveKbCache(entries);
        if (mounted) setState(() => _setKbEntries(entries));
        return;
      }
      await _loadKbCache(freshOnly: false);
    } catch (_) {
      await _loadKbCache(freshOnly: false);
    } finally {
      if (mounted) setState(() => _kbLoading = false);
    }
  }

  Future<List<_KbEntry>> _fetchKbIssuesFromServer() async {
    final res = await http.get(
      Uri.parse(_kbEndpoint),
      headers: const <String, String>{
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      },
    );
    if (res.statusCode != 200) return <_KbEntry>[];
    final jsonObj = jsonDecode(res.body);
    if (jsonObj is! Map<String, dynamic>) return <_KbEntry>[];
    final data = jsonObj['data'];
    if (data is! Map<String, dynamic>) return <_KbEntry>[];
    final entries = _parseKbEntriesFromJson(data);
    if (entries.isNotEmpty) return entries;
    final combinedPrompt = data['combined_prompt'];
    if (combinedPrompt is! String) return <_KbEntry>[];
    return _parseKbEntries(combinedPrompt);
  }

  List<_KbEntry> _parseKbEntriesFromJson(Map<String, dynamic> data) {
    for (final key in <String>['entries', 'issues', 'items', 'kb']) {
      final rawEntries = data[key];
      if (rawEntries is! List) continue;
      final entries = rawEntries
          .map(_KbEntry.fromJson)
          .whereType<_KbEntry>()
          .toList(growable: false);
      if (entries.isNotEmpty) return _dedupeKbEntries(entries);
    }
    return <_KbEntry>[];
  }

  List<_KbEntry> _parseKbEntries(String combinedPrompt) {
    final entries = <_KbEntry>[];
    final lines = const LineSplitter().convert(combinedPrompt);
    String? currentIssue;
    final currentSolutionLines = <String>[];

    void pushEntry() {
      final issue = currentIssue;
      if (issue == null || issue.isEmpty) return;
      final solution = currentSolutionLines.join('\n').trim();
      entries.add(_KbEntry(issue: issue, solution: solution));
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.toLowerCase().startsWith('issue:')) {
        pushEntry();
        currentIssue = line
            .replaceFirst(RegExp(r'^issue:\s*', caseSensitive: false), '')
            .trim();
        currentSolutionLines.clear();
        continue;
      }
      if (currentIssue == null) continue;

      if (line.toLowerCase().startsWith('solution:')) {
        final firstLine = line
            .replaceFirst(RegExp(r'^solution:\s*', caseSensitive: false), '')
            .trim();
        if (firstLine.isNotEmpty) currentSolutionLines.add(firstLine);
        continue;
      }

      if (currentSolutionLines.isNotEmpty && line.isNotEmpty) {
        currentSolutionLines.add(line);
      }
    }
    pushEntry();

    return _dedupeKbEntries(entries);
  }

  List<_KbEntry> _dedupeKbEntries(List<_KbEntry> entries) {
    final dedupedByIssue = <String, _KbEntry>{};
    for (final entry in entries) {
      dedupedByIssue[entry.issue] = entry;
    }
    return dedupedByIssue.values.toList(growable: false);
  }

  Future<bool> _loadKbCache({bool freshOnly = true}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fetchedAtMs = prefs.getInt(_kbCacheFetchedAtPrefsKey) ?? 0;
      if (freshOnly) {
        final ageMs = DateTime.now().millisecondsSinceEpoch - fetchedAtMs;
        if (fetchedAtMs <= 0 || ageMs > _kbCacheMaxAge.inMilliseconds) {
          return false;
        }
      }
      final raw = prefs.getString(_kbCacheEntriesPrefsKey);
      if (raw == null || raw.trim().isEmpty) return false;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return false;
      final entries = decoded
          .map(_KbEntry.fromJson)
          .whereType<_KbEntry>()
          .toList(growable: false);
      if (entries.isEmpty) return false;
      if (mounted) setState(() => _setKbEntries(entries));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveKbCache(List<_KbEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kbCacheEntriesPrefsKey,
      jsonEncode(entries.map((e) => e.toJson()).toList(growable: false)),
    );
    await prefs.setInt(
      _kbCacheFetchedAtPrefsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _setKbEntries(List<_KbEntry> entries) {
    _kbEntries = entries;
    _kbSearchAttempted = true;
    final query = _appliedKbQuery.trim();
    _kbSearchResults =
        query.isEmpty ? _allKbSearchResults() : _searchKbEntries(query);
    if (_selectedKbEntry != null) {
      final keep = entries.where((e) => e.issue == _selectedKbEntry!.issue);
      _selectedKbEntry = keep.isEmpty ? null : keep.first;
    }
  }

  void _closePanel() {
    if (!_panelOpen) return;
    setState(() {
      _panelOpen = false;
      _maximized = false;
    });
  }

  void _togglePanel() {
    final opening = !_panelOpen;
    setState(() => _panelOpen = opening);
    if (opening) {
      unawaited(_loadKbEntriesOnStartup());
    }
  }

  void _toggleMaximized() {
    setState(() => _maximized = !_maximized);
  }

  void _fontDelta(double delta) {
    setState(() {
      _chatMessageFontSize =
          (_chatMessageFontSize + delta).clamp(_fontMin, _fontMax);
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _runKbSearch() async {
    final query = _kbSearchController.text.trim();
    setState(() {
      _appliedKbQuery = query;
      _kbWildcardFilter = '';
      _kbWildcardFilterController.clear();
      _kbSearchAttempted = true;
      _kbSearchError = null;
    });
    final ready = await _ensureKbEntriesForSearch();
    if (!ready || !mounted) return;
    setState(() {
      _kbSearchResults =
          query.isEmpty ? _allKbSearchResults() : _searchKbEntries(query);
    });
  }

  List<_KbSearchResult> _allKbSearchResults() {
    return _kbEntries
        .map(
          (entry) => _KbSearchResult(
            entry: entry,
            score: 0,
            matchedSolution: false,
            solutionSnippet: '',
          ),
        )
        .toList(growable: false);
  }

  List<_KbSearchResult> _searchKbEntries(String query) {
    final normalizedPattern = _normalizeWildcardPattern(query);
    if (normalizedPattern.isEmpty) return _allKbSearchResults();
    final tokens = _kbQueryTokens(query);
    final results = <_KbSearchResult>[];

    for (final entry in _kbEntries) {
      final issue = _normalizeSearchText(entry.issue);
      final solution = _normalizeSearchText(entry.solution);
      var score = 0;
      final issueMatches = _matchesNormalizedWildcard(issue, normalizedPattern);
      final solutionMatches =
          _matchesNormalizedWildcard(solution, normalizedPattern);
      if (!issueMatches && !solutionMatches) continue;
      if (issueMatches) {
        score += issue.startsWith(normalizedPattern) ? 160 : 120;
      }
      if (solutionMatches) score += 55;

      results.add(
        _KbSearchResult(
          entry: entry,
          score: score,
          matchedSolution: solutionMatches,
          solutionSnippet:
              solutionMatches ? _solutionSnippet(entry.solution, tokens) : '',
        ),
      );
    }

    results.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) return scoreCompare;
      return a.entry.issue.compareTo(b.entry.issue);
    });
    return results;
  }

  List<_KbSearchResult> _filteredKbSearchResults() {
    final pattern = _kbWildcardFilter.trim();
    if (pattern.isEmpty) return _kbSearchResults;
    return _kbSearchResults
        .where((result) => _matchesKbWildcard(result.entry, pattern))
        .toList(growable: false);
  }

  bool _matchesKbWildcard(_KbEntry entry, String pattern) {
    final normalizedPattern = _normalizeWildcardPattern(pattern);
    if (normalizedPattern.isEmpty) return true;
    final haystack = _normalizeSearchText('${entry.issue} ${entry.solution}');
    return _matchesNormalizedWildcard(haystack, normalizedPattern);
  }

  bool _matchesNormalizedWildcard(String haystack, String normalizedPattern) {
    if (!normalizedPattern.contains('*') && !normalizedPattern.contains('?')) {
      return haystack.contains(normalizedPattern);
    }
    final regex = RegExp(_wildcardPatternToRegex(normalizedPattern));
    return regex.hasMatch(haystack);
  }

  String _normalizeWildcardPattern(String pattern) {
    return pattern
        .toLowerCase()
        .replaceAll(RegExp(r'[\u0591-\u05C7\u200e\u200f]'), '')
        .replaceAll('ך', 'כ')
        .replaceAll('ם', 'מ')
        .replaceAll('ן', 'נ')
        .replaceAll('ף', 'פ')
        .replaceAll('ץ', 'צ')
        .replaceAll(RegExp(r'[^\u0590-\u05FFa-z0-9*?]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _wildcardPatternToRegex(String pattern) {
    final buffer = StringBuffer();
    for (var i = 0; i < pattern.length; i++) {
      final ch = pattern[i];
      if (ch == '*') {
        buffer.write('.*');
      } else if (ch == '?') {
        buffer.write('.');
      } else {
        buffer.write(RegExp.escape(ch));
      }
    }
    return buffer.toString();
  }

  String _normalizeSearchText(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[\u0591-\u05C7\u200e\u200f]'), '')
        .replaceAll('ך', 'כ')
        .replaceAll('ם', 'מ')
        .replaceAll('ן', 'נ')
        .replaceAll('ף', 'פ')
        .replaceAll('ץ', 'צ')
        .replaceAll(RegExp(r'[^\u0590-\u05FFa-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<String> _kbQueryTokens(String query) {
    final normalized = _normalizeSearchText(query);
    if (normalized.isEmpty) return <String>[];
    final seen = <String>{};
    final tokens = <String>[];
    for (final token in normalized.split(' ')) {
      if (token.isEmpty || !seen.add(token)) continue;
      tokens.add(token);
    }
    return tokens;
  }

  String _solutionSnippet(String solution, List<String> tokens) {
    final cleaned = solution.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return '';
    final normalized = _normalizeSearchText(cleaned);
    var matchIndex = -1;
    for (final token in tokens) {
      matchIndex = normalized.indexOf(token);
      if (matchIndex >= 0) break;
    }
    if (matchIndex < 0) {
      return cleaned.length <= 120
          ? cleaned
          : '${cleaned.substring(0, 120)}...';
    }
    final start = math.max(0, matchIndex - 45);
    final end = math.min(cleaned.length, matchIndex + 95);
    final prefix = start > 0 ? '...' : '';
    final suffix = end < cleaned.length ? '...' : '';
    return '$prefix${cleaned.substring(start, end)}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mq = MediaQuery.of(context);
    final defaultPanelH = (mq.size.height * 0.55).clamp(320.0, 520.0);
    const defaultPanelW = 380.0;
    const combinedDetailsAndSearchW = 600.0;

    final fabReserve = 68.0;
    final panelW = _maximized
        ? math.max(320.0, mq.size.width - mq.padding.horizontal - 24)
        : math.max(defaultPanelW, combinedDetailsAndSearchW + 24);
    final panelH = _maximized
        ? math.max(
            280.0,
            mq.size.height - mq.padding.vertical - fabReserve - 16,
          )
        : defaultPanelH;
    final kbSidebarWidth = _maximized ? 300.0 : 230.0;
    final detailsAreaWidth =
        math.max(220.0, combinedDetailsAndSearchW - kbSidebarWidth);
    final launcher = _buildLauncher();
    final panel =
        _buildPanel(cs, panelW, panelH, detailsAreaWidth, kbSidebarWidth);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: widget.panelBelowTrigger
            ? [
                launcher,
                if (_panelOpen) ...[
                  const SizedBox(height: 8),
                  panel,
                ],
              ]
            : [
                if (_panelOpen) ...[
                  panel,
                  const SizedBox(height: 8),
                ],
                launcher,
              ],
      ),
    );
  }

  Widget _buildPanel(
    ColorScheme cs,
    double panelW,
    double panelH,
    double detailsAreaWidth,
    double kbSidebarWidth,
  ) {
    return Material(
      elevation: _maximized ? 16 : 10,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: panelW,
        height: panelH,
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _kItHelpAccent.withOpacity(0.45),
            width: 1.2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(cs),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: detailsAreaWidth,
                      child: Scrollbar(
                        controller: _scroll,
                        thumbVisibility: _maximized,
                        child: _messages.isEmpty
                            ? Center(
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    _he
                                        ? 'שאלו את עוזר ה־IT כאן — נסביר צעד־אחר־צעד.'
                                        : 'Ask your IT question here — we\'ll guide you step by step.',
                                    textAlign: TextAlign.center,
                                    textDirection: _he
                                        ? TextDirection.rtl
                                        : TextDirection.ltr,
                                    style: TextStyle(
                                      fontSize: (_chatMessageFontSize - 1)
                                          .clamp(11.0, 18.0),
                                      color: cs.onSurfaceVariant,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              )
                            : ListView.builder(
                                controller: _scroll,
                                primary: false,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 0,
                                  vertical: 4,
                                ),
                                itemCount: _messages.length,
                                itemBuilder: (ctx, i) {
                                  return _bubble(
                                    _messages[i],
                                    cs,
                                    panelW,
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: kbSidebarWidth,
                      child: _buildKbSidebar(cs),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLauncher() {
    final size = widget.compactTrigger ? 40.0 : 52.0;
    final radius = widget.compactTrigger ? 10.0 : 12.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.compactTrigger) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: _kItHelpAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kItHelpAccent.withOpacity(0.35)),
            ),
            child: Text(
              'פתרון תקלות',
              textDirection: TextDirection.rtl,
              style: TextStyle(
                color: _kItHelpAccent,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ] else ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _kItHelpAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kItHelpAccent.withOpacity(0.35)),
            ),
            child: Text(
              'מאגר תקלות ופיתרונם',
              textDirection: TextDirection.rtl,
              style: TextStyle(
                color: _kItHelpAccent,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Tooltip(
          message: _panelOpen ? translate('Close') : 'מאגר תקלות ופיתרונם',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _togglePanel,
              borderRadius: BorderRadius.circular(radius),
              child: Ink(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: _kItHelpAccent,
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.9),
                    width: 1.1,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(
                  _panelOpen ? Icons.close : Icons.build_outlined,
                  color: Colors.white,
                  size: widget.compactTrigger ? 22 : 26,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    final dir = _he ? TextDirection.rtl : TextDirection.ltr;
    return Material(
      color: _kItHelpAccent.withOpacity(0.1),
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(15),
        topRight: Radius.circular(15),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 4, end: 2, top: 2),
        child: Directionality(
          textDirection: dir,
          child: Row(
            children: [
              Icon(Icons.support_agent_outlined,
                  color: _kItHelpAccent, size: 22),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      _he ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Get IT Help',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: _kItHelpAccent,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      translate('rmm-it-chat-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                        height: 1.15,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                padding: EdgeInsets.zero,
                tooltip: _he ? 'הקטן גופן' : 'Smaller text',
                onPressed: _chatMessageFontSize <= _fontMin
                    ? null
                    : () => _fontDelta(-1),
                icon: Icon(
                  Icons.text_decrease_outlined,
                  size: 20,
                  color: cs.onSurface,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                padding: EdgeInsets.zero,
                tooltip: _he ? 'הגדל גופן' : 'Larger text',
                onPressed: _chatMessageFontSize >= _fontMax
                    ? null
                    : () => _fontDelta(1),
                icon: Icon(
                  Icons.text_increase_outlined,
                  size: 20,
                  color: cs.onSurface,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 36),
                padding: EdgeInsets.zero,
                tooltip: _maximized
                    ? (_he ? 'חזור לגודל רגיל' : 'Restore')
                    : (_he ? 'מסך מלא' : 'Maximize'),
                onPressed: _toggleMaximized,
                icon: Icon(
                  _maximized ? Icons.fullscreen_exit : Icons.fullscreen,
                  size: 21,
                  color: cs.onSurface,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 36),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close),
                color: cs.onSurface,
                tooltip: translate('Close'),
                onPressed: _closePanel,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bubble(_ChatMsg m, ColorScheme cs, double panelInnerW) {
    final user = m.isUser;
    final hasHebrew = _containsHebrew(m.text);
    final bg = user
        ? _kItHelpAccent.withOpacity(0.15)
        : cs.surfaceContainerHigh.withOpacity(0.95);
    final align = user ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final maxBubble =
        _maximized ? math.min(720.0, math.max(200.0, panelInnerW - 24)) : 340.0;
    if (!user) {
      final parsed = _parseStepBlocks(m.text);
      if (parsed.steps.isNotEmpty) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _buildStepCards(
            preamble: parsed.preamble,
            steps: parsed.steps,
            cs: cs,
            maxBubble: maxBubble,
            hasHebrew: hasHebrew,
          ),
        );
      }
    }
    final cmds = user ? const <_DetectedCommand>[] : _detectCommands(m.text);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            constraints: BoxConstraints(maxWidth: maxBubble),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(10),
                topRight: const Radius.circular(10),
                bottomLeft: Radius.circular(user ? 10 : 2),
                bottomRight: Radius.circular(user ? 2 : 10),
              ),
            ),
            child: _selectableChatBody(
              m.text,
              TextStyle(
                fontSize: _chatMessageFontSize,
                height: 1.35,
                color: cs.onSurface,
              ),
              hasHebrew,
            ),
          ),
          if (cmds.isNotEmpty)
            for (final cmd in cmds) ...[
              const SizedBox(height: 6),
              Container(
                width: maxBubble,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF060A06),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1A5D1A), width: 1),
                ),
                child: SelectableText(
                  cmd.text,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: math.max(12, _chatMessageFontSize - 1),
                    color: const Color(0xFF66FF88),
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_copyCommand(cmd)),
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(_he ? 'העתק' : 'Copy'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilledButton.icon(
                    onPressed: () => unawaited(_runCommandAsAdmin(cmd)),
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Run PowerShell'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: const Color(0xFF2D7C3B),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ],
        ],
      ),
    );
  }

  Widget _buildKbSidebar(ColorScheme cs) {
    final results = _filteredKbSearchResults();
    final query = _appliedKbQuery.trim();
    final hasActiveSearch = _kbSearchAttempted;
    final hasWildcardFilter = _kbWildcardFilter.trim().isNotEmpty;
    final statusText = _kbLoading && _kbEntries.isNotEmpty
        ? (_he
            ? 'מרענן את המאגר מהשרת... ${results.length} מוצגים'
            : 'Refreshing KB from server... ${results.length} shown')
        : !hasActiveSearch
            ? (_he ? 'טוען את כל הפתרונות...' : 'Loading all solutions...')
            : hasWildcardFilter
                ? (_he
                    ? '${results.length}/${_kbSearchResults.length} אחרי סינון'
                    : '${results.length}/${_kbSearchResults.length} after filter')
                : query.isEmpty
                    ? (_he
                        ? '${results.length} פתרונות נטענו'
                        : '${results.length} solutions loaded')
                    : (_he
                        ? '${results.length} תוצאות wildcard'
                        : '${results.length} wildcard results');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _kbSearchController,
                    enabled: !_kbLoading,
                    onSubmitted: (_) => unawaited(_runKbSearch()),
                    textDirection: _he ? TextDirection.rtl : TextDirection.ltr,
                    textAlign: _he ? TextAlign.right : TextAlign.left,
                    style: TextStyle(
                      fontSize: math.max(12, _chatMessageFontSize - 1),
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      hintText: _he
                          ? 'חיפוש wildcard, למשל מדפסת* או *רשת*'
                          : 'Wildcard search, e.g. printer* or *network*',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  height: 40,
                  child: ElevatedButton(
                    onPressed:
                        _kbLoading ? null : () => unawaited(_runKbSearch()),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 40),
                    ),
                    child: Text(
                      _he ? 'חפש' : 'Search',
                      style: TextStyle(
                        fontSize: math.max(11, _chatMessageFontSize - 3),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: _he
                        ? AlignmentDirectional.centerEnd
                        : AlignmentDirectional.centerStart,
                    child: Text(
                      statusText,
                      textDirection:
                          _he ? TextDirection.rtl : TextDirection.ltr,
                      style: TextStyle(
                        fontSize: math.max(10, _chatMessageFontSize - 3),
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (hasActiveSearch && _kbSearchResults.isNotEmpty) ...[
              const SizedBox(height: 4),
              TextField(
                controller: _kbWildcardFilterController,
                onChanged: (value) {
                  setState(() => _kbWildcardFilter = value.trim());
                },
                textDirection: _he ? TextDirection.rtl : TextDirection.ltr,
                textAlign: _he ? TextAlign.right : TextAlign.left,
                style: TextStyle(
                  fontSize: math.max(11, _chatMessageFontSize - 3),
                ),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.filter_alt_outlined, size: 17),
                  suffixIcon: hasWildcardFilter
                      ? IconButton(
                          tooltip: _he ? 'נקה סינון' : 'Clear filter',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _kbWildcardFilterController.clear();
                            setState(() => _kbWildcardFilter = '');
                          },
                        )
                      : null,
                  hintText: _he
                      ? 'סינון נוסף wildcard, למשל *מדפסת*'
                      : 'Extra wildcard filter, e.g. *printer*',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Expanded(
              child: _kbLoading && _kbEntries.isEmpty
                  ? Center(
                      child: Text(
                        _he ? 'טוען מאגר…' : 'Loading KB…',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : !hasActiveSearch
                      ? Center(
                          child: Text(
                            _he
                                ? 'טוען את כל הפתרונות מהמאגר...'
                                : 'Loading all solutions from the KB...',
                            textDirection:
                                _he ? TextDirection.rtl : TextDirection.ltr,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        )
                      : _kbSearchError != null && _kbEntries.isEmpty
                          ? Center(
                              child: Text(
                                _kbSearchError!,
                                textDirection:
                                    _he ? TextDirection.rtl : TextDirection.ltr,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: cs.error),
                              ),
                            )
                          : results.isEmpty
                              ? Center(
                                  child: Text(
                                    _he
                                        ? (hasWildcardFilter
                                            ? 'לא נמצאו תוצאות בסינון'
                                            : 'לא נמצאו תוצאות')
                                        : (hasWildcardFilter
                                            ? 'No results after filter'
                                            : 'No matching issues'),
                                    textDirection: _he
                                        ? TextDirection.rtl
                                        : TextDirection.ltr,
                                    textAlign: TextAlign.center,
                                    style:
                                        TextStyle(color: cs.onSurfaceVariant),
                                  ),
                                )
                              : ListView.separated(
                                  itemCount: results.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 4),
                                  itemBuilder: (context, i) {
                                    final result = results[i];
                                    final e = result.entry;
                                    final rtl = _containsHebrew(e.issue);
                                    final selected =
                                        _selectedKbEntry?.issue == e.issue;
                                    return Material(
                                      color: selected
                                          ? _kItHelpAccent.withOpacity(0.14)
                                          : cs.surface.withOpacity(0.72),
                                      borderRadius: BorderRadius.circular(8),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () {
                                          setState(() {
                                            _selectedKbEntry = e;
                                            _messages.removeWhere(
                                                (m) => m.isKbSolution);
                                            if (e.solution.isNotEmpty) {
                                              _messages.add(
                                                _ChatMsg(
                                                  isUser: false,
                                                  text: e.solution,
                                                  isKbSolution: true,
                                                ),
                                              );
                                            }
                                          });
                                          _scrollToEnd();
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 7,
                                          ),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Icon(
                                                selected
                                                    ? Icons.check_circle
                                                    : Icons.article_outlined,
                                                size: 16,
                                                color: selected
                                                    ? _kItHelpAccent
                                                    : cs.onSurfaceVariant,
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: rtl
                                                      ? CrossAxisAlignment.end
                                                      : CrossAxisAlignment
                                                          .start,
                                                  children: [
                                                    _highlightIssueText(
                                                      issue: e.issue,
                                                      query: query,
                                                      rtl: rtl,
                                                      cs: cs,
                                                    ),
                                                    if (result.solutionSnippet
                                                        .isNotEmpty) ...[
                                                      const SizedBox(height: 3),
                                                      Text(
                                                        (_he
                                                                ? 'נמצא בפתרון: '
                                                                : 'Found in solution: ') +
                                                            result
                                                                .solutionSnippet,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        textDirection:
                                                            _containsHebrew(
                                                          result
                                                              .solutionSnippet,
                                                        )
                                                                ? TextDirection
                                                                    .rtl
                                                                : TextDirection
                                                                    .ltr,
                                                        textAlign:
                                                            _containsHebrew(
                                                          result
                                                              .solutionSnippet,
                                                        )
                                                                ? TextAlign
                                                                    .right
                                                                : TextAlign
                                                                    .left,
                                                        style: TextStyle(
                                                          fontSize: math.max(
                                                            10,
                                                            _chatMessageFontSize -
                                                                4,
                                                          ),
                                                          color: cs
                                                              .onSurfaceVariant,
                                                          height: 1.2,
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _highlightIssueText({
    required String issue,
    required String query,
    required bool rtl,
    required ColorScheme cs,
  }) {
    final baseStyle = TextStyle(
      fontSize: math.max(11, _chatMessageFontSize - 2),
      color: cs.onSurface,
      height: 1.25,
    );
    if (query.isEmpty) {
      return Text(
        issue,
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        textAlign: rtl ? TextAlign.right : TextAlign.left,
        softWrap: true,
        style: baseStyle,
      );
    }

    final lowerIssue = issue.toLowerCase();
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    final ranges = <List<int>>[];
    for (final token in tokens) {
      var start = 0;
      while (start < lowerIssue.length) {
        final matchAt = lowerIssue.indexOf(token, start);
        if (matchAt < 0) break;
        final matchEnd = matchAt + token.length;
        final overlaps = ranges.any(
          (range) => matchAt < range[1] && matchEnd > range[0],
        );
        if (!overlaps) ranges.add(<int>[matchAt, matchEnd]);
        start = matchEnd;
      }
    }
    ranges.sort((a, b) => a[0].compareTo(b[0]));
    if (ranges.isEmpty) {
      return Text(
        issue,
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        textAlign: rtl ? TextAlign.right : TextAlign.left,
        softWrap: true,
        style: baseStyle,
      );
    }

    final spans = <TextSpan>[];
    var cursor = 0;
    for (final range in ranges) {
      if (range[0] > cursor) {
        spans.add(TextSpan(text: issue.substring(cursor, range[0])));
      }
      spans.add(
        TextSpan(
          text: issue.substring(range[0], range[1]),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: _kItHelpAccent,
          ),
        ),
      );
      cursor = range[1];
    }
    if (cursor < issue.length) {
      spans.add(TextSpan(text: issue.substring(cursor)));
    }
    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: spans,
      ),
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      textAlign: rtl ? TextAlign.right : TextAlign.left,
      softWrap: true,
    );
  }
}
