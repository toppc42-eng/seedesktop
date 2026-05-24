import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import '../consts.dart';
import './platform_model.dart';

enum SvcStatus { notReady, connecting, ready }

class StateGlobal {
  int _windowId = -1;
  final RxBool _fullscreen = false.obs;
  bool _isMinimized = false;
  final RxBool isMaximized = false.obs;
  /// Main window, home tab: after title-bar restore, show only the two connection
  /// panels (Your Desktop above remote) and hide the peer list area.
  final RxBool compactHomeConnectionLayout = false.obs;
  final RxBool _showTabBar = true.obs;
  final RxDouble _resizeEdgeSize = RxDouble(windowResizeEdgeSize);
  final RxDouble _windowBorderWidth = RxDouble(kWindowBorderWidth);
  final RxBool showRemoteToolBar = false.obs;
  final svcStatus = SvcStatus.notReady.obs;
  final RxInt videoConnCount = 0.obs;
  // Local guard to enforce one active outgoing connection for free users.
  // Stores active/outstanding outgoing session peer ids.
  final RxSet<String> freeActiveOutgoingPeerIds = <String>{}.obs;
  final RxBool isFocused = false.obs;
  final RxBool hideBottomNotificationBanner = false.obs;
  // for mobile and web
  bool isInMainPage = true;
  bool isWebVisible = true;

  final isPortrait = false.obs;

  final updateUrl = ''.obs;
  final RxBool hasOtaUpdate = false.obs;
  final RxString otaLatestVersion = ''.obs;
  final RxString otaDownloadUrl = ''.obs;
  final RxString otaReleaseNotes = ''.obs;

  String _inputSource = '';

  // Track relative mouse mode state for each peer connection.
  // Key: peerId, Value: true if relative mouse mode is active.
  // Note: This is session-only runtime state, NOT persisted to config.
  final RxMap<String, bool> relativeMouseModeState = <String, bool>{}.obs;

  // Use for desktop -> remote toolbar -> resolution
  final Map<String, Map<int, String?>> _lastResolutionGroupValues = {};

  int get windowId => _windowId;
  RxBool get fullscreen => _fullscreen;
  bool get isMinimized => _isMinimized;
  double get tabBarHeight => fullscreen.isTrue ? 0 : kDesktopRemoteTabBarHeight;
  RxBool get showTabBar => _showTabBar;
  RxDouble get resizeEdgeSize => _resizeEdgeSize;
  RxDouble get windowBorderWidth => _windowBorderWidth;

  resetLastResolutionGroupValues(String peerId) {
    _lastResolutionGroupValues[peerId] = {};
  }

  setLastResolutionGroupValue(
      String peerId, int currentDisplay, String? value) {
    if (!_lastResolutionGroupValues.containsKey(peerId)) {
      _lastResolutionGroupValues[peerId] = {};
    }
    _lastResolutionGroupValues[peerId]![currentDisplay] = value;
  }

  String? getLastResolutionGroupValue(String peerId, int currentDisplay) {
    return _lastResolutionGroupValues[peerId]?[currentDisplay];
  }

  setWindowId(int id) => _windowId = id;
  setMaximized(bool v) {
    if (!_fullscreen.isTrue) {
      if (isMaximized.value != v) {
        isMaximized.value = v;
        refreshResizeEdgeSize();
      }
      if (!isMacOS) {
        _windowBorderWidth.value = v ? 0 : kWindowBorderWidth;
      }
    }
  }

  setMinimized(bool v) => _isMinimized = v;

  setFullscreen(bool v, {bool procWnd = true}) {
    if (_fullscreen.value != v) {
      _fullscreen.value = v;
      _showTabBar.value = !_fullscreen.value;
      if (isWebDesktop) {
        procFullscreenWeb();
      } else {
        procFullscreenNative(procWnd);
      }
    }
  }

  procFullscreenWeb() {
    final isFullscreen = ffiGetByName('fullscreen') == 'Y';
    String fullscreenValue = '';
    if (isFullscreen && _fullscreen.isFalse) {
      fullscreenValue = 'N';
    } else if (!isFullscreen && fullscreen.isTrue) {
      fullscreenValue = 'Y';
    }
    if (fullscreenValue.isNotEmpty) {
      ffiSetByName('fullscreen', fullscreenValue);
    }
  }

  procFullscreenNative(bool procWnd) {
    refreshResizeEdgeSize();
    if (kDebugMode) {
      debugPrint(
          "fullscreen: $fullscreen, resizeEdgeSize: ${_resizeEdgeSize.value}");
    }
    _windowBorderWidth.value = fullscreen.isTrue ? 0 : kWindowBorderWidth;
    if (procWnd) {
      unawaited(_applyNativeFullscreen(_fullscreen.isTrue));
    }
  }

  Future<void> _applyNativeFullscreen(bool fullscreen) async {
    try {
      // True fullscreen (borderless), hides local OS taskbar on Windows.
      await windowManager.setFullScreen(fullscreen);
      final synced = await windowManager.isFullScreen();
      if (synced == fullscreen) {
        return;
      }
      debugPrint(
          "windowManager fullscreen state mismatch, fallback to WindowController");
    } catch (e) {
      debugPrint("windowManager.setFullScreen failed: $e");
    }

    // Fallback path for secondary windows / edge plugin cases.
    try {
      final wc = WindowController.fromWindowId(windowId);
      await wc.setFullscreen(fullscreen);
    } catch (e) {
      debugPrint("WindowController.setFullscreen fallback failed: $e");
    }
  }

  refreshResizeEdgeSize() => _resizeEdgeSize.value = fullscreen.isTrue
      ? kFullScreenEdgeSize
      : isMaximized.isTrue
          ? kMaximizeEdgeSize
          : windowResizeEdgeSize;

  String getInputSource({bool force = false}) {
    if (force || _inputSource.isEmpty) {
      _inputSource = bind.mainGetInputSource();
    }
    return _inputSource;
  }

  setInputSource(SessionID sessionId, String v) async {
    await bind.mainSetInputSource(sessionId: sessionId, value: v);
    _inputSource = bind.mainGetInputSource();
  }

  StateGlobal._() {
    if (isWebDesktop) {
      platformFFI.setFullscreenCallback((v) {
        _fullscreen.value = v;
      });
    }
  }

  static final StateGlobal instance = StateGlobal._();
}

// This final variable is initialized when the first time it is accessed.
final stateGlobal = StateGlobal.instance;
