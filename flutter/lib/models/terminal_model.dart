import 'dart:async';
import 'dart:convert';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart';
import 'package:xterm/xterm.dart';

import 'package:flutter_hbb/utils/terminal_windows_profile_prefs.dart';

import 'model.dart';
import 'platform_model.dart';

final _kHebrewInTerminal = RegExp(r'[\u0590-\u05FF]');

/// Wraps lines that contain Hebrew in RLE/PDF so glyphs read RTL in xterm.
String rtlEnrichHebrewTerminalLines(String text) {
  if (!_kHebrewInTerminal.hasMatch(text)) return text;
  final parts = text.split(RegExp(r'(\r\n|\n|\r)'));
  final sb = StringBuffer();
  for (final p in parts) {
    if (p == '\r\n' || p == '\n' || p == '\r') {
      sb.write(p);
      continue;
    }
    if (_kHebrewInTerminal.hasMatch(p)) {
      sb.write('\u202B');
      sb.write(p);
      sb.write('\u202C');
    } else {
      sb.write(p);
    }
  }
  return sb.toString();
}

class TerminalModel with ChangeNotifier {
  final String id; // peer id
  final FFI parent;
  final int terminalId;
  late final Terminal terminal;
  late final TerminalController terminalController;

  bool _terminalOpened = false;
  bool get terminalOpened => _terminalOpened;

  bool _disposed = false;

  final _inputBuffer = <String>[];
  // Buffer for output data received before terminal view has valid dimensions.
  // This prevents NaN errors when writing to terminal before layout is complete.
  final _pendingOutputChunks = <String>[];
  int _pendingOutputSize = 0;
  static const int _kMaxOutputBufferChars = 8 * 1024;
  // View ready state: true when terminal has valid dimensions, safe to write
  bool _terminalViewReady = false;

  bool get isPeerWindows => parent.ffiModel.pi.platform == kPeerPlatformWindows;

  /// Folder name under `C:\Users` when the remote shell runs as SYSTEM (e.g. `"eli"`).
  String? windowsTargetProfileFolder;

  /// Fired after the remote shell reports opened (success), once per open (reset when closed).
  void Function()? onShellOpenedOnce;

  bool _shellOpenedOnceNotified = false;

  /// Runs once at the start of [openTerminal] (e.g. Windows target-user dialog).
  Future<void> Function()? prepareBeforeOpen;

  /// When true, [openTerminal]'s `opened` event does not flush buffered input until
  /// [completeDeferredOpenAfterProfileProbe] runs (used to run a remote user probe first).
  bool deferFlushAfterOpenForProfileProbe = false;

  /// Invoked when the shell opened but input flush is deferred (see [deferFlushAfterOpenForProfileProbe]).
  void Function()? onDeferredProfileProbe;

  void completeDeferredOpenAfterProfileProbe() {
    if (!deferFlushAfterOpenForProfileProbe) return;
    deferFlushAfterOpenForProfileProbe = false;
    _invokeOpenFlushSequence();
  }

  void _invokeOpenFlushSequence() {
    // Before flushing buffered pastes so the first remote command sees $SD_UserProfile.
    if (!_shellOpenedOnceNotified && onShellOpenedOnce != null) {
      _shellOpenedOnceNotified = true;
      onShellOpenedOnce!();
    }

    _processBufferedInputAsync().then((_) {
      notifyListeners();
    }).catchError((e) {
      debugPrint('[TerminalModel] Error processing buffered input: $e');
      notifyListeners();
    });
  }

  void setWindowsTargetProfileFolder(String? folder) {
    final t = folder?.trim();
    windowsTargetProfileFolder =
        (t == null || t.isEmpty) ? null : t;
    notifyListeners();
  }

  /// Prepends profile variables so catalogue / pasted scripts can use `$SD_UserProfile` / `$global:SD_TargetUserProfile`.
  String wrapScriptForTargetProfile(String cmd) {
    if (!isPeerWindows || windowsTargetProfileFolder == null) {
      return cmd;
    }
    if (!isValidWindowsUsersFolderName(windowsTargetProfileFolder!)) {
      return cmd;
    }
    return wrapWindowsTargetProfileScript(windowsTargetProfileFolder!, cmd);
  }

  /// Single-line bootstrap for pasting when the session starts; null if no target folder.
  String? windowsProfileBootstrapPowerShellLine() {
    if (!isPeerWindows || windowsTargetProfileFolder == null) return null;
    if (!isValidWindowsUsersFolderName(windowsTargetProfileFolder!)) return null;
    return buildWindowsTargetProfileBootstrapPs1(windowsTargetProfileFolder!);
  }

  void Function(int w, int h, int pw, int ph)? onResizeExternal;

  /// Called for every chunk of remote terminal output (before writing to the view).
  /// Used e.g. to capture structured health reports without scraping the xterm buffer.
  void Function(String text)? onRemoteTextOutput;

  Future<void> _handleInput(String data) async {
    // If we press the `Enter` button on Android,
    // `data` can be '\r' or '\n' when using different keyboards.
    // Android -> Windows. '\r' works, but '\n' does not. '\n' is just a newline.
    // Android -> Linux. Both '\r' and '\n' work as expected (execute a command).
    // So when we receive '\n', we may need to convert it to '\r' to ensure compatibility.
    // Desktop -> Desktop works fine.
    // Check if we are on mobile or web(mobile), and convert '\n' to '\r'.
    final isMobileOrWebMobile = (isMobile || (isWeb && !isWebDesktop));
    if (isMobileOrWebMobile && isPeerWindows && data == '\n') {
      data = '\r';
    }
    if (_terminalOpened) {
      // Send user input to remote terminal
      try {
        await bind.sessionSendTerminalInput(
          sessionId: parent.sessionId,
          terminalId: terminalId,
          data: data,
        );
      } catch (e) {
        debugPrint('[TerminalModel] Error sending terminal input: $e');
      }
    } else {
      debugPrint('[TerminalModel] Terminal not opened yet, buffering input');
      _inputBuffer.add(data);
    }
  }

  TerminalModel(this.parent, [this.terminalId = 0]) : id = parent.id {
    terminal = Terminal(maxLines: 10000);
    terminalController = TerminalController();

    // Setup terminal callbacks
    terminal.onOutput = _handleInput;

    terminal.onResize = (w, h, pw, ph) async {
      // Validate all dimensions before using them
      if (w > 0 && h > 0 && pw > 0 && ph > 0) {
        debugPrint(
            '[TerminalModel] Terminal resized to ${w}x$h (pixel: ${pw}x$ph)');

        // This piece of code must be placed before the conditional check in order to initialize properly.
        onResizeExternal?.call(w, h, pw, ph);

        // Mark terminal view as ready and flush any buffered output on first valid resize.
        // Must be after onResizeExternal so the view layer has valid dimensions before flushing.
        if (!_terminalViewReady) {
          _markViewReady();
        }

        if (_terminalOpened) {
          // Notify remote terminal of resize
          try {
            await bind.sessionResizeTerminal(
              sessionId: parent.sessionId,
              terminalId: terminalId,
              rows: h,
              cols: w,
            );
          } catch (e) {
            debugPrint('[TerminalModel] Error resizing terminal: $e');
          }
        }
      } else {
        debugPrint(
            '[TerminalModel] Invalid terminal dimensions: ${w}x$h (pixel: ${pw}x$ph)');
      }
    };
  }

  void onReady() {
    parent.dialogManager.dismissAll();

    // Fire and forget - don't block onReady
    openTerminal().catchError((e) {
      debugPrint('[TerminalModel] Error opening terminal: $e');
    });
  }

  Future<void> openTerminal() async {
    if (_terminalOpened) return;
    final prep = prepareBeforeOpen;
    prepareBeforeOpen = null;
    if (prep != null) {
      try {
        await prep();
      } catch (e) {
        debugPrint('[TerminalModel] prepareBeforeOpen failed: $e');
      }
    }
    // Request the remote side to open a terminal with default shell
    // The remote side will decide which shell to use based on its OS

    // Get terminal dimensions, ensuring they are valid
    int rows = 24;
    int cols = 80;

    if (terminal.viewHeight > 0) {
      rows = terminal.viewHeight;
    }
    if (terminal.viewWidth > 0) {
      cols = terminal.viewWidth;
    }

    debugPrint(
        '[TerminalModel] Opening terminal $terminalId, sessionId: ${parent.sessionId}, size: ${cols}x$rows');
    try {
      await bind
          .sessionOpenTerminal(
        sessionId: parent.sessionId,
        terminalId: terminalId,
        rows: rows,
        cols: cols,
      )
          .timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException(
              'sessionOpenTerminal timed out after 5 seconds');
        },
      );
      debugPrint('[TerminalModel] sessionOpenTerminal called successfully');
    } catch (e) {
      debugPrint('[TerminalModel] Error calling sessionOpenTerminal: $e');
      // Optionally show error to user
      if (e is TimeoutException) {
        _writeToTerminal('Failed to open terminal: Connection timeout\r\n');
      }
    }
  }

  Future<void> sendVirtualKey(String data) async {
    return _handleInput(data);
  }

  Future<void> closeTerminal() async {
    if (_terminalOpened) {
      try {
        await bind
            .sessionCloseTerminal(
          sessionId: parent.sessionId,
          terminalId: terminalId,
        )
            .timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            throw TimeoutException(
                'sessionCloseTerminal timed out after 3 seconds');
          },
        );
        debugPrint('[TerminalModel] sessionCloseTerminal called successfully');
      } catch (e) {
        debugPrint('[TerminalModel] Error calling sessionCloseTerminal: $e');
        // Continue with cleanup even if close fails
      }
      _terminalOpened = false;
      notifyListeners();
    }
  }

  static int getTerminalIdFromEvt(Map<String, dynamic> evt) {
    if (evt.containsKey('terminal_id')) {
      final v = evt['terminal_id'];
      if (v is int) {
        // Desktop and mobile send terminal_id as an int
        return v;
      } else if (v is String) {
        // Web sends terminal_id as a string
        final parsed = int.tryParse(v);
        if (parsed != null) {
          return parsed;
        } else {
          debugPrint(
              '[TerminalModel] Failed to parse terminal_id as integer: $v. Expected a numeric string.');
          return 0;
        }
      } else {
        // Unexpected type, log and handle gracefully
        debugPrint(
            '[TerminalModel] Unexpected terminal_id type: ${v.runtimeType}, value: $v. Expected int or String.');
        return 0;
      }
    } else {
      debugPrint('[TerminalModel] Event does not contain terminal_id');
      return 0;
    }
  }

  static bool getSuccessFromEvt(Map<String, dynamic> evt) {
    if (evt.containsKey('success')) {
      final v = evt['success'];
      if (v is bool) {
        // Desktop and mobile
        return v;
      } else if (v is String) {
        // Web
        return v.toLowerCase() == 'true';
      } else {
        // Unexpected type, log and handle gracefully
        debugPrint(
            '[TerminalModel] Unexpected success type: ${v.runtimeType}, value: $v. Expected bool or String.');
        return false;
      }
    } else {
      debugPrint('[TerminalModel] Event does not contain success');
      return false;
    }
  }

  void handleTerminalResponse(Map<String, dynamic> evt) {
    final String? type = evt['type'];
    final int evtTerminalId = getTerminalIdFromEvt(evt);

    // Only handle events for this terminal
    if (evtTerminalId != terminalId) {
      debugPrint(
          '[TerminalModel] Ignoring event for terminal $evtTerminalId (not mine)');
      return;
    }

    switch (type) {
      case 'opened':
        _handleTerminalOpened(evt);
        break;
      case 'data':
        _handleTerminalData(evt);
        break;
      case 'closed':
        _handleTerminalClosed(evt);
        break;
      case 'error':
        _handleTerminalError(evt);
        break;
    }
  }

  void _handleTerminalOpened(Map<String, dynamic> evt) {
    final bool success = getSuccessFromEvt(evt);
    final String message = evt['message']?.toString() ?? '';
    final String? serviceId = evt['service_id']?.toString();

    debugPrint(
        '[TerminalModel] Terminal opened response: success=$success, message=$message, service_id=$serviceId');

    if (success) {
      _terminalOpened = true;

      // On reconnect ("Reconnected to existing terminal"), server may replay recent output.
      // If this TerminalView instance is reused (not rebuilt), duplicate lines can appear.
      // We intentionally accept this tradeoff for now to keep logic simple.

      // Fallback: if terminal view is not yet ready but already has valid
      // dimensions (e.g. layout completed before open response arrived),
      // mark view ready now to avoid output stuck in buffer indefinitely.
      if (!_terminalViewReady &&
          terminal.viewWidth > 0 &&
          terminal.viewHeight > 0) {
        _markViewReady();
      }

      final persistentSessions =
          evt['persistent_sessions'] as List<dynamic>? ?? [];
      if (kWindowId != null && persistentSessions.isNotEmpty) {
        DesktopMultiWindow.invokeMethod(
            kWindowId!,
            kWindowEventRestoreTerminalSessions,
            jsonEncode({
              'persistent_sessions': persistentSessions,
            }));
      }

      if (deferFlushAfterOpenForProfileProbe) {
        scheduleMicrotask(() => onDeferredProfileProbe?.call());
        return;
      }

      _invokeOpenFlushSequence();
    } else {
      _writeToTerminal('Failed to open terminal: $message\r\n');
    }
  }

  Future<void> _processBufferedInputAsync() async {
    final buffer = List<String>.from(_inputBuffer);
    _inputBuffer.clear();

    for (final data in buffer) {
      try {
        await bind.sessionSendTerminalInput(
          sessionId: parent.sessionId,
          terminalId: terminalId,
          data: data,
        );
      } catch (e) {
        debugPrint('[TerminalModel] Error sending buffered input: $e');
      }
    }
  }

  void _handleTerminalData(Map<String, dynamic> evt) {
    final data = evt['data'];

    if (data != null) {
      try {
        String text = '';
        if (data is String) {
          // Try to decode as base64 first
          try {
            final bytes = base64Decode(data);
            text = utf8.decode(bytes, allowMalformed: true);
          } catch (e) {
            // If base64 decode fails, treat as plain text
            text = data;
          }
        } else if (data is List) {
          // Handle if data comes as byte array
          text = utf8.decode(List<int>.from(data), allowMalformed: true);
        } else {
          debugPrint('[TerminalModel] Unknown data type: ${data.runtimeType}');
          return;
        }

        _writeToTerminal(text);
      } catch (e) {
        debugPrint('[TerminalModel] Failed to process terminal data: $e');
      }
    }
  }

  /// Write text to terminal, buffering if the view is not yet ready.
  /// All terminal output should go through this method to avoid NaN errors
  /// from writing before the terminal view has valid layout dimensions.
  void _writeToTerminal(String text) {
    onRemoteTextOutput?.call(text);
    final out = rtlEnrichHebrewTerminalLines(text);
    if (!_terminalViewReady) {
      // If a single chunk exceeds the cap, keep only its tail.
      // Note: truncation may split a multi-byte ANSI escape sequence,
      // which can cause a brief visual glitch on flush. This is acceptable
      // because it only affects the pre-layout buffering window and the
      // terminal will self-correct on subsequent output.
      if (out.length >= _kMaxOutputBufferChars) {
        final truncated = out.substring(out.length - _kMaxOutputBufferChars);
        _pendingOutputChunks
          ..clear()
          ..add(truncated);
        _pendingOutputSize = truncated.length;
      } else {
        _pendingOutputChunks.add(out);
        _pendingOutputSize += out.length;
        // Drop oldest chunks if exceeds limit (whole chunks to preserve ANSI sequences)
        while (_pendingOutputSize > _kMaxOutputBufferChars &&
            _pendingOutputChunks.length > 1) {
          final removed = _pendingOutputChunks.removeAt(0);
          _pendingOutputSize -= removed.length;
        }
      }
      return;
    }
    terminal.write(out);
  }

  void _flushOutputBuffer() {
    if (_pendingOutputChunks.isEmpty) return;
    debugPrint(
        '[TerminalModel] Flushing $_pendingOutputSize buffered chars (${_pendingOutputChunks.length} chunks)');
    for (final chunk in _pendingOutputChunks) {
      terminal.write(chunk);
    }
    _pendingOutputChunks.clear();
    _pendingOutputSize = 0;
  }

  /// Mark terminal view as ready and flush buffered output.
  void _markViewReady() {
    if (_terminalViewReady) return;
    _terminalViewReady = true;
    _flushOutputBuffer();
  }

  void _handleTerminalClosed(Map<String, dynamic> evt) {
    final int exitCode = evt['exit_code'] ?? 0;
    _writeToTerminal('\r\nTerminal closed with exit code: $exitCode\r\n');
    _terminalOpened = false;
    _shellOpenedOnceNotified = false;
    deferFlushAfterOpenForProfileProbe = false;
    notifyListeners();
  }

  void _handleTerminalError(Map<String, dynamic> evt) {
    final String message = evt['message'] ?? 'Unknown error';
    _writeToTerminal('\r\nTerminal error: $message\r\n');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Clear buffers to free memory
    _inputBuffer.clear();
    _pendingOutputChunks.clear();
    _pendingOutputSize = 0;
    // Terminal cleanup is handled server-side when service closes
    super.dispose();
  }
}
