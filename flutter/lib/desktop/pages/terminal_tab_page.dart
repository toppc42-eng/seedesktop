import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/rmm_pro_gate_dialog.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/desktop/widgets/ps_command_dialogs.dart';
import 'package:flutter_hbb/desktop/widgets/terminal_appearance_dialog.dart';
import 'package:flutter_hbb/utils/global_ps_catalog_store.dart';
import 'package:flutter_hbb/utils/ps_commands_catalogue.dart';
import 'package:flutter_hbb/utils/rmm_custom_scripts_store.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/platform_model.dart';
import 'terminal_page.dart';
import 'terminal_connection_manager.dart';
import 'terminal_appearance_prefs.dart';
import '../widgets/material_mod_popup_menu.dart' as mod_menu;
import '../widgets/popup_menu.dart';
import 'package:bot_toast/bot_toast.dart';

class TerminalTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const TerminalTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<TerminalTabPage> createState() => _TerminalTabPageState(params);
}

class _TerminalTabPageState extends State<TerminalTabPage> {
  DesktopTabController get tabController => Get.find<DesktopTabController>();

  static const IconData selectedIcon = Icons.terminal;
  static const IconData unselectedIcon = Icons.terminal_outlined;
  int _nextTerminalId = 1;
  // Lightweight idempotency guard for async close operations
  final Set<String> _closingTabs = {};
  // When true, all session cleanup should persist (window-level close in progress)
  bool _windowClosing = false;

  // PS command panel state (open by default so commands are one tap away)
  bool _showPsPanel = true;
  final TextEditingController _psSearchController = TextEditingController();
  String _psQuery = '';
  /// Saved in Script Manager; same store as [RmmCustomScriptsStore].
  List<RmmCustomScript> _customScripts = const [];
  /// Persisted global PS entries; merged after built-in [psCatalogue].
  List<GlobalPsSectionEntry> _globalPsSections = const [];

  Future<bool> _ensureRmmLicenseOrShowUpgrade() async {
    if (await hasRmmLicenseLocal()) return true;
    if (mounted) await showRmmProGateDialog(context);
    return false;
  }

  _TerminalTabPageState(Map<String, dynamic> params) {
    Get.put(DesktopTabController(tabType: DesktopTabType.terminal));
    tabController.onSelected = (id) {
      () async {
        final title = await getWindowNameWithIdAndLicense(id);
        await WindowController.fromWindowId(windowId()).setTitle(title);
      }();
    };
    tabController.onRemoved = (_, id) => onRemoveId(id);
    final terminalId = params['terminalId'] ?? _nextTerminalId++;
    final tab = _createTerminalTab(
      peerId: params['id'],
      terminalId: terminalId,
      password: params['password'],
      isSharedPassword: params['isSharedPassword'],
      forceRelay: params['forceRelay'],
      connToken: params['connToken'],
    );
    tabController.add(tab);
  }

  Future<void> _loadCustomScripts() async {
    try {
      final list = await RmmCustomScriptsStore.load();
      if (mounted) setState(() => _customScripts = list);
    } catch (_) {
      if (mounted) setState(() => _customScripts = const []);
    }
  }

  Future<void> _loadGlobalPsCatalog() async {
    try {
      final list = await GlobalPsCatalogStore.load();
      if (mounted) setState(() => _globalPsSections = list);
    } catch (_) {
      if (mounted) setState(() => _globalPsSections = const []);
    }
  }

  List<RmmCustomScript> _filteredCustomScripts() {
    final q = _psQuery.trim().toLowerCase();
    if (q.isEmpty) return List<RmmCustomScript>.from(_customScripts);
    return _customScripts.where((s) {
      return s.title.toLowerCase().contains(q) ||
          s.body.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _openTerminalAppearanceDialog() async {
    final p = await SharedPreferences.getInstance();
    var bg = Colors.black;
    var fg = Colors.white;
    final bgI = p.getInt(kPrefTerminalBgArgb);
    final fgI = p.getInt(kPrefTerminalFgArgb);
    if (bgI != null) {
      // ignore: deprecated_member_use
      bg = Color(bgI);
    }
    if (fgI != null) {
      // ignore: deprecated_member_use
      fg = Color(fgI);
    }
    if (!mounted) return;
    await showTerminalAppearanceDialog(
      context,
      initialBackground: bg,
      initialForeground: fg,
      onApply: (theme, _, __) {
        for (final tab in tabController.state.value.tabs) {
          final page = tab.page;
          if (page is TerminalPage) {
            page.applyTerminalTheme(theme);
          }
        }
      },
    );
  }

  /// Paste [cmd] + Enter into the currently selected terminal tab.
  void _pasteToActiveTerminal(String cmd) {
    final state = tabController.state.value;
    final idx = state.selected;
    if (idx >= 0 && idx < state.tabs.length) {
      final page = state.tabs[idx].page;
      if (page is TerminalPage) {
        page.pasteRemoteScript('$cmd\r');
      }
    }
  }

  TabInfo _createTerminalTab({
    required String peerId,
    required int terminalId,
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
    String? connToken,
  }) {
    final tabKey = '${peerId}_$terminalId';
    final alias = bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
    final tabLabel =
        alias.isNotEmpty ? '$alias #$terminalId' : '$peerId #$terminalId';
    return TabInfo(
      key: tabKey,
      label: tabLabel,
      selectedIcon: selectedIcon,
      unselectedIcon: unselectedIcon,
      onTabCloseButton: () => _closeTab(tabKey),
      page: TerminalPage(
        key: ValueKey(tabKey),
        id: peerId,
        terminalId: terminalId,
        tabKey: tabKey,
        password: password,
        isSharedPassword: isSharedPassword,
        tabController: tabController,
        forceRelay: forceRelay,
        connToken: connToken,
        onOpenTerminalAppearance: () => unawaited(_openTerminalAppearanceDialog()),
      ),
    );
  }

  /// Unified tab close handler for all close paths (button, shortcut, programmatic).
  /// Shows audit dialog, cleans up session if not persistent, then removes the UI tab.
  Future<void> _closeTab(String tabKey) async {
    // Idempotency guard: skip if already closing this tab
    if (_closingTabs.contains(tabKey)) return;
    _closingTabs.add(tabKey);

    try {
      // Snapshot peerTabCount BEFORE any await to avoid race with concurrent
      // _closeAllTabs clearing tabController (which would make the live count
      // drop to 0 and incorrectly trigger session persistence).
      // Note: the snapshot may become stale if other individual tabs are closed
      // during the audit dialog, but this is an acceptable trade-off.
      int? snapshotPeerTabCount;
      final parsed = _parseTabKey(tabKey);
      if (parsed != null) {
        final (peerId, _) = parsed;
        snapshotPeerTabCount = tabController.state.value.tabs.where((t) {
          final p = _parseTabKey(t.key);
          return p != null && p.$1 == peerId;
        }).length;
      }

      if (await desktopTryShowTabAuditDialogCloseCancelled(
        id: tabKey,
        tabController: tabController,
      )) {
        return;
      }

      // Close terminal session if not in persistent mode.
      // Wrapped separately so session cleanup failure never blocks UI tab removal.
      try {
        await _closeTerminalSessionIfNeeded(tabKey,
            peerTabCount: snapshotPeerTabCount);
      } catch (e) {
        debugPrint('[TerminalTabPage] Session cleanup failed for $tabKey: $e');
      }
      // Always close the tab from UI, regardless of session cleanup result
      tabController.closeBy(tabKey);
    } catch (e) {
      debugPrint('[TerminalTabPage] Error closing tab $tabKey: $e');
    } finally {
      _closingTabs.remove(tabKey);
    }
  }

  /// Close all tabs with session cleanup.
  /// Used for window-level close operations (onDestroy, handleWindowCloseButton).
  /// UI tabs are removed immediately; session cleanup runs in parallel with a
  /// bounded timeout so window close is not blocked indefinitely.
  Future<void> _closeAllTabs() async {
    _windowClosing = true;
    final tabKeys = tabController.state.value.tabs.map((t) => t.key).toList();
    // Remove all UI tabs immediately (same instant behavior as the old tabController.clear())
    tabController.clear();
    // Run session cleanup in parallel with bounded timeout (closeTerminal() has internal 3s timeout).
    // Skip tabs already being closed by a concurrent _closeTab() to avoid duplicate FFI calls.
    final futures = tabKeys
        .where((tabKey) => !_closingTabs.contains(tabKey))
        .map((tabKey) async {
      try {
        await _closeTerminalSessionIfNeeded(tabKey, persistAll: true);
      } catch (e) {
        debugPrint('[TerminalTabPage] Session cleanup failed for $tabKey: $e');
      }
    }).toList();
    if (futures.isNotEmpty) {
      await Future.wait(futures).timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          debugPrint(
              '[TerminalTabPage] Session cleanup timed out for batch close');
          return [];
        },
      );
    }
  }

  /// Close the terminal session on server side based on persistent mode.
  ///
  /// [persistAll] controls behavior when persistent mode is enabled:
  /// - `true` (window close): persist all sessions, don't close any.
  /// - `false` (tab close): only persist the last session for the peer,
  ///   close others so only the most recent disconnected session survives.
  ///
  /// Note: if [_windowClosing] is true, persistAll is forced to true so that
  /// in-flight _closeTab() calls don't accidentally close sessions that the
  /// window-close flow intends to preserve.
  Future<void> _closeTerminalSessionIfNeeded(String tabKey,
      {bool persistAll = false, int? peerTabCount}) async {
    // If window close is in progress, override to persist all sessions
    // even if this call originated from an individual tab close.
    if (_windowClosing) {
      persistAll = true;
    }
    final parsed = _parseTabKey(tabKey);
    if (parsed == null) return;
    final (peerId, terminalId) = parsed;

    final ffi = TerminalConnectionManager.getExistingConnection(peerId);
    if (ffi == null) return;

    final isPersistent = bind.sessionGetToggleOptionSync(
      sessionId: ffi.sessionId,
      arg: kOptionTerminalPersistent,
    );

    if (isPersistent) {
      if (persistAll) {
        // Window close: persist all sessions
        return;
      }
      // Tab close: only persist if this is the last tab for this peer.
      // Use the snapshot value if provided (avoids race with concurrent tab removal).
      final effectivePeerTabCount = peerTabCount ??
          tabController.state.value.tabs.where((t) {
            final p = _parseTabKey(t.key);
            return p != null && p.$1 == peerId;
          }).length;
      if (effectivePeerTabCount <= 1) {
        // Last tab for this peer — persist the session
        return;
      }
      // Not the last tab — fall through to close the session
    }

    final terminalModel = ffi.terminalModels[terminalId];
    if (terminalModel != null) {
      // closeTerminal() has internal 3s timeout, no need for external timeout
      await terminalModel.closeTerminal();
    }
  }

  /// Parse tabKey (format: "peerId_terminalId") into its components.
  /// Note: peerId may contain underscores, so we use lastIndexOf('_').
  /// Returns null if tabKey format is invalid.
  (String peerId, int terminalId)? _parseTabKey(String tabKey) {
    final lastUnderscore = tabKey.lastIndexOf('_');
    if (lastUnderscore <= 0) {
      debugPrint('[TerminalTabPage] Invalid tabKey format: $tabKey');
      return null;
    }
    final terminalIdStr = tabKey.substring(lastUnderscore + 1);
    final terminalId = int.tryParse(terminalIdStr);
    if (terminalId == null) {
      debugPrint('[TerminalTabPage] Invalid terminalId in tabKey: $tabKey');
      return null;
    }
    final peerId = tabKey.substring(0, lastUnderscore);
    return (peerId, terminalId);
  }

  Widget _tabMenuBuilder(String peerId, CancelFunc cancelFunc) {
    final List<MenuEntryBase<String>> menu = [];
    const EdgeInsets padding = EdgeInsets.only(left: 8.0, right: 5.0);

    // New tab menu item
    menu.add(MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('New tab'),
        style: style,
      ),
      proc: () {
        _addNewTerminal(peerId);
        cancelFunc();
        // Also try to close any BotToast overlays
        BotToast.cleanAll();
      },
      padding: padding,
    ));

    menu.add(MenuEntryDivider());

    menu.add(MenuEntrySwitch<String>(
      switchType: SwitchType.scheckbox,
      text: translate('Keep terminal sessions on disconnect'),
      getter: () async {
        final ffi = Get.find<FFI>(tag: 'terminal_$peerId');
        return bind.sessionGetToggleOptionSync(
          sessionId: ffi.sessionId,
          arg: kOptionTerminalPersistent,
        );
      },
      setter: (bool v) async {
        final ffi = Get.find<FFI>(tag: 'terminal_$peerId');
        await bind.sessionToggleOption(
          sessionId: ffi.sessionId,
          value: kOptionTerminalPersistent,
        );
      },
      padding: padding,
    ));

    return mod_menu.PopupMenu<String>(
      items: menu
          .map((e) => e.build(
                context,
                const MenuConfig(
                  commonColor: CustomPopupMenuTheme.commonColor,
                  height: CustomPopupMenuTheme.height,
                  dividerHeight: CustomPopupMenuTheme.dividerHeight,
                ),
              ))
          .expand((i) => i)
          .toList(),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadCustomScripts());
    unawaited(_loadGlobalPsCatalog());

    // Add keyboard shortcut handler
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      if (kDebugMode) {
        debugPrint(
            "[Remote Terminal] call ${call.method} with args ${call.arguments} from window $fromWindowId");
      }
      if (call.method == kWindowEventNewTerminal) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        windowOnTop(windowId());
        // Allow multiple terminals for the same connection
        final terminalId = args['terminalId'] ?? _nextTerminalId++;
        tabController.add(_createTerminalTab(
          peerId: id,
          terminalId: terminalId,
          password: args['password'],
          isSharedPassword: args['isSharedPassword'],
          forceRelay: args['forceRelay'],
          connToken: args['connToken'],
        ));
      } else if (call.method == kWindowEventRestoreTerminalSessions) {
        _restoreSessions(call.arguments);
      } else if (call.method == "onDestroy") {
        // Clean up sessions before window destruction (bounded wait)
        await _closeAllTabs();
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      } else if (call.method == kWindowEventActiveSession) {
        if (tabController.state.value.tabs.isEmpty) {
          return false;
        }
        assert(call.arguments is String,
            "Expected String arguments for kWindowEventActiveSession, got ${call.arguments.runtimeType}");
        final remoteArg = (call.arguments as String).trim();
        if (remoteArg.isEmpty) {
          return false;
        }
        final normRemote = remoteArg.replaceAll(' ', '');
        var matchIndex = -1;
        for (var i = 0; i < tabController.state.value.tabs.length; i++) {
          final parsed = _parseTabKey(tabController.state.value.tabs[i].key);
          if (parsed == null) continue;
          final (peerId, _) = parsed;
          if (peerId.replaceAll(' ', '') == normRemote) {
            matchIndex = i;
            break;
          }
        }
        if (matchIndex < 0) {
          return false;
        }
        tabController.jumpTo(matchIndex);
        windowOnTop(windowId());
        return true;
      }
    });
    Future.delayed(Duration.zero, () {
      restoreWindowPosition(WindowType.Terminal, windowId: windowId());
    });
  }

  @override
  void dispose() {
    _psSearchController.dispose();
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  Future<void> _restoreSessions(String arguments) async {
    Map<String, dynamic>? args;
    try {
      args = jsonDecode(arguments) as Map<String, dynamic>;
    } catch (e) {
      debugPrint("Error parsing JSON arguments in _restoreSessions: $e");
      return;
    }
    final persistentSessions =
        args['persistent_sessions'] as List<dynamic>? ?? [];
    final sortedSessions = persistentSessions.whereType<int>().toList()..sort();
    for (final terminalId in sortedSessions) {
      _addNewTerminalForCurrentPeer(terminalId: terminalId);
      // A delay is required to ensure the UI has sufficient time to update
      // before adding the next terminal. Without this delay, `_TerminalPageState::dispose()`
      // may be called prematurely while the tab widget is still in the tab controller.
      // This behavior is likely due to a race condition between the UI rendering lifecycle
      // and the addition of new tabs. Attempts to use `_TerminalPageState::addPostFrameCallback()`
      // to wait for the previous page to be ready were unsuccessful, as the observed call sequence is:
      // `initState() 2 -> dispose() 2 -> postFrameCallback() 2`, followed by `initState() 3`.
      // The `Future.delayed` approach mitigates this issue by introducing a buffer period,
      // allowing the UI to stabilize before proceeding.
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      // Use Cmd+T on macOS, Ctrl+Shift+T on other platforms
      if (event.logicalKey == LogicalKeyboardKey.keyT) {
        if (isMacOS &&
            HardwareKeyboard.instance.isMetaPressed &&
            !HardwareKeyboard.instance.isShiftPressed) {
          // macOS: Cmd+T (standard for new tab)
          _addNewTerminalForCurrentPeer();
          return true;
        } else if (!isMacOS &&
            HardwareKeyboard.instance.isControlPressed &&
            HardwareKeyboard.instance.isShiftPressed) {
          // Other platforms: Ctrl+Shift+T (to avoid conflict with Ctrl+T in terminal)
          _addNewTerminalForCurrentPeer();
          return true;
        }
      }

      // Use Cmd+W on macOS, Ctrl+Shift+W on other platforms
      if (event.logicalKey == LogicalKeyboardKey.keyW) {
        if (isMacOS &&
            HardwareKeyboard.instance.isMetaPressed &&
            !HardwareKeyboard.instance.isShiftPressed) {
          // macOS: Cmd+W (standard for close tab)
          final currentTab = tabController.state.value.selectedTabInfo;
          if (tabController.state.value.tabs.length > 1) {
            _closeTab(currentTab.key);
            return true;
          }
        } else if (!isMacOS &&
            HardwareKeyboard.instance.isControlPressed &&
            HardwareKeyboard.instance.isShiftPressed) {
          // Other platforms: Ctrl+Shift+W (to avoid conflict with Ctrl+W word delete)
          final currentTab = tabController.state.value.selectedTabInfo;
          if (tabController.state.value.tabs.length > 1) {
            _closeTab(currentTab.key);
            return true;
          }
        }
      }

      // Use Alt+Left/Right for tab navigation (avoids conflicts)
      if (HardwareKeyboard.instance.isAltPressed) {
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          // Previous tab
          final currentIndex = tabController.state.value.selected;
          if (currentIndex > 0) {
            tabController.jumpTo(currentIndex - 1);
          }
          return true;
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          // Next tab
          final currentIndex = tabController.state.value.selected;
          if (currentIndex < tabController.length - 1) {
            tabController.jumpTo(currentIndex + 1);
          }
          return true;
        }
      }

      // Check for Cmd/Ctrl + Number (switch to specific tab)
      final numberKeys = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit7,
        LogicalKeyboardKey.digit8,
        LogicalKeyboardKey.digit9,
      ];

      for (int i = 0; i < numberKeys.length; i++) {
        if (event.logicalKey == numberKeys[i] &&
            ((isMacOS && HardwareKeyboard.instance.isMetaPressed) ||
                (!isMacOS && HardwareKeyboard.instance.isControlPressed))) {
          if (i < tabController.length) {
            tabController.jumpTo(i);
            return true;
          }
        }
      }
    }
    return false;
  }

  void _addNewTerminal(String peerId, {int? terminalId}) {
    // Find first tab for this peer to get connection parameters
    final firstTab = tabController.state.value.tabs.firstWhere(
      (tab) {
        final last = tab.key.lastIndexOf('_');
        return last > 0 && tab.key.substring(0, last) == peerId;
      },
    );
    if (firstTab.page is TerminalPage) {
      final page = firstTab.page as TerminalPage;
      final newTerminalId = terminalId ?? _nextTerminalId++;
      if (terminalId != null && terminalId >= _nextTerminalId) {
        _nextTerminalId = terminalId + 1;
      }
      tabController.add(_createTerminalTab(
        peerId: peerId,
        terminalId: newTerminalId,
        password: page.password,
        isSharedPassword: page.isSharedPassword,
        forceRelay: page.forceRelay,
        connToken: page.connToken,
      ));
    }
  }

  void _addNewTerminalForCurrentPeer({int? terminalId}) {
    final currentTab = tabController.state.value.selectedTabInfo;
    final parsed = _parseTabKey(currentTab.key);
    if (parsed == null) return;
    final (peerId, _) = parsed;
    _addNewTerminal(peerId, terminalId: terminalId);
  }

  Widget _buildTabBarTrail({required bool scriptsUiEnabled}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'צבעי טרמינל (רקע וטקסט)',
          child: InkWell(
            onTap: () => unawaited(_openTerminalAppearanceDialog()),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Icon(
                Icons.palette_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ),
        ),
        if (scriptsUiEnabled)
          Tooltip(
            message: _showPsPanel ? 'סגור פאנל פקודות' : 'פקודות PowerShell',
            child: InkWell(
              onTap: () async {
                final openingPanel = !_showPsPanel;
                if (openingPanel && !await _ensureRmmLicenseOrShowUpgrade()) {
                  return;
                }
                setState(() {
                  _showPsPanel = !_showPsPanel;
                  if (!_showPsPanel) {
                    _psSearchController.clear();
                    _psQuery = '';
                  }
                });
                if (_showPsPanel) {
                  unawaited(_loadCustomScripts());
                  unawaited(_loadGlobalPsCatalog());
                }
              },
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Icon(
                  Icons.terminal,
                  size: 16,
                  color: _showPsPanel
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
            ),
          ),
        _buildAddButton(),
      ],
    );
  }

  Widget _buildPsPanel(BuildContext context) {
    final merged = GlobalPsCatalogStore.mergeCatalogues(_globalPsSections);
    final sections = filterPsSections(_psQuery, catalogue: merged);
    final customFiltered = _filteredCustomScripts();
    final hasCatalog = sections.isNotEmpty;
    final hasAny = hasCatalog || customFiltered.isNotEmpty;
    final theme = Theme.of(context);
    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          left: BorderSide(color: theme.dividerColor, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: theme.dividerColor, width: 1)),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 14, color: Colors.blueGrey),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('פקודות PS',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 24, minHeight: 24),
                  onPressed: () => setState(() {
                    _showPsPanel = false;
                    _psSearchController.clear();
                    _psQuery = '';
                  }),
                ),
              ],
            ),
          ),
          // Search
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: TextField(
              controller: _psSearchController,
              onChanged: (v) => setState(() => _psQuery = v),
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: 'חפש...',
                hintStyle: const TextStyle(fontSize: 11),
                prefixIcon:
                    const Icon(Icons.search, size: 14),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
          // Commands
          Expanded(
            child: !hasAny
                ? const Center(
                    child: Text('לא נמצאו פקודות',
                        style:
                            TextStyle(color: Colors.grey, fontSize: 11)))
                : ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      if (customFiltered.isNotEmpty)
                        ExpansionTile(
                          key: const PageStorageKey<String>('ps_cat_custom'),
                          tilePadding:
                              const EdgeInsets.symmetric(horizontal: 6),
                          initiallyExpanded: true,
                          title: Text(
                            translate('script-manager-tab-custom'),
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 11,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          children: [
                            for (final s in customFiltered)
                              InkWell(
                                onTap: () async {
                                  if (!await _ensureRmmLicenseOrShowUpgrade()) {
                                    return;
                                  }
                                  final cmd = s.body.trim();
                                  if (cmd.isEmpty) return;
                                  _pasteToActiveTerminal(cmd);
                                  BotToast.showText(
                                    text: '▶ ${s.title}',
                                    duration: const Duration(seconds: 2),
                                  );
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 7),
                                  child: Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: Text(
                                      s.title.isNotEmpty
                                          ? s.title
                                          : translate(
                                              'script-manager-custom'),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      for (final g in groupCatalogSections(sections))
                        ExpansionTile(
                          key: PageStorageKey<String>('ps_cat_${g.title}'),
                          tilePadding:
                              const EdgeInsets.symmetric(horizontal: 6),
                          initiallyExpanded: true,
                          title: Text(
                            psSectionDisplayGroup(g.sections.first),
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 11,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          children: [
                            for (final sec in g.sections) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    10, 6, 8, 2),
                                child: Align(
                                  alignment:
                                      AlignmentDirectional.centerStart,
                                  child: Text(
                                    psSectionDisplayLabel(sec),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 10,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                              for (final cmd in sec.cmds)
                                InkWell(
                                  onTap: () async {
                                    if (!await _ensureRmmLicenseOrShowUpgrade()) {
                                      return;
                                    }
                                    final resolved =
                                        await showPsCommandResolveDialog(
                                            context, cmd);
                                    if (resolved == null ||
                                        resolved.isEmpty ||
                                        !context.mounted) {
                                      return;
                                    }
                                    _pasteToActiveTerminal(resolved);
                                    BotToast.showText(
                                        text: '▶ ${psCmdDisplayTitle(cmd)}',
                                        duration: const Duration(
                                            seconds: 2));
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 7),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          psCmdDisplayTitle(cmd),
                                          style: const TextStyle(
                                              fontSize: 12),
                                        ),
                                        if (psCmdDisplayHint(cmd) != null)
                                          Text(
                                            psCmdDisplayHint(cmd)!,
                                            style: const TextStyle(
                                                fontSize: 10,
                                                color: Colors.blueGrey),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Same PowerShell catalogue as the remote session toolbar ("PowerShell commands");
    // always available here — not gated on Settings → Admin visibility.
    const scriptsUiEnabled = true;
    final desk = DesktopTab(
      controller: tabController,
      onWindowCloseButton: handleWindowCloseButton,
      tail: _buildTabBarTrail(scriptsUiEnabled: scriptsUiEnabled),
      selectedBorderColor: MyTheme.accent,
      labelGetter: DesktopTab.tablabelGetter,
      tabMenuBuilder: (key) {
        final parsed = _parseTabKey(key);
        if (parsed == null) return Container();
        final (peerId, _) = parsed;
        return _tabMenuBuilder(peerId, () {});
      },
    );

    final showPs = scriptsUiEnabled && _showPsPanel;
    final body = showPs
        ? Row(
            children: [
              Expanded(child: desk),
              _buildPsPanel(context),
            ],
          )
        : desk;

    final child = Scaffold(backgroundColor: Colors.black, body: body);
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(context, child)
        : workaroundWindowBorder(
            context,
            Container(
              decoration: BoxDecoration(
                  border: Border.all(color: MyTheme.color(context).border!)),
              child: child,
            ));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : SubWindowDragToResizeArea(
            child: tabWidget,
            resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
            enableResizeEdges: subWindowManagerEnableResizeEdges,
            windowId: stateGlobal.windowId,
          );
  }

  void onRemoveId(String id) {
    if (tabController.state.value.tabs.isEmpty) {
      WindowController.fromWindowId(windowId()).close();
    }
  }

  int windowId() {
    return widget.params["windowId"];
  }

  Widget _buildAddButton() {
    return ActionIcon(
      message: 'New tab',
      icon: IconFont.add,
      onTap: () {
        _addNewTerminalForCurrentPeer();
      },
      isClose: false,
    );
  }

  Future<bool> handleWindowCloseButton() async {
    final connLength = tabController.state.value.tabs.length;
    if (connLength == 1) {
      if (await desktopTryShowTabAuditDialogCloseCancelled(
        id: tabController.state.value.tabs[0].key,
        tabController: tabController,
      )) {
        return false;
      }
    }
    if (connLength <= 1) {
      await _closeAllTabs();
      return true;
    } else {
      final bool res;
      if (!option2bool(kOptionEnableConfirmClosingTabs,
          bind.mainGetLocalOption(key: kOptionEnableConfirmClosingTabs))) {
        res = true;
      } else {
        res = await closeConfirmDialog();
      }
      if (res) {
        await _closeAllTabs();
      }
      return res;
    }
  }
}
