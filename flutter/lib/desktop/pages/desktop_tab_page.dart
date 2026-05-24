import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
// import 'package:flutter/services.dart';

import '../../common/shared_state.dart';
import '../desktop_remote_tab_registry.dart';

class DesktopTabPage extends StatefulWidget {
  const DesktopTabPage({Key? key}) : super(key: key);

  @override
  State<DesktopTabPage> createState() => _DesktopTabPageState();

  static void onAddSetting(
      {SettingsTabKey initialPage = SettingsTabKey.general}) {
    try {
      DesktopTabController tabController = Get.find<DesktopTabController>();
      tabController.add(TabInfo(
          key: kTabLabelSettingPage,
          label: kTabLabelSettingPage,
          selectedIcon: Icons.build_sharp,
          unselectedIcon: Icons.build_outlined,
          page: DesktopSettingPage(
            key: const ValueKey(kTabLabelSettingPage),
            initialTabkey: initialPage,
          )));
      tabController.jumpToByKey(kTabLabelSettingPage);
    } catch (e) {
      debugPrintStack(label: '$e');
    }
  }

  static void onAddRemoteTab(
    String id, {
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
  }) {
    try {
      final tabController = Get.find<DesktopTabController>();
      final key = id;
      final exists = tabController.state.value.tabs.any((t) => t.key == key);
      if (!exists) {
        final remotePage = RemotePage(
          key: ValueKey(key),
          id: id,
          toolbarState: ToolbarState(),
          tabController: tabController,
          password: password,
          isSharedPassword: isSharedPassword,
          forceRelay: forceRelay,
        );
        tabController.add(TabInfo(
          key: key,
          label: id,
          selectedIcon: Icons.desktop_windows_sharp,
          unselectedIcon: Icons.desktop_windows_outlined,
          onTabCloseButton: () => unawaited(
            _requestRemoteTabClose(tabController, key, remotePage),
          ),
          page: remotePage,
        ));
      }
      tabController.jumpToByKey(key);
    } catch (e) {
      debugPrintStack(label: '$e');
    }
  }

  /// Opens another remote display for the same peer as a new tab (main window only).
  /// Primary tab must keep [TabInfo.key] == [peerId] so cache/session lookups stay correct.
  static void onAddRemoteDisplayTab(String peerId, int displayIndex) {
    try {
      final tabController = Get.find<DesktopTabController>();
      if (tabController.tabType != DesktopTabType.main) return;
      final key = '$peerId##display$displayIndex';
      final exists = tabController.state.value.tabs.any((t) => t.key == key);
      if (!exists) {
        final remotePage = RemotePage(
          key: ValueKey(key),
          id: peerId,
          toolbarState: ToolbarState(),
          tabController: tabController,
          tabWindowId: kMainWindowId,
          display: displayIndex,
          displays: [displayIndex],
        );
        tabController.add(TabInfo(
          key: key,
          label: '$peerId (${displayIndex + 1})',
          selectedIcon: Icons.desktop_windows_sharp,
          unselectedIcon: Icons.desktop_windows_outlined,
          onTabCloseButton: () => unawaited(
            _requestRemoteTabClose(tabController, key, remotePage),
          ),
          page: remotePage,
        ));
      }
      tabController.jumpToByKey(key);
    } catch (e) {
      debugPrintStack(label: '$e');
    }
  }

  static Future<void> _requestRemoteTabClose(
    DesktopTabController tabController,
    String tabKey,
    RemotePage remotePage,
  ) async {
    await remotePage.requestCloseSession(
      onCloseSession: () {
        final index = tabController.state.value.tabs
            .indexWhere((tab) => tab.key == tabKey);
        if (index >= 0) {
          tabController.remove(index);
        }
      },
    );
  }
}

class _DesktopTabPageState extends State<DesktopTabPage> {
  final tabController = DesktopTabController(tabType: DesktopTabType.main);
  bool _mainWindowCloseFlowActive = false;

  _DesktopTabPageState() {
    RemoteCountState.init();
    Get.put<DesktopTabController>(tabController);
    tabController.add(TabInfo(
        key: kTabLabelHomePage,
        label: kTabLabelHomePage,
        selectedIcon: Icons.home_sharp,
        unselectedIcon: Icons.home_outlined,
        closable: false,
        page: DesktopHomePage(
          key: const ValueKey(kTabLabelHomePage),
        )));
    if (bind.isIncomingOnly()) {
      tabController.onSelected = (key) {
        if (key == kTabLabelHomePage) {
          windowManager.setSize(getIncomingOnlyHomeSize());
          setResizable(false);
        } else {
          windowManager.setSize(getIncomingOnlySettingsSize());
          setResizable(true);
        }
      };
    }
    tabController.onRemoved ??= (_, __) {};
    _setDefaultHomeTab();
  }

  void _setDefaultHomeTab() {
    tabController.jumpToByKey(kTabLabelHomePage);
  }

  Future<bool> _handleMainWindowCloseButton() async {
    if (_mainWindowCloseFlowActive) return false;
    _mainWindowCloseFlowActive = true;
    try {
      final remoteTabs = tabController.state.value.tabs
          .where((tab) => tab.page is RemotePage)
          .map((tab) => MapEntry(tab.key, tab.page as RemotePage))
          .toList();
      if (remoteTabs.isEmpty) {
        await windowManager.setPreventClose(false);
        await windowManager.close();
        return false;
      }
      await windowManager.setPreventClose(true);
      await Future.wait(remoteTabs.map((entry) async {
        final tabKey = entry.key;
        final remotePage = entry.value;
        if (!tabController.state.value.tabs.any((tab) => tab.key == tabKey)) {
          return;
        }
        await remotePage.closeSessionForAppExit(
          onCloseSession: () {
            final index = tabController.state.value.tabs
                .indexWhere((tab) => tab.key == tabKey);
            if (index >= 0) {
              tabController.remove(index);
            }
          },
        );
      }));
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } finally {
      _mainWindowCloseFlowActive = false;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    registerDesktopRemoteTabOpener(DesktopTabPage.onAddRemoteTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setDefaultHomeTab();
    });
    // HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  /*
  bool _handleKeyEvent(KeyEvent event) {
    if (!mouseIn && event is KeyDownEvent) {
      print('key down: ${event.logicalKey}');
      shouldBeBlocked(_block, canBeBlocked);
    }
    return false; // allow it to propagate
  }
  */

  @override
  void dispose() {
    // HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    registerDesktopRemoteTabOpener(null);
    Get.delete<DesktopTabController>();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabWidget = Container(
        child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.surface,
            body: DesktopTab(
              controller: tabController,
              onWindowCloseButton: _handleMainWindowCloseButton,
              tail: Offstage(
                offstage: bind.isIncomingOnly(),
                child: ActionIcon(
                  message: 'Settings',
                  icon: IconFont.menu,
                  onTap: DesktopTabPage.onAddSetting,
                  isClose: false,
                ),
              ),
            )));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : Obx(
            () => DragToResizeArea(
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: windowManagerEnableResizeEdges,
              child: tabWidget,
            ),
          );
  }
}
