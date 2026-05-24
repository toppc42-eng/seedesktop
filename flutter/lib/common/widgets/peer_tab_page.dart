import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/address_book.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/common/widgets/my_group.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_tab_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/pages/cloud_contacts_page.dart';
import 'package:flutter_hbb/desktop/pages/favorites_page.dart';
import 'package:flutter_hbb/desktop/pages/health_monitor_page.dart';
import 'package:flutter_hbb/desktop/pages/my_devices_page.dart';
import 'package:flutter_hbb/desktop/pages/script_manager_page.dart';
import 'package:flutter_hbb/desktop/pages/local_maintenance_page.dart';
import 'package:flutter_hbb/desktop/pages/secure_transfer_page.dart';
import 'package:flutter_hbb/desktop/pages/saved_connections_page.dart';
import 'package:flutter_hbb/desktop/pages/updates_page.dart';
import 'package:flutter_hbb/utils/favorite_groups.dart';
import 'package:flutter_hbb/desktop/widgets/popup_menu.dart';
import 'package:flutter_hbb/desktop/widgets/material_mod_popup_menu.dart'
    as mod_menu;
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';
import 'package:flutter_hbb/common/widgets/premium_paywall_dialog.dart';
import 'package:flutter_hbb/common/widgets/rmm_admin_gate_dialog.dart';
import 'package:flutter_hbb/common/widgets/rmm_pro_gate_dialog.dart';
import 'package:flutter_hbb/utils/rmm_admin_session.dart';

import 'package:flutter_hbb/models/peer_tab_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:pull_down_button/pull_down_button.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

class PeerTabPage extends StatefulWidget {
  const PeerTabPage({Key? key}) : super(key: key);
  @override
  State<PeerTabPage> createState() => _PeerTabPageState();
}

class _TabEntry {
  final Widget widget;
  final Function({dynamic hint})? load;
  _TabEntry(this.widget, [this.load]);
}

enum _HomePanelType { peers, addressBook, savedConnections, settings, updates }

EdgeInsets? _menuPadding() {
  return (isDesktop || isWebDesktop) ? kDesktopMenuPadding : null;
}

class _PeerTabPageState extends State<PeerTabPage>
    with SingleTickerProviderStateMixin {
  static const double _topNavIconSize = 20;
  static const double _topNavButtonSize = 30;
  static const BorderRadius _topNavRadius =
      BorderRadius.all(Radius.circular(7));

  _HomePanelType _homePanelType = _HomePanelType.peers;
  final List<_TabEntry> entries = [
    _TabEntry(RecentPeersView(
      menuPadding: _menuPadding(),
    )),
    _TabEntry(FavoritePeersView(
      menuPadding: _menuPadding(),
    )),
    _TabEntry(const CloudContactsPage()),
    _TabEntry(DiscoveredPeersView(
      menuPadding: _menuPadding(),
    )),
    _TabEntry(const HealthMonitorPage()),
    _TabEntry(
        AddressBook(
          menuPadding: _menuPadding(),
        ),
        ({dynamic hint}) => gFFI.abModel.pullAb(
            force: hint == null ? ForcePullAb.listAndCurrent : null,
            quiet: false)),
    _TabEntry(
      MyGroup(
        menuPadding: _menuPadding(),
      ),
      ({dynamic hint}) => gFFI.groupModel.pull(force: hint == null),
    ),
    _TabEntry(const MyDevicesPage()),
    _TabEntry(const ScriptManagerPage()),
    _TabEntry(const LocalMaintenancePage()),
    _TabEntry(const SecureTransferPage()),
  ];
  RelativeRect? mobileTabContextMenuPos;

  final isOptVisiableFixed = isOptionFixed(kOptionPeerTabVisible);

  _PeerTabPageState() {
    _loadLocalOptions();
  }

  @override
  void initState() {
    super.initState();
    rmmScriptsUiVisibleNotifier.addListener(_onRmmScriptsUiPrefChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _ensureCurrentTabNotRestricted());
  }

  @override
  void dispose() {
    rmmScriptsUiVisibleNotifier.removeListener(_onRmmScriptsUiPrefChanged);
    super.dispose();
  }

  void _onRmmScriptsUiPrefChanged() {
    _ensureCurrentTabNotRestricted();
    if (mounted) setState(() {});
  }

  void _ensureCurrentTabNotRestricted() {
    final m = gFFI.peerTabModel;
    if (_rmmSessionAllowsTabIndex(m.currentTab)) return;
    m.setCurrentTab(PeerTabIndex.recent.index);
    m.setCurrentTabCachedPeers([]);
  }

  /// When admin turned off RMM/scripts UI, My Devices / Script Manager are hidden for everyone.
  bool _rmmSessionAllowsTabIndex(int tabIndex) {
    if (tabIndex != PeerTabIndex.myDevices.index &&
        tabIndex != PeerTabIndex.scriptManager.index) {
      return true;
    }
    return rmmScriptsUiVisibleNotifier.value;
  }

  List<int> _filteredTopNavTabs(PeerTabModel model) {
    return model.visibleEnabledOrderedIndexs
        .where((t) => _rmmSessionAllowsTabIndex(t))
        .toList();
  }

  void _onTopNavReorder(PeerTabModel model, int oldFiltered, int newFiltered) {
    final filtered = _filteredTopNavTabs(model);
    if (oldFiltered < 0 ||
        newFiltered < 0 ||
        oldFiltered >= filtered.length ||
        newFiltered >= filtered.length) {
      return;
    }
    final full = model.visibleEnabledOrderedIndexs;
    final oldTab = filtered[oldFiltered];
    final newTab = filtered[newFiltered];
    final oldFull = full.indexOf(oldTab);
    final newFull = full.indexOf(newTab);
    if (oldFull < 0 || newFull < 0) return;
    model.reorder(oldFull, newFull);
  }

  void _loadLocalOptions() {
    final uiType = bind.getLocalFlutterOption(k: kOptionPeerCardUiType);
    if (uiType != '') {
      peerCardUiType.value = int.parse(uiType) == 0
          ? PeerUiType.grid
          : int.parse(uiType) == 1
              ? PeerUiType.tile
              : PeerUiType.list;
    }
    hideAbTagsPanel.value =
        bind.mainGetLocalOption(key: kOptionHideAbTagsPanel) == 'Y';
  }

  Future<void> handleTabSelection(int tabIndex) async {
    final isPremiumFavoritesTab = tabIndex == PeerTabIndex.fav.index;
    final isPremiumCloudContactsTab =
        tabIndex == PeerTabIndex.cloudContacts.index;
    if ((isPremiumFavoritesTab || isPremiumCloudContactsTab) &&
        !await hasProLicenseLocal()) {
      await showPremiumPaywallDialog(context);
      return;
    }
    final isRmmTab = tabIndex == PeerTabIndex.myDevices.index ||
        tabIndex == PeerTabIndex.scriptManager.index ||
        tabIndex == PeerTabIndex.localMaintenance.index ||
        tabIndex == PeerTabIndex.health.index;
    if (isRmmTab) {
      if (!rmmScriptsUiVisibleNotifier.value) {
        if (mounted) await showRmmAdminSessionGateDialog(context);
        return;
      }
      if (!await hasRmmLicenseLocal()) {
        if (mounted) await showRmmProGateDialog(context);
        return;
      }
    }
    if (tabIndex < entries.length) {
      if (tabIndex != gFFI.peerTabModel.currentTab) {
        gFFI.peerTabModel.setCurrentTabCachedPeers([]);
      }
      if (_homePanelType != _HomePanelType.peers) {
        setState(() {
          _homePanelType = _HomePanelType.peers;
        });
      }
      gFFI.peerTabModel.setCurrentTab(tabIndex);
      entries[tabIndex].load?.call(hint: false);
      _syncBottomBannerVisibility();
    }
  }

  void _syncBottomBannerVisibility() {
    final model = gFFI.peerTabModel;
    final hideByHomePanel = _homePanelType == _HomePanelType.addressBook;
    final hideByPeerTab = _homePanelType == _HomePanelType.peers &&
        (model.currentTab == PeerTabIndex.ab.index ||
            model.currentTab == PeerTabIndex.fav.index ||
            model.currentTab == PeerTabIndex.cloudContacts.index);
    stateGlobal.hideBottomNotificationBanner.value =
        hideByHomePanel || hideByPeerTab;
  }

  @override
  Widget build(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    _syncBottomBannerVisibility();
    Widget selectionWrap(Widget widget) {
      return model.multiSelectionMode ? createMultiSelectionBar(model) : widget;
    }

    return Column(
      textBaseline: TextBaseline.ideographic,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Obx(() => SizedBox(
              height: 32,
              child: Container(
                padding: stateGlobal.isPortrait.isTrue
                    ? EdgeInsets.symmetric(horizontal: 2)
                    : null,
                child: selectionWrap(Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    visibleContextMenuListener(_createSwitchBar(context)),
                    const SizedBox(width: 8),
                    if (!stateGlobal.isPortrait.isTrue &&
                        _homePanelType == _HomePanelType.peers)
                      const PeerSearchBar().marginOnly(right: 8),
                    const Spacer(),
                    if (stateGlobal.isPortrait.isTrue)
                      ..._portraitRightActions(context)
                    else
                      ..._landscapeRightActions(context)
                  ],
                )),
              ),
            ).paddingOnly(right: stateGlobal.isPortrait.isTrue ? 0 : 12)),
        Expanded(
          child: _createPeersView(),
        ),
      ],
    );
  }

  Widget _createSwitchBar(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    final topNavTabs = _filteredTopNavTabs(model);
    var counter = -1;
    final itemWidth = stateGlobal.isPortrait.isTrue ? 36.0 : 40.0;
    final listWidth = (topNavTabs.length * itemWidth).clamp(40.0, 300.0);
    final activeColor = _topNavActiveColor(context);
    final inactiveColor = _topNavInactiveColor(context);
    return SizedBox(
      width: listWidth,
      child: ReorderableListView(
        buildDefaultDragHandles: false,
        onReorder: (oldIndex, newIndex) {
          var ni = newIndex;
          if (ni > oldIndex) ni -= 1;
          _onTopNavReorder(model, oldIndex, ni);
        },
        scrollDirection: Axis.horizontal,
        physics: NeverScrollableScrollPhysics(),
        children: topNavTabs.map((t) {
          final selected = model.currentTab == t;
          final color = selected ? activeColor : inactiveColor;
          counter += 1;
          return ReorderableDragStartListener(
              key: ValueKey(t),
              index: counter,
              child: Tooltip(
                preferBelow: false,
                message: model.tabTooltip(t),
                onTriggered: isMobile ? mobileShowTabVisibilityMenu : null,
                child: _TopNavIconButton(
                  icon: model.tabIcon(t),
                  selected: selected,
                  iconColor: color,
                  activeColor: activeColor,
                  onTap: isOptionFixed(kOptionPeerTabIndex)
                      ? null
                      : () async {
                          await handleTabSelection(t);
                          await bind.setLocalFlutterOption(
                              k: kOptionPeerTabIndex, v: t.toString());
                        },
                ),
              ));
        }).toList(),
      ),
    );
  }

  Future<List<MapEntry<String, String>>> _loadLanguages() async {
    final langs = await bind.mainGetLangs();
    final langsList = jsonDecode(langs) as List<dynamic>;
    final map = <String, String>{for (final v in langsList) v[0]: v[1]};
    return <MapEntry<String, String>>[
      MapEntry(defaultOptionLang, translate('Default')),
      ...map.entries,
    ];
  }

  String _flagForLang(String key) {
    switch (key.toLowerCase()) {
      case 'en':
        return '🇺🇸';
      case 'he':
        return '🇮🇱';
      case 'de':
        return '🇩🇪';
      case 'fr':
        return '🇫🇷';
      case 'es':
        return '🇪🇸';
      case 'it':
        return '🇮🇹';
      case 'pt':
      case 'pt_pt':
        return '🇵🇹';
      case 'ptbr':
        return '🇧🇷';
      case 'ru':
        return '🇷🇺';
      case 'uk':
        return '🇺🇦';
      case 'tr':
        return '🇹🇷';
      case 'ja':
        return '🇯🇵';
      case 'ko':
        return '🇰🇷';
      case 'th':
        return '🇹🇭';
      case 'vi':
        return '🇻🇳';
      case 'ar':
        return '🇸🇦';
      case 'fa':
        return '🇮🇷';
      case 'id':
        return '🇮🇩';
      case 'cn':
        return '🇨🇳';
      case 'tw':
        return '🇹🇼';
      default:
        return '🌐';
    }
  }

  Widget _buildTopLanguageSelector() {
    var currentKey = bind.mainGetLocalOption(key: kCommConfKeyLang);
    if (currentKey.isEmpty) currentKey = defaultOptionLang;
    return FutureBuilder<List<MapEntry<String, String>>>(
      future: _loadLanguages(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox(width: 22);
        final items = snapshot.data!;
        final selected = items.firstWhere(
          (e) => e.key == currentKey,
          orElse: () => MapEntry(defaultOptionLang, 'Default'),
        );
        final activeColor = _topNavActiveColor(context);
        final inactiveColor = _topNavInactiveColor(context);
        return Tooltip(
          message: translate('Language'),
          child: PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            onSelected: (key) async {
              await bind.mainSetLocalOption(key: kCommConfKeyLang, value: key);
              if (isWeb) reloadCurrentWindow();
              if (!isWeb) {
                reloadAllWindows();
                bind.mainChangeLanguage(lang: key);
              }
              setState(() {});
            },
            child: _TopNavIconButton(
              icon: Icons.language_outlined,
              selected: false,
              iconColor: inactiveColor,
              activeColor: activeColor,
            ),
            itemBuilder: (context) => items
                .map(
                  (e) => PopupMenuItem<String>(
                    value: e.key,
                    child: Row(
                      children: [
                        Text(_flagForLang(e.key)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(e.value)),
                        if (e.key == selected.key)
                          Icon(Icons.check, size: 16, color: activeColor),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }

  Color _topNavActiveColor(BuildContext context) {
    return MyTheme.tabbar(context).selectedTextColor ??
        Theme.of(context).colorScheme.primary;
  }

  Color _topNavInactiveColor(BuildContext context) {
    final c = MyTheme.tabbar(context).unSelectedTextColor;
    if (c != null) return c;
    return Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black87;
  }

  Widget _createPeersView() {
    Widget wrapPanel(Widget child) {
      return child.marginSymmetric(
        vertical: (isDesktop || isWebDesktop) ? 12.0 : 6.0,
      );
    }

    if (_homePanelType == _HomePanelType.addressBook) {
      return wrapPanel(const FavoritesPage());
    }
    if (_homePanelType == _HomePanelType.savedConnections) {
      return wrapPanel(const SavedConnectionsPage());
    }
    if (_homePanelType == _HomePanelType.settings) {
      return wrapPanel(DesktopSettingPage(
        initialTabkey: SettingsTabKey.general,
      ));
    }
    if (_homePanelType == _HomePanelType.updates) {
      return wrapPanel(const UpdatesPage());
    }
    final model = Provider.of<PeerTabModel>(context);
    Widget child;
    if (model.visibleEnabledOrderedIndexs.isEmpty) {
      child = visibleContextMenuListener(Row(
        children: [Expanded(child: InkWell())],
      ));
    } else {
      if (model.visibleEnabledOrderedIndexs.contains(model.currentTab) &&
          _rmmSessionAllowsTabIndex(model.currentTab)) {
        if (model.currentTab == PeerTabIndex.fav.index) {
          child = const FavoritesPage();
        } else {
          child = entries[model.currentTab].widget;
        }
      } else {
        debugPrint("should not happen! currentTab not in visibleIndexs");
        Future.delayed(Duration.zero, () {
          model.setCurrentTab(model.visibleEnabledOrderedIndexs[0]);
        });
        child = entries[0].widget;
      }
    }
    return wrapPanel(child);
  }

  Widget _panelIcon({
    required _HomePanelType panel,
    required IconData icon,
    required String tooltip,
  }) {
    final selected = _homePanelType == panel;
    final color = selected ? MyTheme.accent : Theme.of(context).iconTheme.color;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () {
          if (panel == _HomePanelType.settings) {
            DesktopTabPage.onAddSetting(initialPage: SettingsTabKey.general);
            return;
          }
          if (_homePanelType != panel) {
            setState(() {
              _homePanelType = panel;
            });
            _syncBottomBannerVisibility();
          }
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.all(4),
          decoration: selected
              ? BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                )
              : null,
          child: panel == _HomePanelType.updates
              ? Obx(() => Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(icon, size: 18, color: color),
                      if (stateGlobal.hasOtaUpdate.value)
                        const Positioned(
                          right: -2,
                          top: -2,
                          child: _UpdateBadgeDot(),
                        ),
                    ],
                  ))
              : Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }

  List<Widget> _homePanelActions() {
    return [
      _buildTopLanguageSelector(),
      const SizedBox(width: 8),
      _panelIcon(
        panel: _HomePanelType.updates,
        icon: Icons.system_update_alt_rounded,
        tooltip: translate('Updates'),
      ),
    ];
  }

  Widget _createRefresh(
      {required PeerTabIndex index, required RxBool loading}) {
    final model = Provider.of<PeerTabModel>(context);
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    return Offstage(
      offstage: model.currentTab != index.index,
      child: Tooltip(
        message: translate('Refresh'),
        child: RefreshWidget(
            onPressed: () {
              if (gFFI.peerTabModel.currentTab < entries.length) {
                entries[gFFI.peerTabModel.currentTab].load?.call();
              }
            },
            spinning: loading,
            child: RotatedBox(
                quarterTurns: 2,
                child: Icon(
                  Icons.refresh,
                  size: 18,
                  color: textColor,
                ))),
      ),
    );
  }

  Widget _createPeerViewTypeSwitch(BuildContext context) {
    return PeerViewDropdown();
  }

  Widget _createMultiSelection() {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    final model = Provider.of<PeerTabModel>(context);
    return _hoverAction(
      toolTip: translate('Select'),
      context: context,
      onTap: () {
        model.setMultiSelectionMode(true);
        if (isMobile && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      },
      child: SvgPicture.asset(
        "assets/checkbox-outline.svg",
        width: 18,
        height: 18,
        colorFilter: svgColor(textColor),
      ),
    );
  }

  void mobileShowTabVisibilityMenu() {
    final model = gFFI.peerTabModel;
    final items = List<PopupMenuItem>.empty(growable: true);
    for (int i = 0; i < PeerTabModel.maxTabCount; i++) {
      if (!model.isEnabled[i]) continue;
      if (!_rmmSessionAllowsTabIndex(i)) continue;
      items.add(PopupMenuItem(
        height: kMinInteractiveDimension * 0.8,
        onTap: isOptVisiableFixed
            ? null
            : () => model.setTabVisible(i, !model.isVisibleEnabled[i]),
        enabled: !isOptVisiableFixed,
        child: Row(
          children: [
            Checkbox(
                value: model.isVisibleEnabled[i],
                onChanged: isOptVisiableFixed
                    ? null
                    : (_) {
                        model.setTabVisible(i, !model.isVisibleEnabled[i]);
                        if (Navigator.canPop(context)) {
                          Navigator.pop(context);
                        }
                      }),
            Expanded(child: Text(model.tabTooltip(i))),
          ],
        ),
      ));
    }
    if (mobileTabContextMenuPos != null) {
      showMenu(
          context: context, position: mobileTabContextMenuPos!, items: items);
    }
  }

  Widget visibleContextMenuListener(Widget child) {
    if (!(isDesktop || isWebDesktop)) {
      return GestureDetector(
        onLongPressDown: (e) {
          final x = e.globalPosition.dx;
          final y = e.globalPosition.dy;
          mobileTabContextMenuPos = RelativeRect.fromLTRB(x, y, x, y);
        },
        onLongPressUp: () {
          mobileShowTabVisibilityMenu();
        },
        child: child,
      );
    } else {
      return Listener(
          onPointerDown: (e) {
            if (e.kind != ui.PointerDeviceKind.mouse) {
              return;
            }
            if (e.buttons == 2) {
              showRightMenu(
                (CancelFunc cancelFunc) {
                  return visibleContextMenu(cancelFunc);
                },
                target: e.position,
              );
            }
          },
          child: child);
    }
  }

  Widget visibleContextMenu(CancelFunc cancelFunc) {
    final model = Provider.of<PeerTabModel>(context);
    final menu = List<MenuEntrySwitchSync>.empty(growable: true);
    for (int i = 0; i < model.orders.length; i++) {
      int tabIndex = model.orders[i];
      if (tabIndex < 0 || tabIndex >= PeerTabModel.maxTabCount) continue;
      if (!model.isEnabled[tabIndex]) continue;
      if (!_rmmSessionAllowsTabIndex(tabIndex)) continue;
      menu.add(MenuEntrySwitchSync(
          switchType: SwitchType.scheckbox,
          text: model.tabTooltip(tabIndex),
          currentValue: model.isVisibleEnabled[tabIndex],
          setter: (show) async {
            model.setTabVisible(tabIndex, show);
            // Do not hide the current menu (checkbox)
            // cancelFunc();
          },
          enabled: (!isOptVisiableFixed).obs));
    }
    return mod_menu.PopupMenu(
        items: menu
            .map((entry) => entry.build(
                context,
                const MenuConfig(
                  commonColor: MyTheme.accent,
                  height: 20.0,
                  dividerHeight: 12.0,
                )))
            .expand((i) => i)
            .toList());
  }

  Widget createMultiSelectionBar(PeerTabModel model) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Offstage(
          offstage: model.selectedPeers.isEmpty,
          child: Row(
            children: [
              deleteSelection(),
              addSelectionToFav(),
              addSelectionToAb(),
              editSelectionTags(),
            ],
          ),
        ),
        Row(
          children: [
            selectionCount(model.selectedPeers.length),
            selectAll(model),
            closeSelection(),
          ],
        )
      ],
    );
  }

  Widget deleteSelection() {
    final model = Provider.of<PeerTabModel>(context);
    if (model.currentTab == PeerTabIndex.group.index) {
      return Offstage();
    }
    return _hoverAction(
        context: context,
        toolTip: translate('Delete'),
        onTap: () {
          onSubmit() async {
            final peers = model.selectedPeers;
            final tab = model.currentTab;
            if (tab == PeerTabIndex.recent.index) {
              for (var p in peers) {
                await bind.mainRemovePeer(id: p.id);
              }
              bind.mainLoadRecentPeers();
            } else if (tab == PeerTabIndex.fav.index) {
              final favs = (await bind.mainGetFav()).toList();
              for (var p in peers) {
                favs.remove(p.id);
              }
              await bind.mainStoreFav(favs: favs);
              bind.mainLoadFavPeers();
            } else if (tab == PeerTabIndex.lan.index) {
              for (var p in peers) {
                await bind.mainRemoveDiscovered(id: p.id);
              }
              bind.mainLoadLanPeers();
            } else if (tab == PeerTabIndex.ab.index) {
              await gFFI.abModel.deletePeers(peers.map((p) => p.id).toList());
            }
            gFFI.peerTabModel.setMultiSelectionMode(false);
            if (tab != PeerTabIndex.ab.index) {
              showToast(translate('Successful'));
            }
          }

          deleteConfirmDialog(onSubmit, translate('Delete'));
        },
        child: Icon(Icons.delete, color: Colors.red));
  }

  Widget addSelectionToFav() {
    final model = Provider.of<PeerTabModel>(context);
    return Offstage(
      offstage:
          model.currentTab != PeerTabIndex.recent.index, // show based on recent
      child: _hoverAction(
        context: context,
        toolTip: translate('Add to Favorites'),
        onTap: () async {
          if (!await hasProLicenseLocal()) {
            await showPremiumPaywallDialog(context);
            return;
          }
          final peers = model.selectedPeers;
          final favs = (await bind.mainGetFav()).toList();
          for (var p in peers) {
            if (!favs.contains(p.id)) {
              favs.add(p.id);
            }
          }
          await bind.mainStoreFav(favs: favs);
          await bind.mainLoadFavPeers();
          model.setMultiSelectionMode(false);
          showToast(translate('Successful'));
        },
        child: Icon(PeerTabModel.icons[PeerTabIndex.fav.index]),
      ).marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget addSelectionToAb() {
    final model = Provider.of<PeerTabModel>(context);
    final addressbooks = gFFI.abModel.addressBooksCanWrite();
    if (model.currentTab == PeerTabIndex.ab.index) {
      addressbooks.remove(gFFI.abModel.currentName.value);
    }
    return Offstage(
      offstage: !gFFI.userModel.isLogin || addressbooks.isEmpty,
      child: _hoverAction(
        context: context,
        toolTip: translate('Add to address book'),
        onTap: () async {
          if (!await hasProLicenseLocal()) {
            await showPremiumPaywallDialog(context);
            return;
          }
          final peers = model.selectedPeers.map((e) => Peer.copy(e)).toList();
          addPeersToAbDialog(peers);
          model.setMultiSelectionMode(false);
        },
        child: Icon(PeerTabModel.icons[PeerTabIndex.ab.index]),
      ).marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget editSelectionTags() {
    final model = Provider.of<PeerTabModel>(context);
    return Offstage(
      offstage: !gFFI.userModel.isLogin ||
          model.currentTab != PeerTabIndex.ab.index ||
          gFFI.abModel.currentAbTags.isEmpty,
      child: _hoverAction(
              context: context,
              toolTip: translate('Edit Tag'),
              onTap: () {
                editAbTagDialog(List.empty(), (selectedTags) async {
                  final peers = model.selectedPeers;
                  await gFFI.abModel.changeTagForPeers(
                      peers.map((p) => p.id).toList(), selectedTags);
                  model.setMultiSelectionMode(false);
                  showToast(translate('Successful'));
                });
              },
              child: Icon(Icons.tag))
          .marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget selectionCount(int count) {
    return Align(
      alignment: Alignment.center,
      child: Text('$count ${translate('Selected')}'),
    );
  }

  Widget selectAll(PeerTabModel model) {
    return Offstage(
      offstage:
          model.selectedPeers.length >= model.currentTabCachedPeers.length,
      child: _hoverAction(
        context: context,
        toolTip: translate('Select All'),
        onTap: () {
          model.selectAll();
        },
        child: Icon(Icons.select_all),
      ).marginOnly(left: 6),
    );
  }

  Widget closeSelection() {
    final model = Provider.of<PeerTabModel>(context);
    return _hoverAction(
            context: context,
            toolTip: translate('Close'),
            onTap: () {
              model.setMultiSelectionMode(false);
            },
            child: Icon(Icons.clear))
        .marginOnly(left: 6);
  }

  Widget _toggleTags() {
    return _hoverAction(
        context: context,
        toolTip: translate('Toggle Tags'),
        hoverableWhenfalse: hideAbTagsPanel,
        child: Icon(
          Icons.tag_rounded,
          size: 18,
        ),
        onTap: () async {
          await bind.mainSetLocalOption(
              key: kOptionHideAbTagsPanel,
              value: hideAbTagsPanel.value ? defaultOptionNo : "Y");
          hideAbTagsPanel.value = !hideAbTagsPanel.value;
        });
  }

  List<Widget> _landscapeRightActions(BuildContext context) {
    if (_homePanelType != _HomePanelType.peers) {
      return _homePanelActions();
    }
    final model = Provider.of<PeerTabModel>(context);
    return [
      ..._homePanelActions(),
      _createRefresh(
          index: PeerTabIndex.ab, loading: gFFI.abModel.currentAbLoading),
      _createRefresh(
          index: PeerTabIndex.group, loading: gFFI.groupModel.groupLoading),
      Offstage(
        offstage: model.currentTabCachedPeers.isEmpty,
        child: _createMultiSelection(),
      ),
      _createPeerViewTypeSwitch(context),
      Offstage(
        offstage: model.currentTab == PeerTabIndex.recent.index,
        child: PeerSortDropdown(),
      ),
      Offstage(
        offstage: model.currentTab != PeerTabIndex.ab.index,
        child: _toggleTags(),
      ),
    ];
  }

  List<Widget> _portraitRightActions(BuildContext context) {
    if (_homePanelType != _HomePanelType.peers) {
      return _homePanelActions();
    }
    final model = Provider.of<PeerTabModel>(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final leftIconSize = Theme.of(context).iconTheme.size ?? 24;
    final leftActionsSize =
        (leftIconSize + (4 + 4) * 2) * _filteredTopNavTabs(model).length;
    final availableWidth = screenWidth - 10 * 2 - leftActionsSize - 2 * 2;
    final searchWidth = 120;
    final otherActionWidth = 18 + 10;

    dropDown(List<Widget> menus) {
      final padding = 6.0;
      final textColor = Theme.of(context).textTheme.titleLarge?.color;
      return PullDownButton(
        buttonBuilder:
            (BuildContext context, Future<void> Function() showMenu) {
          return _hoverAction(
            context: context,
            toolTip: translate('More'),
            child: SvgPicture.asset(
              "assets/chevron_up_chevron_down.svg",
              width: 18,
              height: 18,
              colorFilter: svgColor(textColor),
            ),
            onTap: showMenu,
          );
        },
        routeTheme: PullDownMenuRouteTheme(
            width: menus.length * (otherActionWidth + padding * 2) * 1.0),
        itemBuilder: (context) => [
          PullDownMenuEntryImpl(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: menus
                  .map((e) =>
                      Material(child: e.paddingSymmetric(horizontal: padding)))
                  .toList(),
            ),
          )
        ],
      );
    }

    // Always show search, refresh
    List<Widget> actions = [
      const PeerSearchBar(),
      if (model.currentTab == PeerTabIndex.ab.index)
        _createRefresh(
            index: PeerTabIndex.ab, loading: gFFI.abModel.currentAbLoading),
      if (model.currentTab == PeerTabIndex.group.index)
        _createRefresh(
            index: PeerTabIndex.group, loading: gFFI.groupModel.groupLoading),
    ];
    final List<Widget> dynamicActions = [
      if (model.currentTabCachedPeers.isNotEmpty) _createMultiSelection(),
      if (model.currentTab != PeerTabIndex.recent.index) PeerSortDropdown(),
      if (model.currentTab == PeerTabIndex.ab.index) _toggleTags()
    ];
    final rightWidth = availableWidth -
        searchWidth -
        (actions.length == 2 ? otherActionWidth : 0);
    final availablePositions = rightWidth ~/ otherActionWidth;

    if (availablePositions < dynamicActions.length &&
        dynamicActions.length > 1) {
      if (availablePositions < 2) {
        actions.addAll([
          dropDown(dynamicActions),
        ]);
      } else {
        actions.addAll([
          ...dynamicActions.sublist(0, availablePositions - 1),
          dropDown(dynamicActions.sublist(availablePositions - 1)),
        ]);
      }
    } else {
      actions.addAll(dynamicActions);
    }
    return actions;
  }
}

class _UpdateBadgeDot extends StatelessWidget {
  const _UpdateBadgeDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(
        color: Colors.red,
        shape: BoxShape.circle,
      ),
    );
  }
}

class PeerSearchBar extends StatefulWidget {
  const PeerSearchBar({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _PeerSearchBarState();
}

class _PeerSearchBarState extends State<PeerSearchBar> {
  var drawer = false;

  @override
  Widget build(BuildContext context) {
    return drawer
        ? _buildSearchBar()
        : _hoverAction(
            context: context,
            toolTip: translate('Search'),
            padding: const EdgeInsets.only(right: 2),
            onTap: () {
              setState(() {
                drawer = true;
              });
            },
            child: Icon(
              Icons.search_rounded,
              color: Theme.of(context).hintColor,
            ));
  }

  Widget _buildSearchBar() {
    RxBool focused = false.obs;
    FocusNode focusNode = FocusNode();
    focusNode.addListener(() {
      focused.value = focusNode.hasFocus;
      peerSearchTextController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: peerSearchTextController.value.text.length);
    });
    return Obx(() => Container(
          width: stateGlobal.isPortrait.isTrue ? 120 : 140,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: Theme.of(context).dividerColor.withOpacity(0.7)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      color: Theme.of(context).hintColor,
                    ).marginSymmetric(horizontal: 4),
                    Expanded(
                      child: TextField(
                        autofocus: true,
                        controller: peerSearchTextController,
                        onChanged: (searchText) {
                          peerSearchText.value = searchText;
                        },
                        focusNode: focusNode,
                        textAlign: TextAlign.start,
                        maxLines: 1,
                        cursorColor: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.color
                            ?.withOpacity(0.5),
                        cursorHeight: 18,
                        cursorWidth: 1,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 6),
                          hintText:
                              focused.value ? null : translate("Search ID"),
                          hintStyle: TextStyle(
                              fontSize: 14, color: Theme.of(context).hintColor),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ).workaroundFreezeLinuxMint(),
                    ),
                    // Icon(Icons.close),
                    IconButton(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 2),
                      onPressed: () {
                        setState(() {
                          peerSearchTextController.clear();
                          peerSearchText.value = "";
                          drawer = false;
                        });
                      },
                      icon: Tooltip(
                          message: translate('Close'),
                          child: Icon(
                            Icons.close,
                            color: Theme.of(context).hintColor,
                          )),
                    ),
                  ],
                ),
              )
            ],
          ),
        ));
  }
}

class PeerViewDropdown extends StatefulWidget {
  const PeerViewDropdown({super.key});

  @override
  State<PeerViewDropdown> createState() => _PeerViewDropdownState();
}

class _PeerViewDropdownState extends State<PeerViewDropdown> {
  @override
  Widget build(BuildContext context) {
    final List<PeerUiType> types = [
      PeerUiType.grid,
      PeerUiType.tile,
      PeerUiType.list
    ];
    final style = TextStyle(
        color: Theme.of(context).textTheme.titleLarge?.color,
        fontSize: MenuConfig.fontSize,
        fontWeight: FontWeight.normal);
    List<PopupMenuEntry> items = List.empty(growable: true);
    items.add(PopupMenuItem(
        height: 36,
        enabled: false,
        child: Text(translate("Change view"), style: style)));
    for (var e in PeerUiType.values) {
      items.add(PopupMenuItem(
          height: 36,
          child: Obx(() => Center(
                child: SizedBox(
                  height: 36,
                  child: getRadio<PeerUiType>(
                      Tooltip(
                          message: translate(types.indexOf(e) == 0
                              ? 'Big tiles'
                              : types.indexOf(e) == 1
                                  ? 'Small tiles'
                                  : 'List'),
                          child: Icon(
                            e == PeerUiType.grid
                                ? Icons.grid_view_rounded
                                : e == PeerUiType.list
                                    ? Icons.view_list_rounded
                                    : Icons.view_agenda_rounded,
                            size: 18,
                          )),
                      e,
                      peerCardUiType.value,
                      dense: true,
                      isOptionFixed(kOptionPeerCardUiType)
                          ? null
                          : (PeerUiType? v) async {
                              if (v != null) {
                                peerCardUiType.value = v;
                                setState(() {});
                                await bind.setLocalFlutterOption(
                                  k: kOptionPeerCardUiType,
                                  v: peerCardUiType.value.index.toString(),
                                );
                                if (Navigator.canPop(context)) {
                                  Navigator.pop(context);
                                }
                              }
                            }),
                ),
              ))));
    }

    var menuPos = RelativeRect.fromLTRB(0, 0, 0, 0);
    return _hoverAction(
        context: context,
        toolTip: translate('Change view'),
        child: Icon(
          peerCardUiType.value == PeerUiType.grid
              ? Icons.grid_view_rounded
              : peerCardUiType.value == PeerUiType.list
                  ? Icons.view_list_rounded
                  : Icons.view_agenda_rounded,
          size: 18,
        ),
        onTapDown: (details) {
          final x = details.globalPosition.dx;
          final y = details.globalPosition.dy;
          menuPos = RelativeRect.fromLTRB(x, y, x, y);
        },
        onTap: () => showMenu(
              context: context,
              position: menuPos,
              items: items,
              elevation: 8,
            ));
  }
}

class PeerSortDropdown extends StatefulWidget {
  const PeerSortDropdown({super.key});

  @override
  State<PeerSortDropdown> createState() => _PeerSortDropdownState();
}

class _PeerSortDropdownState extends State<PeerSortDropdown> {
  _PeerSortDropdownState() {
    if (!PeerSortType.values.contains(peerSort.value)) {
      _loadLocalOptions();
    }
  }

  void _loadLocalOptions() {
    peerSort.value = PeerSortType.remoteId;
    bind.setLocalFlutterOption(
      k: kOptionPeerSorting,
      v: peerSort.value,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        color: Theme.of(context).textTheme.titleLarge?.color,
        fontSize: MenuConfig.fontSize,
        fontWeight: FontWeight.normal);
    List<PopupMenuEntry> items = List.empty(growable: true);
    items.add(PopupMenuItem(
        height: 36,
        enabled: false,
        child: Text(translate("Sort by"), style: style)));
    for (var e in PeerSortType.values) {
      items.add(PopupMenuItem(
          height: 36,
          child: Obx(() => Center(
                child: SizedBox(
                  height: 36,
                  child: getRadio(
                      Text(translate(e), style: style), e, peerSort.value,
                      dense: true, (String? v) async {
                    if (v != null) {
                      peerSort.value = v;
                      await bind.setLocalFlutterOption(
                        k: kOptionPeerSorting,
                        v: peerSort.value,
                      );
                    }
                  }),
                ),
              ))));
    }

    var menuPos = RelativeRect.fromLTRB(0, 0, 0, 0);
    return _hoverAction(
      context: context,
      toolTip: translate('Sort by'),
      child: Icon(
        Icons.sort_rounded,
        size: 18,
      ),
      onTapDown: (details) {
        final x = details.globalPosition.dx;
        final y = details.globalPosition.dy;
        menuPos = RelativeRect.fromLTRB(x, y, x, y);
      },
      onTap: () => showMenu(
        context: context,
        position: menuPos,
        items: items,
        elevation: 8,
      ),
    );
  }
}

class _TopNavIconButton extends StatefulWidget {
  final IconData icon;
  final bool selected;
  final Color iconColor;
  final Color activeColor;
  final VoidCallback? onTap;

  const _TopNavIconButton({
    required this.icon,
    required this.selected,
    required this.iconColor,
    required this.activeColor,
    this.onTap,
  });

  @override
  State<_TopNavIconButton> createState() => _TopNavIconButtonState();
}

class _TopNavIconButtonState extends State<_TopNavIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hoverBg = isDark
        ? Colors.white.withOpacity(0.14)
        : Colors.black.withOpacity(0.07);
    final activeBg = widget.activeColor.withOpacity(isDark ? 0.24 : 0.14);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: _PeerTabPageState._topNavButtonSize,
          height: _PeerTabPageState._topNavButtonSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: _PeerTabPageState._topNavRadius,
            color: widget.selected
                ? activeBg
                : (_hover ? hoverBg : Colors.transparent),
            border: widget.selected
                ? Border(
                    bottom: BorderSide(
                      width: 2,
                      color: widget.activeColor,
                    ),
                  )
                : null,
          ),
          child: Icon(
            widget.icon,
            size: _PeerTabPageState._topNavIconSize,
            color: widget.iconColor,
          ),
        ),
      ),
    );
  }
}

class RefreshWidget extends StatefulWidget {
  final VoidCallback onPressed;
  final Widget child;
  final RxBool? spinning;
  const RefreshWidget(
      {super.key, required this.onPressed, required this.child, this.spinning});

  @override
  State<RefreshWidget> createState() => RefreshWidgetState();
}

class RefreshWidgetState extends State<RefreshWidget> {
  double turns = 0.0;
  bool hover = false;

  @override
  void initState() {
    super.initState();
    widget.spinning?.listen((v) {
      if (v && mounted) {
        setState(() {
          turns += 1;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final deco = BoxDecoration(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
    );
    return AnimatedRotation(
        turns: turns,
        duration: const Duration(milliseconds: 200),
        onEnd: () {
          if (widget.spinning?.value == true && mounted) {
            setState(() => turns += 1.0);
          }
        },
        child: Container(
          padding: EdgeInsets.all(4.0),
          margin: EdgeInsets.symmetric(horizontal: 1),
          decoration: hover ? deco : null,
          child: InkWell(
              onTap: () {
                if (mounted) setState(() => turns += 1.0);
                widget.onPressed();
              },
              onHover: (value) {
                if (mounted) {
                  setState(() {
                    hover = value;
                  });
                }
              },
              child: widget.child),
        ));
  }
}

Widget _hoverAction(
    {required BuildContext context,
    required Widget child,
    required Function() onTap,
    required String toolTip,
    GestureTapDownCallback? onTapDown,
    RxBool? hoverableWhenfalse,
    EdgeInsetsGeometry padding = const EdgeInsets.all(4.0)}) {
  final hover = false.obs;
  final deco = BoxDecoration(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(6),
  );
  return Tooltip(
    message: toolTip,
    child: Obx(
      () => Container(
          margin: EdgeInsets.symmetric(horizontal: 1),
          decoration:
              (hover.value || hoverableWhenfalse?.value == false) ? deco : null,
          child: InkWell(
              onHover: (value) => hover.value = value,
              onTap: onTap,
              onTapDown: onTapDown,
              child: Container(padding: padding, child: child))),
    ),
  );
}

class PullDownMenuEntryImpl extends StatelessWidget
    implements PullDownMenuEntry {
  final Widget child;
  const PullDownMenuEntryImpl({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
