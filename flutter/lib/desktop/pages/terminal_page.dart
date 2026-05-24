import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/terminal_model.dart';
import 'package:flutter_hbb/utils/agent_heartbeat_manager.dart';
import 'package:flutter_hbb/utils/ai_copilot_system_prompt.dart';
import 'package:flutter_hbb/utils/license_api_router.dart';
import 'package:flutter_hbb/utils/terminal_windows_profile_prefs.dart';
import 'package:xterm/xterm.dart';
import 'terminal_appearance_prefs.dart';
import 'terminal_connection_manager.dart';

class TerminalPage extends StatefulWidget {
  TerminalPage({
    Key? key,
    required this.id,
    required this.password,
    required this.tabController,
    required this.isSharedPassword,
    required this.terminalId,
    required this.tabKey,
    this.forceRelay,
    this.connToken,
    this.onOpenTerminalAppearance,
  }) : super(key: key);
  final String id;
  final String? password;
  final DesktopTabController tabController;
  final bool? forceRelay;
  final bool? isSharedPassword;
  final String? connToken;
  final int terminalId;

  /// Tab key for focus management, passed from parent to avoid duplicate construction
  final String tabKey;

  /// Opens the shared terminal colors dialog (background + text).
  final VoidCallback? onOpenTerminalAppearance;
  final SimpleWrapper<State<TerminalPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _TerminalPageState)._ffi;

  /// Paste [text] into the terminal (buffered if not yet connected).
  /// Also focuses the terminal view so input is sent to the active session immediately.
  void pasteInput(String text) {
    final state = _lastState.value;
    if (state is _TerminalPageState && state.mounted) {
      state._terminalModel.terminal.paste(text);
      state._requestFocusIfSelected();
    }
  }

  /// Like [pasteInput], but on Windows peers prepends `$SD_UserProfile` bootstrap when a target user folder is set.
  void pasteRemoteScript(String text) {
    final state = _lastState.value;
    if (state is _TerminalPageState && state.mounted) {
      final wrapped = state._terminalModel.wrapScriptForTargetProfile(text);
      state._terminalModel.terminal.paste(wrapped);
      state._requestFocusIfSelected();
    }
  }

  /// Applies xterm colors (e.g. after user picks theme in terminal window).
  void applyTerminalTheme(TerminalTheme theme) {
    final state = _lastState.value;
    if (state is _TerminalPageState && state.mounted) {
      state._applyXtermTheme(theme);
    }
  }

  @override
  State<TerminalPage> createState() {
    final state = _TerminalPageState();
    _lastState.value = state;
    return state;
  }
}

class _TerminalPageState extends State<TerminalPage>
    with AutomaticKeepAliveClientMixin {
  late FFI _ffi;
  late TerminalModel _terminalModel;
  double? _cellHeight;
  final FocusNode _terminalFocusNode = FocusNode(canRequestFocus: false);
  StreamSubscription<DesktopTabState>? _tabStateSubscription;

  final TextEditingController _aiPromptController = TextEditingController();
  final TextEditingController _commandLineController = TextEditingController();
  bool _aiCopilotLoading = false;

  late TerminalTheme _xtermTheme;

  Timer? _windowsProfileProbeTimer;
  final StringBuffer _windowsProfileProbeCapture = StringBuffer();
  void Function(String text)? _savedOnRemoteTextOutput;
  bool _windowsProfileProbeListening = false;
  bool _windowsProfileProbeRunning = false;
  List<String> _windowsProfileDropdownItems = [];

  void _applyXtermTheme(TerminalTheme theme) {
    setState(() => _xtermTheme = theme);
  }

  Future<void> _loadTerminalWindowThemePrefs() async {
    final t = await loadTerminalWindowTheme();
    if (mounted) setState(() => _xtermTheme = t);
  }

  @override
  void initState() {
    super.initState();
    _xtermTheme = terminalThemeFromBaseColors(Colors.black, Colors.white);

    // Listen for tab selection changes to request focus
    _tabStateSubscription =
        widget.tabController.state.listen(_onTabStateChanged);

    // Use shared FFI instance from connection manager
    _ffi = TerminalConnectionManager.getConnection(
      peerId: widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
      connToken: widget.connToken,
    );

    // Create terminal model with specific terminal ID
    _terminalModel = TerminalModel(_ffi, widget.terminalId);
    debugPrint(
        '[TerminalPage] Terminal model created for terminal ${widget.terminalId}');

    _terminalModel.onResizeExternal = (w, h, pw, ph) {
      _cellHeight = ph * 1.0;

      // Enable focus once terminal has valid dimensions (first valid resize)
      if (!_terminalFocusNode.canRequestFocus && w > 0 && h > 0) {
        _terminalFocusNode.canRequestFocus = true;
        // Auto-focus if this tab is currently selected
        _requestFocusIfSelected();
      }

      // Schedule the setState for the next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
    };

    // Register this terminal model with FFI for event routing
    _ffi.registerTerminalModel(widget.terminalId, _terminalModel);

    // Load saved profile folder from local prefs only — no remote probe/bootstrap on connect.
    _terminalModel.prepareBeforeOpen = _loadSavedWindowsProfileFromPrefsOnly;

    unawaited(_loadTerminalWindowThemePrefs());

    // Initialize terminal connection
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController.onSelected?.call(widget.id);

      // Check if this is a new connection or additional terminal
      // Note: When a connection exists, the ref count will be > 1 after this terminal is added
      final isExistingConnection =
          TerminalConnectionManager.hasConnection(widget.id) &&
              TerminalConnectionManager.getTerminalCount(widget.id) > 1;

      if (!isExistingConnection) {
        // First terminal - show loading dialog, wait for onReady
        _ffi.dialogManager
            .showLoading(translate('Connecting...'), onCancel: closeConnection);
      } else {
        // Additional terminal - connection already established
        // Open the terminal directly
        _terminalModel.openTerminal();
      }
    });
  }

  @override
  void dispose() {
    // Cancel tab state subscription to prevent memory leak
    _tabStateSubscription?.cancel();
    // Unregister terminal model from FFI
    _ffi.unregisterTerminalModel(widget.terminalId);
    _terminalModel.dispose();
    _terminalFocusNode.dispose();
    _aiPromptController.dispose();
    _commandLineController.dispose();
    _windowsProfileProbeTimer?.cancel();
    if (_windowsProfileProbeListening) {
      _terminalModel.onRemoteTextOutput = _savedOnRemoteTextOutput;
    }
    // Release connection reference instead of closing directly
    TerminalConnectionManager.releaseConnection(widget.id);
    super.dispose();
  }

  Future<void> _askAiCopilot(String prompt) async {
    final p = prompt.trim();
    if (p.isEmpty) return;
    setState(() => _aiCopilotLoading = true);
    try {
      final resp = await LicenseApiRouter.post(
        Uri.parse(kAiGenerateCommandEndpoint),
        headers: {
          'Authorization': 'Bearer $kVpsAdminBearerKey',
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(<String, dynamic>{
          'prompt': p,
          'system_prompt': kAiCopilotSystemPrompt,
        }),
        requestTimeout: const Duration(seconds: 90),
      );
      final body = resp.body;
      Map<String, dynamic>? j;
      try {
        j = jsonDecode(body) as Map<String, dynamic>?;
      } catch (_) {
        j = null;
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final msg = j?['error']?.toString() ??
            j?['message']?.toString() ??
            (body.isNotEmpty ? body : 'HTTP ${resp.statusCode}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg)),
          );
        }
        return;
      }
      final cmd = j?['command']?.toString();
      if (cmd == null || cmd.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('תגובה ללא שדה command')),
          );
        }
        return;
      }
      if (mounted) {
        setState(() {
          _commandLineController.text = cmd;
          _commandLineController.selection = TextSelection.collapsed(
            offset: _commandLineController.text.length,
          );
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('AI Copilot: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _aiCopilotLoading = false);
    }
  }

  void _sendCommandLineToRemote() {
    final t = _commandLineController.text;
    final trimmed = t.trimRight();
    if (trimmed.isEmpty) return;
    final wrapped = _terminalModel.wrapScriptForTargetProfile(trimmed);
    _terminalModel.terminal.paste('$wrapped\r');
    _commandLineController.clear();
  }

  void _pasteWindowsProfileBootstrapIfNeeded() {
    if (!mounted) return;
    final line = _terminalModel.windowsProfileBootstrapPowerShellLine();
    if (line != null && line.isNotEmpty) {
      _terminalModel.terminal.paste('$line\r');
    }
  }

  Future<void> _loadSavedWindowsProfileFromPrefsOnly() async {
    if (!_terminalModel.isPeerWindows) return;
    final saved = await loadSavedWindowsProfileFolder(widget.id);
    if (saved != null) {
      _terminalModel.setWindowsTargetProfileFolder(saved);
      if (mounted) {
        setState(() => _windowsProfileDropdownItems = [saved]);
      }
    }
  }

  void _startWindowsProfileProbe() {
    if (_windowsProfileProbeListening) return;
    if (mounted) setState(() => _windowsProfileProbeRunning = true);
    _windowsProfileProbeListening = true;
    _windowsProfileProbeCapture.clear();
    _savedOnRemoteTextOutput = _terminalModel.onRemoteTextOutput;
    _terminalModel.onRemoteTextOutput = _onRemoteTextDuringWindowsProfileProbe;
    _terminalModel.terminal.paste('${buildWindowsProfileProbeCommand()}\r');
    _windowsProfileProbeTimer?.cancel();
    _windowsProfileProbeTimer =
        Timer(const Duration(seconds: 12), _onWindowsProfileProbeTimedOut);
  }

  void _onRemoteTextDuringWindowsProfileProbe(String text) {
    _savedOnRemoteTextOutput?.call(text);
    if (!_windowsProfileProbeListening) return;
    _windowsProfileProbeCapture.write(text);
    final parsed = WindowsProfileProbeResult.parseCapture(
        _windowsProfileProbeCapture.toString());
    if (parsed != null) {
      _windowsProfileProbeTimer?.cancel();
      _windowsProfileProbeListening = false;
      _terminalModel.onRemoteTextOutput = _savedOnRemoteTextOutput;
      _savedOnRemoteTextOutput = null;
      _applyWindowsProfileProbeResult(parsed);
    }
  }

  void _applyWindowsProfileProbeResult(WindowsProfileProbeResult parsed) {
    final openingDeferred = _terminalModel.deferFlushAfterOpenForProfileProbe;
    final choices = usableWindowsProfileFolders(parsed);
    final current = _terminalModel.windowsTargetProfileFolder;
    String? picked;
    if (openingDeferred) {
      picked = pickDefaultWindowsProfileFolder(parsed) ??
          (choices.isNotEmpty ? choices.first : null);
    } else {
      if (current != null && choices.contains(current)) {
        picked = current;
      } else {
        picked = pickDefaultWindowsProfileFolder(parsed) ??
            (choices.isNotEmpty ? choices.first : null);
      }
    }
    if (mounted) {
      setState(() {
        _windowsProfileProbeRunning = false;
        _windowsProfileDropdownItems = choices;
      });
    }
    _terminalModel.setWindowsTargetProfileFolder(picked);
    if (openingDeferred) {
      _terminalModel.completeDeferredOpenAfterProfileProbe();
    }
  }

  void _onWindowsProfileProbeTimedOut() {
    if (!_windowsProfileProbeListening) return;
    _windowsProfileProbeListening = false;
    _terminalModel.onRemoteTextOutput = _savedOnRemoteTextOutput;
    _savedOnRemoteTextOutput = null;
    _windowsProfileProbeTimer?.cancel();

    final openingDeferred = _terminalModel.deferFlushAfterOpenForProfileProbe;
    final parsed = WindowsProfileProbeResult.parseCapture(
        _windowsProfileProbeCapture.toString());
    if (parsed != null) {
      _applyWindowsProfileProbeResult(parsed);
      return;
    }
    if (mounted) {
      setState(() => _windowsProfileProbeRunning = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(translate('terminal-win-profile-probe-failed'))),
      );
    }
    if (openingDeferred) {
      _terminalModel.setWindowsTargetProfileFolder(null);
      _terminalModel.completeDeferredOpenAfterProfileProbe();
    }
  }

  void _rerunWindowsProfileProbe() {
    if (!_terminalModel.isPeerWindows || !_terminalModel.terminalOpened) {
      return;
    }
    if (_windowsProfileProbeListening) return;
    _startWindowsProfileProbe();
  }

  Widget _buildWindowsProfileToolbar(BuildContext context) {
    if (!_terminalModel.isPeerWindows) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final folder = _terminalModel.windowsTargetProfileFolder;
    var items = List<String>.from(_windowsProfileDropdownItems);
    if (folder != null &&
        !items.contains(folder) &&
        isValidWindowsUsersFolderName(folder)) {
      items.add(folder);
      items.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    String? dropdownValue;
    if (items.isNotEmpty) {
      dropdownValue =
          (folder != null && items.contains(folder)) ? folder : items.first;
    }

    return Row(
      children: [
        if (_windowsProfileProbeRunning)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6, end: 4),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _xtermTheme.foreground.withOpacity(0.9),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6),
            child: Icon(
              Icons.person_outline,
              size: 18,
              color: _xtermTheme.foreground.withOpacity(0.85),
            ),
          ),
        const SizedBox(width: 4),
        Expanded(
          child: items.isEmpty
              ? Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: Text(
                    _windowsProfileProbeRunning
                        ? translate('terminal-win-profile-probing')
                        : translate('terminal-win-profile-no-profiles'),
                    style: TextStyle(
                      fontSize: 11,
                      color: _xtermTheme.foreground.withOpacity(0.85),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              : Padding(
                  padding: const EdgeInsetsDirectional.only(end: 2),
                  child: Theme(
                    data: theme.copyWith(canvasColor: _xtermTheme.background),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isDense: true,
                        isExpanded: true,
                        dropdownColor: theme.colorScheme.surface,
                        value: dropdownValue,
                        iconEnabledColor: _xtermTheme.foreground,
                        style: TextStyle(
                          fontSize: 12,
                          color: _xtermTheme.foreground,
                        ),
                        items: items
                            .map(
                              (e) => DropdownMenuItem<String>(
                                value: e,
                                child: Text(e),
                              ),
                            )
                            .toList(),
                        onChanged: _windowsProfileProbeRunning
                            ? null
                            : (v) {
                                if (v == null) return;
                                _terminalModel.setWindowsTargetProfileFolder(v);
                                _pasteWindowsProfileBootstrapIfNeeded();
                              },
                      ),
                    ),
                  ),
                ),
        ),
        IconButton(
          tooltip: translate('terminal-win-profile-refresh-list'),
          icon: Icon(
            Icons.refresh,
            size: 18,
            color: _xtermTheme.foreground.withOpacity(0.9),
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 32),
          onPressed:
              (_windowsProfileProbeRunning || !_terminalModel.terminalOpened)
                  ? null
                  : _rerunWindowsProfileProbe,
        ),
      ],
    );
  }

  void _onTabStateChanged(DesktopTabState state) {
    // Check if this tab is now selected and request focus
    if (state.selected >= 0 && state.selected < state.tabs.length) {
      final selectedTab = state.tabs[state.selected];
      if (selectedTab.key == widget.tabKey && mounted) {
        _requestFocusIfSelected();
      }
    }
  }

  void _requestFocusIfSelected() {
    if (!mounted || !_terminalFocusNode.canRequestFocus) return;
    // Use post-frame callback to ensure widget is fully laid out in focus tree
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Re-check conditions after frame: mounted, focusable, still selected, not already focused
      if (!mounted ||
          !_terminalFocusNode.canRequestFocus ||
          _terminalFocusNode.hasFocus) return;
      final state = widget.tabController.state.value;
      if (state.selected >= 0 && state.selected < state.tabs.length) {
        if (state.tabs[state.selected].key == widget.tabKey) {
          _terminalFocusNode.requestFocus();
        }
      }
    });
  }

  // This method ensures that the number of visible rows is an integer by computing the
  // extra space left after dividing the available height by the height of a single
  // terminal row (`_cellHeight`) and distributing it evenly as top and bottom padding.
  EdgeInsets _calculatePadding(double heightPx) {
    if (_cellHeight == null) {
      return const EdgeInsets.symmetric(horizontal: 5.0, vertical: 2.0);
    }
    final rows = (heightPx / _cellHeight!).floor();
    final extraSpace = heightPx - rows * _cellHeight!;
    final topBottom = extraSpace / 2.0;
    return EdgeInsets.symmetric(horizontal: 5.0, vertical: topBottom);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final isLangHe = bind.mainGetLocalOption(key: kCommConfKeyLang) == 'he';
    final terminalPane = LayoutBuilder(
      builder: (context, constraints) {
        final heightPx = constraints.maxHeight;
        return TerminalView(
          _terminalModel.terminal,
          controller: _terminalModel.terminalController,
          focusNode: _terminalFocusNode,
          theme: _xtermTheme,
          backgroundOpacity: 1,
          padding: _calculatePadding(heightPx),
          onSecondaryTapDown: (details, offset) async {
            final selection = _terminalModel.terminalController.selection;
            if (selection != null) {
              final text = _terminalModel.terminal.buffer.getText(selection);
              _terminalModel.terminalController.clearSelection();
              await Clipboard.setData(ClipboardData(text: text));
            } else {
              final data = await Clipboard.getData('text/plain');
              final text = data?.text;
              if (text != null) {
                _terminalModel.terminal.paste(text);
              }
            }
          },
        );
      },
    );

    return Scaffold(
      backgroundColor: _xtermTheme.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.onOpenTerminalAppearance != null ||
              _terminalModel.isPeerWindows)
            Material(
              color: _xtermTheme.background,
              elevation: 1,
              child: SizedBox(
                height: 36,
                child: Row(
                  children: [
                    if (widget.onOpenTerminalAppearance != null)
                      IconButton(
                        tooltip: 'צבעי טרמינל (רקע וטקסט)',
                        icon: const Icon(Icons.palette_outlined, size: 20),
                        color: _xtermTheme.foreground.withOpacity(0.9),
                        padding: const EdgeInsetsDirectional.only(start: 4),
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 36,
                        ),
                        onPressed: widget.onOpenTerminalAppearance,
                      ),
                    if (_terminalModel.isPeerWindows)
                      Expanded(
                        child: ListenableBuilder(
                          listenable: _terminalModel,
                          builder: (ctx, _) => _buildWindowsProfileToolbar(ctx),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Expanded(child: terminalPane),
          Material(
            elevation: 2,
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.85),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _aiPromptController,
                      enabled: !_aiCopilotLoading,
                      minLines: 1,
                      maxLines: 2,
                      textDirection:
                          isLangHe ? TextDirection.rtl : TextDirection.ltr,
                      textAlign: isLangHe ? TextAlign.right : TextAlign.start,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: isLangHe
                            ? "בקש מ-AI... (למשל: 'איך לנקות את הדיסק')"
                            : "Ask AI… (e.g. 'how to free disk space')",
                        hintStyle: TextStyle(
                          fontSize: 12,
                          color: theme.hintColor.withOpacity(0.9),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      onSubmitted: (_) {
                        if (!_aiCopilotLoading) {
                          unawaited(_askAiCopilot(_aiPromptController.text));
                        }
                      },
                    ),
                  ),
                  if (_aiCopilotLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  IconButton(
                    tooltip: 'AI Copilot',
                    icon: const Icon(Icons.auto_awesome),
                    color: const Color(0xFF7C3AED),
                    onPressed: _aiCopilotLoading
                        ? null
                        : () =>
                            unawaited(_askAiCopilot(_aiPromptController.text)),
                  ),
                ],
              ),
            ),
          ),
          Material(
            elevation: 1,
            color: theme.colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commandLineController,
                      minLines: 1,
                      maxLines: 4,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: isLangHe
                            ? 'שורת פקודה (עריכה לפני שליחה)'
                            : 'Command line (edit before send)',
                        hintText: isLangHe
                            ? 'הפקודה תישלח לטרמינל המרוחק ב-Enter או בכפתור — ניתן לערוך אחרי AI'
                            : 'Sent to the remote terminal on Enter or the play button — editable after AI',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _sendCommandLineToRemote(),
                    ),
                  ),
                  IconButton(
                    tooltip: 'הרץ פקודה',
                    icon: const Icon(Icons.play_circle_filled),
                    iconSize: 32,
                    color: Colors.green,
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    onPressed: () {
                      if (_commandLineController.text.trim().isNotEmpty) {
                        _sendCommandLineToRemote();
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
