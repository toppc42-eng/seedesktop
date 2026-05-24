import 'dart:async';
import 'package:bot_toast/bot_toast.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/common/widgets/crm_widgets.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_tab_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import '../../desktop/widgets/popup_menu.dart';
import '../../common/widgets/cloud_contacts_dialog.dart';
import '../../desktop/pages/cloud_contacts_page.dart';
import '../../utils/cloud_contacts_service.dart';
import '../../utils/favorite_groups.dart';
import '../../utils/peer_display_name_sync.dart';
import '../../utils/freemium_guard.dart';
import 'premium_paywall_dialog.dart';
import 'dart:math' as math;

typedef PopupMenuEntryBuilder = Future<List<mod_menu.PopupMenuEntry<String>>>
    Function(BuildContext);

enum PeerUiType { grid, tile, list }

final peerCardUiType = PeerUiType.grid.obs;

bool? hideUsernameOnCard;

class _PeerCard extends StatefulWidget {
  final Peer peer;
  final PeerTabIndex tab;
  final Function(BuildContext, String) connect;
  final PopupMenuEntryBuilder popupMenuEntryBuilder;
  final String? subtitleOverride;
  final String? cloudGroupsLabelOverride;

  const _PeerCard(
      {required this.peer,
      required this.tab,
      required this.connect,
      required this.popupMenuEntryBuilder,
      this.subtitleOverride,
      this.cloudGroupsLabelOverride,
      Key? key})
      : super(key: key);

  @override
  _PeerCardState createState() => _PeerCardState();
}

/// State for the connection page.
class _PeerCardState extends State<_PeerCard>
    with AutomaticKeepAliveClientMixin {
  var _menuPos = RelativeRect.fill;
  final double _cardRadius = 16;
  final double _tileRadius = 5;
  final double _borderWidth = 2;
  String _cloudGroupsLabel = '';

  String get _cardGroupsLabel {
    final override = widget.cloudGroupsLabelOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    return _cloudGroupsLabel;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadCloudGroupsLabel());
  }

  @override
  void didUpdateWidget(covariant _PeerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peer.id != widget.peer.id ||
        oldWidget.cloudGroupsLabelOverride !=
            widget.cloudGroupsLabelOverride) {
      unawaited(_loadCloudGroupsLabel());
    }
  }

  Future<void> _loadCloudGroupsLabel() async {
    final override = widget.cloudGroupsLabelOverride?.trim() ?? '';
    if (override.isNotEmpty) {
      if (!mounted || override == _cloudGroupsLabel) return;
      setState(() => _cloudGroupsLabel = override);
      return;
    }
    var next = CloudContactsService.groupsLabelFor(widget.peer.id);
    if (next.isEmpty &&
        CloudContactsService.resolveAuthToken() != null &&
        await canUseCloudContactsLocal()) {
      await CloudContactsService.warmGroupsCache();
      next = CloudContactsService.groupsLabelFor(widget.peer.id);
    }
    if (!mounted || next == _cloudGroupsLabel) return;
    setState(() => _cloudGroupsLabel = next);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Obx(() =>
        stateGlobal.isPortrait.isTrue ? _buildPortrait() : _buildLandscape());
  }

  Widget gestureDetector({required Widget child}) {
    final PeerTabModel peerTabModel = Provider.of(context);
    final peer = super.widget.peer;
    return GestureDetector(
        onDoubleTap: peerTabModel.multiSelectionMode
            ? null
            : () => widget.connect(context, peer.id),
        onTap: () {
          if (peerTabModel.multiSelectionMode) {
            peerTabModel.select(peer);
          } else {
            if (isMobile) {
              widget.connect(context, peer.id);
            } else {
              peerTabModel.select(peer);
            }
          }
        },
        onLongPress: () => peerTabModel.select(peer),
        child: child);
  }

  Widget _buildPortrait() {
    final peer = super.widget.peer;
    return Card(
        margin: EdgeInsets.symmetric(horizontal: 2),
        child: gestureDetector(
          child: Container(
              padding: EdgeInsets.only(left: 12, top: 8, bottom: 8),
              child: _buildPeerTile(context, peer, null)),
        ));
  }

  Widget _buildLandscape() {
    final peer = super.widget.peer;
    var deco = Rx<BoxDecoration?>(
      BoxDecoration(
        border: Border.all(color: Colors.transparent, width: _borderWidth),
        borderRadius: BorderRadius.circular(
          peerCardUiType.value == PeerUiType.grid ? _cardRadius : _tileRadius,
        ),
      ),
    );
    return MouseRegion(
      onEnter: (evt) {
        deco.value = BoxDecoration(
          border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: _borderWidth),
          borderRadius: BorderRadius.circular(
            peerCardUiType.value == PeerUiType.grid ? _cardRadius : _tileRadius,
          ),
        );
      },
      onExit: (evt) {
        deco.value = BoxDecoration(
          border: Border.all(color: Colors.transparent, width: _borderWidth),
          borderRadius: BorderRadius.circular(
            peerCardUiType.value == PeerUiType.grid ? _cardRadius : _tileRadius,
          ),
        );
      },
      child: gestureDetector(
          child: Obx(() => peerCardUiType.value == PeerUiType.grid
              ? _buildPeerCard(context, peer, deco)
              : _buildPeerTile(context, peer, deco))),
    );
  }

  bool _showNote(Peer peer) {
    return peerTabShowNote(widget.tab) && peer.note.isNotEmpty;
  }

  String _technicalName(Peer peer) {
    final username = peer.username.trim();
    final hostname = peer.hostname.trim();
    if (username.isNotEmpty && hostname.isNotEmpty) {
      return '$username@$hostname';
    }
    if (username.isNotEmpty) return username;
    if (hostname.isNotEmpty) return hostname;
    return formatID(peer.id);
  }

  String _peerSubtitle(Peer peer) {
    final override = widget.subtitleOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    return _technicalName(peer);
  }

  String _primaryTitle(Peer peer) {
    final alias = peer.alias.trim();
    if (alias.isNotEmpty) return alias;
    return _technicalName(peer);
  }

  String _secondaryTitle(Peer peer) {
    final technical = _peerSubtitle(peer);
    final id = formatID(peer.id);
    if (technical == id) return id;
    return '$technical  •  $id';
  }

  Widget _buildListTilePreviewStrip(
    BuildContext context,
    Peer peer, {
    required bool isPortrait,
  }) {
    final previewPath = peer.previewPath.trim();
    final isHttpPreview =
        previewPath.startsWith('http://') || previewPath.startsWith('https://');
    String? localPreviewPath;
    if (previewPath.isNotEmpty && !isHttpPreview) {
      try {
        if (previewPath.startsWith('file://')) {
          localPreviewPath = Uri.parse(previewPath)
              .replace(query: '', fragment: '')
              .toFilePath();
        } else {
          localPreviewPath = previewPath;
        }
      } catch (_) {
        localPreviewPath = previewPath;
      }
    }
    File? localPreviewFile;
    if (localPreviewPath != null && localPreviewPath.isNotEmpty) {
      try {
        final candidate = File(localPreviewPath);
        if (candidate.existsSync() && candidate.lengthSync() > 128) {
          localPreviewFile = candidate;
        }
      } catch (_) {
        localPreviewFile = null;
      }
    }
    final hasPreview = isHttpPreview || localPreviewFile != null;

    final stripW = isPortrait ? 50.0 : 96.0;
    final stripH = isPortrait ? 50.0 : 76.0;
    final br = isPortrait
        ? BorderRadius.circular(_tileRadius)
        : BorderRadius.only(
            topLeft: Radius.circular(_tileRadius),
            bottomLeft: Radius.circular(_tileRadius),
          );

    Widget fallbackContent() {
      return Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          ColoredBox(color: str2color('${peer.id}${peer.platform}', 0x7f)),
          Center(
            child: getPlatformImage(peer.platform, size: isPortrait ? 38 : 30)
                .paddingAll(6),
          ),
          if (_shouldBuildPasswordIcon(peer))
            Positioned(
              top: 1,
              left: 1,
              child: Icon(Icons.key, size: 6, color: Colors.white),
            ),
        ],
      );
    }

    Widget previewLayer() {
      if (isHttpPreview) {
        return Image.network(
          previewPath,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          errorBuilder: (_, __, ___) => fallbackContent(),
        );
      }
      if (localPreviewFile != null) {
        int modifiedAtMs = 0;
        try {
          modifiedAtMs =
              localPreviewFile.lastModifiedSync().millisecondsSinceEpoch;
        } catch (_) {}
        return Image.file(
          localPreviewFile,
          key: ValueKey<String>(
              '${peer.id}:${localPreviewFile.path}:$modifiedAtMs'),
          fit: BoxFit.cover,
          alignment: Alignment.center,
          errorBuilder: (_, __, ___) => fallbackContent(),
        );
      }
      return fallbackContent();
    }

    return SizedBox(
      width: stripW,
      height: stripH,
      child: ClipRRect(
        borderRadius: br,
        child: hasPreview
            ? Stack(
                fit: StackFit.expand,
                children: [
                  previewLayer(),
                  if (_shouldBuildPasswordIcon(peer))
                    Positioned(
                      top: 1,
                      left: 1,
                      child: Icon(Icons.key, size: 6, color: Colors.white),
                    ),
                ],
              )
            : fallbackContent(),
      ),
    );
  }

  makeChild(bool isPortrait, Peer peer) {
    final primaryTitle = _primaryTitle(peer);
    final secondaryTitle = _secondaryTitle(peer);
    final greyStyle = TextStyle(
        fontSize: 11,
        color: Theme.of(context).textTheme.titleLarge?.color?.withOpacity(0.6));
    final showNote = _showNote(peer);

    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        _buildListTilePreviewStrip(context, peer, isPortrait: isPortrait),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.only(
                topRight: Radius.circular(_tileRadius),
                bottomRight: Radius.circular(_tileRadius),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        getOnline(isPortrait ? 4 : 8, peer.online)
                      ]).marginOnly(top: isPortrait ? 0 : 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              primaryTitle,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Flexible(
                            child: Tooltip(
                              message: secondaryTitle,
                              waitDuration: const Duration(seconds: 1),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  secondaryTitle,
                                  style: isPortrait ? null : greyStyle,
                                  textAlign: TextAlign.start,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                            ),
                          ),
                          if (showNote)
                            Expanded(
                              child: Tooltip(
                                message: peer.note,
                                waitDuration: const Duration(seconds: 1),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    peer.note,
                                    style: isPortrait ? null : greyStyle,
                                    textAlign: TextAlign.start,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ).marginOnly(
                                      left: peerCardUiType.value ==
                                              PeerUiType.list
                                          ? 32
                                          : 4),
                                ),
                              ),
                            )
                        ],
                      ),
                      if (_cardGroupsLabel.isNotEmpty)
                        Row(
                          children: [
                            Flexible(
                              child: Tooltip(
                                message: _cardGroupsLabel,
                                waitDuration: const Duration(seconds: 1),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    _cardGroupsLabel,
                                    style: isPortrait ? null : greyStyle,
                                    textAlign: TextAlign.start,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ).marginOnly(top: 2),
                ),
                isPortrait
                    ? checkBoxOrActionMorePortrait(peer)
                    : checkBoxOrActionMoreLandscape(peer, isTile: true),
              ],
            ).paddingOnly(left: 10.0, top: 3.0),
          ),
        )
      ],
    );
  }

  Widget _buildPeerTile(
      BuildContext context, Peer peer, Rx<BoxDecoration?>? deco) {
    hideUsernameOnCard ??=
        bind.mainGetBuildinOption(key: kHideUsernameOnCard) == 'Y';
    final colors = _frontN(peer.tags, 25)
        .map((e) => gFFI.abModel.getCurrentAbTagColor(e))
        .toList();
    return Tooltip(
      message: !(isDesktop || isWebDesktop)
          ? ''
          : peer.tags.isNotEmpty
              ? '${translate('Tags')}: ${peer.tags.join(', ')}'
              : '',
      child: Stack(children: [
        Obx(
          () => deco == null
              ? makeChild(stateGlobal.isPortrait.isTrue, peer)
              : Container(
                  foregroundDecoration: deco.value,
                  child: makeChild(stateGlobal.isPortrait.isTrue, peer),
                ),
        ),
        if (colors.isNotEmpty)
          Obx(() => Positioned(
                top: 2,
                right: stateGlobal.isPortrait.isTrue ? 20 : 10,
                child: CustomPaint(
                  painter: TagPainter(radius: 3, colors: colors),
                ),
              ))
      ]),
    );
  }

  Widget _buildPeerCard(
      BuildContext context, Peer peer, Rx<BoxDecoration?> deco) {
    hideUsernameOnCard ??=
        bind.mainGetBuildinOption(key: kHideUsernameOnCard) == 'Y';
    final primaryTitle = _primaryTitle(peer);
    final technicalTitle = _peerSubtitle(peer);
    final peerIdTitle = formatID(peer.id);
    final previewPath = peer.previewPath.trim();
    final isHttpPreview =
        previewPath.startsWith('http://') || previewPath.startsWith('https://');
    String? localPreviewPath;
    if (previewPath.isNotEmpty && !isHttpPreview) {
      try {
        if (previewPath.startsWith('file://')) {
          final uri = Uri.parse(previewPath);
          localPreviewPath = uri.replace(query: '', fragment: '').toFilePath();
        } else {
          localPreviewPath = previewPath;
        }
      } catch (_) {
        localPreviewPath = previewPath;
      }
    }
    File? localPreviewFile;
    if (localPreviewPath != null && localPreviewPath.isNotEmpty) {
      try {
        final candidate = File(localPreviewPath);
        if (candidate.existsSync() && candidate.lengthSync() > 128) {
          localPreviewFile = candidate;
        }
      } catch (_) {
        localPreviewFile = null;
      }
    }
    final hasPreview = isHttpPreview || localPreviewFile != null;

    Widget imageErrorFallback() {
      return Stack(
        fit: StackFit.expand,
        children: [
          Container(color: const Color(0xFF1F2937)),
          Center(
            child: getPlatformImage(peer.platform, size: 74),
          ),
        ],
      );
    }

    Widget previewLayer() {
      if (isHttpPreview) {
        return Image.network(
          previewPath,
          key: ValueKey<String>('${peer.id}:$previewPath'),
          fit: BoxFit.cover,
          alignment: Alignment.center,
          errorBuilder: (_, __, ___) => imageErrorFallback(),
        );
      }
      if (localPreviewFile != null) {
        int modifiedAtMs = 0;
        try {
          modifiedAtMs =
              localPreviewFile.lastModifiedSync().millisecondsSinceEpoch;
        } catch (_) {}
        return Image.file(
          localPreviewFile,
          key: ValueKey<String>(
              '${peer.id}:${localPreviewFile.path}:$modifiedAtMs:$previewPath'),
          fit: BoxFit.cover,
          alignment: Alignment.center,
          errorBuilder: (_, __, ___) => imageErrorFallback(),
        );
      }
      return Container(color: const Color(0xFF1F2937));
    }

    final child = Card(
      color: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      // to-do: memory leak here, more investigation needed.
      // Continious rebuilds of `Obx()` will cause memory leak here.
      // The simple demo does not have this issue.
      child: Obx(
        () => Container(
          foregroundDecoration: deco.value,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_cardRadius - _borderWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          str2color('${peer.id}${peer.platform}', 0xAA),
                          str2color('${peer.id}${peer.platform}', 0x55),
                        ],
                      ),
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(child: previewLayer()),
                        if (!hasPreview)
                          Center(
                            child: getPlatformImage(peer.platform, size: 74),
                          ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0x00000000), Color(0xCC000000)],
                              ),
                            ),
                            padding: const EdgeInsets.fromLTRB(10, 16, 8, 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          getOnline(8, peer.online),
                                          Expanded(
                                            child: Text(
                                              primaryTitle,
                                              overflow: TextOverflow.ellipsis,
                                              maxLines: 1,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 22,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      Text(
                                        technicalTitle,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                        style: const TextStyle(
                                          color: Color(0xE6FFFFFF),
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      if (_cardGroupsLabel.isNotEmpty)
                                        Text(
                                          _cardGroupsLabel,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                          style: const TextStyle(
                                            color: Color(0xCCFFFFFF),
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      Text(
                                        peerIdTitle,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                        style: const TextStyle(
                                          color: Color(0xD9FFFFFF),
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      if (_showNote(peer))
                                        Text(
                                          peer.note,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                          style: const TextStyle(
                                            color: Color(0xCCFFFFFF),
                                            fontSize: 14,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                checkBoxOrActionMoreLandscape(peer,
                                    isTile: false),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final colors = _frontN(peer.tags, 25)
        .map((e) => gFFI.abModel.getCurrentAbTagColor(e))
        .toList();
    return Tooltip(
      message: peer.tags.isNotEmpty
          ? '${translate('Tags')}: ${peer.tags.join(', ')}'
          : '',
      child: Stack(children: [
        child,
        if (_shouldBuildPasswordIcon(peer))
          Positioned(
            top: 4,
            left: 12,
            child: Icon(Icons.key, size: 12, color: Colors.white),
          ),
        if (colors.isNotEmpty)
          Positioned(
            top: 4,
            right: 12,
            child: CustomPaint(
              painter: TagPainter(radius: 4, colors: colors),
            ),
          )
      ]),
    );
  }

  List _frontN<T>(List list, int n) {
    if (list.length <= n) {
      return list;
    } else {
      return list.sublist(0, n);
    }
  }

  Widget checkBoxOrActionMorePortrait(Peer peer) {
    final PeerTabModel peerTabModel = Provider.of(context);
    final selected = peerTabModel.isPeerSelected(peer.id);
    if (peerTabModel.multiSelectionMode) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: selected
            ? Icon(
                Icons.check_box,
                color: MyTheme.accent,
              )
            : Icon(Icons.check_box_outline_blank),
      );
    } else {
      return InkWell(
          child: const Padding(
              padding: EdgeInsets.all(12), child: Icon(Icons.more_vert)),
          onTapDown: (e) {
            final x = e.globalPosition.dx;
            final y = e.globalPosition.dy;
            _menuPos = RelativeRect.fromLTRB(x, y, x, y);
          },
          onTap: () {
            _showPeerMenu(peer.id);
          });
    }
  }

  Widget checkBoxOrActionMoreLandscape(Peer peer, {required bool isTile}) {
    final PeerTabModel peerTabModel = Provider.of(context);
    final selected = peerTabModel.isPeerSelected(peer.id);
    if (peerTabModel.multiSelectionMode) {
      final icon = selected
          ? Icon(
              Icons.check_box,
              color: MyTheme.accent,
            )
          : Icon(Icons.check_box_outline_blank);
      bool last = peerTabModel.isShiftDown && peer.id == peerTabModel.lastId;
      double right = isTile ? 4 : 0;
      if (last) {
        return Container(
          decoration: BoxDecoration(
              border: Border.all(color: MyTheme.accent, width: 1)),
          child: icon,
        ).marginOnly(right: right);
      } else {
        return icon.marginOnly(right: right);
      }
    } else {
      return _actionMore(peer);
    }
  }

  Widget _actionMore(Peer peer) => Listener(
      onPointerDown: (e) {
        final x = e.position.dx;
        final y = e.position.dy;
        _menuPos = RelativeRect.fromLTRB(x, y, x, y);
      },
      onPointerUp: (_) => _showPeerMenu(peer.id),
      child: build_more(context));

  bool _shouldBuildPasswordIcon(Peer peer) {
    if (gFFI.peerTabModel.currentTab != PeerTabIndex.ab.index) return false;
    if (gFFI.abModel.current.isPersonal()) return false;
    return peer.password.isNotEmpty;
  }

  /// Show the peer menu and handle user's choice.
  /// User might remove the peer or send a file to the peer.
  void _showPeerMenu(String id) async {
    await mod_menu.showMenu(
      context: context,
      position: _menuPos,
      items: await super.widget.popupMenuEntryBuilder(context),
      elevation: 8,
    );
  }

  @override
  bool get wantKeepAlive => true;
}

abstract class BasePeerCard extends StatelessWidget {
  final Peer peer;
  final PeerTabIndex tab;
  final EdgeInsets? menuPadding;
  final String? subtitleOverride;
  final String? cloudGroupsLabelOverride;

  BasePeerCard({
    required this.peer,
    required this.tab,
    this.menuPadding,
    this.subtitleOverride,
    this.cloudGroupsLabelOverride,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _PeerCard(
      peer: peer,
      tab: tab,
      connect: (BuildContext context, String id) =>
          connectInPeerTab(context, peer, tab),
      popupMenuEntryBuilder: _buildPopupMenuEntry,
      subtitleOverride: subtitleOverride,
      cloudGroupsLabelOverride: cloudGroupsLabelOverride,
    );
  }

  Future<List<mod_menu.PopupMenuEntry<String>>> _buildPopupMenuEntry(
          BuildContext context) async =>
      (await _buildMenuItems(context))
          .map((e) => e.build(
              context,
              const MenuConfig(
                  commonColor: CustomPopupMenuTheme.commonColor,
                  height: CustomPopupMenuTheme.height,
                  dividerHeight: CustomPopupMenuTheme.dividerHeight)))
          .expand((i) => i)
          .toList();

  @protected
  Future<List<MenuEntryBase<String>>> _buildMenuItems(BuildContext context);

  MenuEntryBase<String> _connectCommonAction(
    BuildContext context,
    String title, {
    bool isFileTransfer = false,
    bool isViewCamera = false,
    bool isTcpTunneling = false,
    bool isRDP = false,
    bool isTerminal = false,
    bool isTerminalRunAsAdmin = false,
  }) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        title,
        style: style,
      ),
      proc: () {
        if (isFileTransfer) {
          () async {
            if (!await hasProLicenseLocal()) {
              await showPremiumPaywallDialog(context);
              return;
            }
            if (isTerminalRunAsAdmin) {
              setEnvTerminalAdmin();
            } else {
              clearEnvTerminalAdmin();
            }
            connectInPeerTab(
              context,
              peer,
              tab,
              isFileTransfer: isFileTransfer,
              isViewCamera: isViewCamera,
              isTcpTunneling: isTcpTunneling,
              isRDP: isRDP,
              isTerminal: isTerminal || isTerminalRunAsAdmin,
            );
          }();
          return;
        }
        if (isTerminalRunAsAdmin) {
          setEnvTerminalAdmin();
        } else if (isTerminal) {
          clearEnvTerminalAdmin();
        }
        connectInPeerTab(
          context,
          peer,
          tab,
          isFileTransfer: isFileTransfer,
          isViewCamera: isViewCamera,
          isTcpTunneling: isTcpTunneling,
          isRDP: isRDP,
          isTerminal: isTerminal || isTerminalRunAsAdmin,
        );
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _connectAction(BuildContext context) {
    return _connectCommonAction(
      context,
      (peer.alias.isEmpty
          ? translate('Connect')
          : '${translate('Connect')} ${peer.id}'),
    );
  }

  @protected
  MenuEntryBase<String> _transferFileAction(BuildContext context) {
    return _connectCommonAction(
      context,
      translate('Transfer file'),
      isFileTransfer: true,
    );
  }

  @protected
  MenuEntryBase<String> _viewCameraAction(BuildContext context) {
    return _connectCommonAction(
      context,
      translate('View camera'),
      isViewCamera: true,
    );
  }

  @protected
  MenuEntryBase<String> _terminalAction(BuildContext context) {
    return _connectCommonAction(
      context,
      '${translate('Terminal')} (beta)',
      isTerminal: true,
    );
  }

  @protected
  MenuEntryBase<String> _terminalRunAsAdminAction(BuildContext context) {
    return _connectCommonAction(
      context,
      '${translate('Terminal (Run as administrator)')} (beta)',
      isTerminalRunAsAdmin: true,
    );
  }

  @protected
  MenuEntryBase<String> _tcpTunnelingAction(BuildContext context) {
    return _connectCommonAction(
      context,
      translate('TCP tunneling'),
      isTcpTunneling: true,
    );
  }

  @protected
  MenuEntryBase<String> _rdpAction(BuildContext context, String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Container(
          alignment: AlignmentDirectional.center,
          height: CustomPopupMenuTheme.height,
          child: Row(
            children: [
              Text(
                translate('RDP'),
                style: style,
              ),
              Expanded(
                  child: Align(
                alignment: Alignment.centerRight,
                child: Transform.scale(
                    scale: 0.8,
                    child: IconButton(
                      icon: const Icon(Icons.edit),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        if (Navigator.canPop(context)) {
                          Navigator.pop(context);
                        }
                        _rdpDialog(id);
                      },
                    )),
              ))
            ],
          )),
      proc: () {
        connectInPeerTab(context, peer, tab, isRDP: true);
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _wolAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('WOL'),
        style: style,
      ),
      proc: () {
        bind.mainWol(id: id);
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  /// Only available on Windows.
  @protected
  MenuEntryBase<String> _createShortCutAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('Create desktop shortcut'),
        style: style,
      ),
      proc: () {
        bind.mainCreateShortcut(id: id);
        showToast(translate('Successful'));
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  Future<MenuEntryBase<String>> _openNewConnInAction(
      String id, String label, String key) async {
    return MenuEntrySwitch<String>(
      switchType: SwitchType.scheckbox,
      text: translate(label),
      getter: () async => mainGetPeerBoolOptionSync(id, key),
      setter: (bool v) async {
        await bind.mainSetPeerOption(
            id: id, key: key, value: bool2option(key, v));
        showToast(translate('Successful'));
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  _openInTabsAction(String id) async =>
      await _openNewConnInAction(id, 'Open in New Tab', kOptionOpenInTabs);

  _openInWindowsAction(String id) async => await _openNewConnInAction(
      id, 'Open in new window', kOptionOpenInWindows);

  // ignore: unused_element
  _openNewConnInOptAction(String id) async =>
      mainGetLocalBoolOptionSync(kOptionOpenNewConnInTabs)
          ? await _openInWindowsAction(id)
          : await _openInTabsAction(id);

  @protected
  Future<bool> _isForceAlwaysRelay(String id) async {
    return option2bool(kOptionForceAlwaysRelay,
        (await bind.mainGetPeerOption(id: id, key: kOptionForceAlwaysRelay)));
  }

  @protected
  Future<MenuEntryBase<String>> _forceAlwaysRelayAction(String id) async {
    return MenuEntrySwitch<String>(
      switchType: SwitchType.scheckbox,
      text: translate('Always connect via relay'),
      getter: () async {
        return await _isForceAlwaysRelay(id);
      },
      setter: (bool v) async {
        await bind.mainSetPeerOption(
            id: id,
            key: kOptionForceAlwaysRelay,
            value: bool2option(kOptionForceAlwaysRelay, v));
        showToast(translate('Successful'));
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _renameAction(BuildContext context, String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('Rename'),
        style: style,
      ),
      proc: () async {
        if (!await hasProLicenseLocal()) {
          await showPremiumPaywallDialog(context);
          return;
        }
        String oldName = await _getAlias(id);
        renameDialog(
            oldName: oldName,
            onSubmit: (String newName) async {
              final normalizedName = newName.trim();
              if (normalizedName.isEmpty) {
                showToast(translate('Name can not be empty'));
                return;
              }
              if (normalizedName != oldName) {
                if (tab == PeerTabIndex.ab) {
                  await gFFI.abModel.changeAlias(id: id, alias: normalizedName);
                }
                final saved = await applyPeerDisplayNameEverywhere(
                  remoteId: id,
                  alias: normalizedName,
                  peer: peer,
                );
                final savedAlias =
                    await bind.mainGetPeerOption(id: id, key: 'alias');
                if (!saved || savedAlias != normalizedName) {
                  showToast(translate('Failed to save alias'));
                  return;
                }
                if (tab == PeerTabIndex.ab) {
                  gFFI.abModel.currentAbPeers.refresh();
                } else if (tab == PeerTabIndex.cloudContacts) {
                  if (context.mounted) {
                    await context
                        .findAncestorStateOfType<CloudContactsPageState>()
                        ?.reloadCloudContacts();
                  }
                } else {
                  _update();
                }
                showToast(translate('Successful'));
              }
            });
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _removeAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Row(
        children: [
          Text(
            translate('Delete'),
            style: style?.copyWith(color: Colors.red),
          ),
          Expanded(
              child: Align(
            alignment: Alignment.centerRight,
            child: Transform.scale(
              scale: 0.8,
              child: Icon(Icons.delete_forever, color: Colors.red),
            ),
          ).marginOnly(right: 4)),
        ],
      ),
      proc: () {
        onSubmit() async {
          switch (tab) {
            case PeerTabIndex.recent:
              await bind.mainRemovePeer(id: id);
              bind.mainLoadRecentPeers();
              break;
            case PeerTabIndex.fav:
              final favs = (await bind.mainGetFav()).toList();
              if (favs.remove(id)) {
                await bind.mainStoreFav(favs: favs);
                await FavoriteGroupsStore.removePeer(id);
                bind.mainLoadFavPeers();
              }
              break;
            case PeerTabIndex.cloudContacts:
              break;
            case PeerTabIndex.lan:
              await bind.mainRemoveDiscovered(id: id);
              bind.mainLoadLanPeers();
              break;
            case PeerTabIndex.ab:
              await gFFI.abModel.deletePeers([id]);
              break;
            case PeerTabIndex.group:
              break;
            case PeerTabIndex.health:
              break;
            case PeerTabIndex.myDevices:
              break;
            case PeerTabIndex.scriptManager:
              break;
            case PeerTabIndex.localMaintenance:
              break;
            case PeerTabIndex.secureTransfer:
              break;
          }
          if (tab != PeerTabIndex.ab) {
            showToast(translate('Successful'));
          }
        }

        deleteConfirmDialog(onSubmit,
            '${translate('Delete')} "${peer.alias.isEmpty ? formatID(peer.id) : peer.alias}"?');
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _unrememberPasswordAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('Forget Password'),
        style: style,
      ),
      proc: () async {
        bool succ = await gFFI.abModel.changePersonalHashPassword(id, '');
        await bind.mainForgetPassword(id: id);
        if (succ) {
          showToast(translate('Successful'));
        } else {
          if (tab.index == PeerTabIndex.ab.index) {
            BotToast.showText(
                contentColor: Colors.red, text: translate("Failed"));
          }
        }
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _addFavAction(BuildContext context, String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Row(
        children: [
          Text(
            translate('Add to Favorites'),
            style: style,
          ),
          Expanded(
              child: Align(
            alignment: Alignment.centerRight,
            child: Transform.scale(
              scale: 0.8,
              child: Icon(Icons.star_outline),
            ),
          ).marginOnly(right: 4)),
        ],
      ),
      proc: () {
        () async {
          final favs = (await bind.mainGetFav()).toList();
          if (!favs.contains(id)) {
            favs.add(id);
            await bind.mainStoreFav(favs: favs);
          }
          await bind.mainLoadFavPeers();
          showToast(translate('Successful'));
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _rmFavAction(
      String id, Future<void> Function() reloadFunc) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Row(
        children: [
          Text(
            translate('Remove from Favorites'),
            style: style,
          ),
          Expanded(
              child: Align(
            alignment: Alignment.centerRight,
            child: Transform.scale(
              scale: 0.8,
              child: Icon(Icons.star_border),
            ),
          ).marginOnly(right: 4)),
        ],
      ),
      proc: () {
        () async {
          final favs = (await bind.mainGetFav()).toList();
          if (favs.remove(id)) {
            await bind.mainStoreFav(favs: favs);
            await FavoriteGroupsStore.removePeer(id);
            await reloadFunc();
          }
          showToast(translate('Successful'));
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _addToAb(Peer peer) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('Add to address book'),
        style: style,
      ),
      proc: () {
        () async {
          addPeersToAbDialog([Peer.copy(peer)]);
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _cloudContactsMenuAction(
    BuildContext context,
    Peer peer, {
    required bool isEdit,
    String? existingAlias,
    List<String>? existingGroups,
  }) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Row(
        children: [
          Text(
            isEdit ? translate('Edit Contact') : translate('Add to Contacts'),
            style: style,
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Transform.scale(
                scale: 0.8,
                child: Icon(
                  isEdit ? Icons.edit_outlined : Icons.person_add_alt_1,
                ),
              ),
            ).marginOnly(right: 4),
          ),
        ],
      ),
      proc: () {
        () async {
          if (!await canUseCloudContactsLocal()) {
            await showPremiumPaywallDialog(context);
            return;
          }
          if (CloudContactsService.resolveAuthToken() == null ||
              CloudContactsService.resolveUserEmail() == null) {
            showToast(translate('Cloud Contacts login required'));
            return;
          }
          await showCloudContactAliasDialog(
            context,
            remoteId: peer.id,
            initialAlias: existingAlias ??
                (peer.alias.isNotEmpty ? peer.alias : peer.id),
            initialGroups: existingGroups,
            isEdit: isEdit,
            peer: peer,
          );
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  Future<MenuEntryBase<String>?> _buildCloudContactsMenuEntry(
      BuildContext context, Peer peer) async {
    if (!await canUseCloudContactsLocal()) {
      return null;
    }
    if (CloudContactsService.resolveAuthToken() == null ||
        CloudContactsService.resolveUserEmail() == null) {
      return null;
    }
    try {
      final existing =
          await CloudContactsService.findByRemoteId(peer.id);
      return _cloudContactsMenuAction(
        context,
        peer,
        isEdit: existing != null,
        existingAlias: existing?.aliasName,
        existingGroups: existing?.groups,
      );
    } catch (_) {
      return _cloudContactsMenuAction(context, peer, isEdit: false);
    }
  }

  @protected
  MenuEntryBase<String> _editFavGroupAction(BuildContext context, String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Row(
        children: [
          Text(
            translate('Edit Tag'),
            style: style,
          ),
          Expanded(
              child: Align(
            alignment: Alignment.centerRight,
            child: Transform.scale(
              scale: 0.8,
              child: const Icon(Icons.edit_outlined),
            ),
          ).marginOnly(right: 4)),
        ],
      ),
      proc: () {
        () async {
          final groups = await FavoriteGroupsStore.loadPeerGroups();
          final selectedGroup = await showFavoriteGroupDialog(
            context,
            title: translate('Select Favorites Group'),
            initialGroup: groups[id] ?? kDefaultFavoriteGroup,
            confirmLabel: translate('OK'),
          );
          if (selectedGroup == null) return;
          await FavoriteGroupsStore.assignPeerToGroup(id, selectedGroup);
          await bind.mainLoadFavPeers();
          showToast(translate('Successful'));
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _addImageAction(BuildContext context, String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        'Add Image',
        style: style,
      ),
      proc: () {
        () async {
          try {
            final controller = TextEditingController();
            final result = await showDialog<String>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Add Image Link'),
                content: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'https://example.com/image.png',
                  ),
                  onSubmitted: (_) =>
                      Navigator.of(ctx).pop(controller.text.trim()),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: () =>
                        Navigator.of(ctx).pop(controller.text.trim()),
                    child: const Text('Save'),
                  ),
                ],
              ),
            );
            controller.dispose();
            final imageUrl = (result ?? '').trim();
            if (imageUrl.isEmpty) return;
            final uri = Uri.tryParse(imageUrl);
            final isHttp = uri != null &&
                uri.hasScheme &&
                (uri.scheme == 'http' || uri.scheme == 'https');
            if (!isHttp) {
              showToast('Please enter a valid image URL');
              return;
            }

            await bind.mainSetPeerOption(
                id: id, key: 'desktop-preview-path', value: imageUrl);
            await bind.mainLoadRecentPeers();
            await bind.mainLoadFavPeers();
            await bind.mainLoadLanPeers();
            showToast(translate('Successful'));
          } catch (e) {
            showToast('Failed to set custom image');
          }
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _clearImageAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        'Clear Image',
        style: style,
      ),
      proc: () {
        () async {
          try {
            final previewPath = (await bind.mainGetPeerOption(
                    id: id, key: 'desktop-preview-path'))
                .trim();
            if (previewPath.isNotEmpty &&
                !previewPath.startsWith('http://') &&
                !previewPath.startsWith('https://')) {
              try {
                final localPath = previewPath.startsWith('file://')
                    ? Uri.parse(previewPath)
                        .replace(query: '', fragment: '')
                        .toFilePath()
                    : previewPath;
                final f = File(localPath);
                if (await f.exists()) {
                  await f.delete();
                }
              } catch (_) {
                // Ignore local delete errors and continue clearing option.
              }
            }

            await bind.mainSetPeerOption(
                id: id, key: 'desktop-preview-path', value: '');
            await bind.mainLoadRecentPeers();
            await bind.mainLoadFavPeers();
            await bind.mainLoadLanPeers();
            showToast(translate('Successful'));
          } catch (_) {
            showToast('Failed to clear custom image');
          }
        }();
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _serviceHistoryAction(BuildContext context, String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Row(
        children: [
          Text(
            'הצג היסטוריית טיפולים',
            style: style,
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Transform.scale(
                scale: 0.8,
                child: const Icon(Icons.history_edu_outlined),
              ),
            ).marginOnly(right: 4),
          ),
        ],
      ),
      proc: () {
        unawaited(showCrmPeerHistoryDialog(context: context, peerId: id));
      },
      padding: menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  Future<String> _getAlias(String id) async =>
      await bind.mainGetPeerOption(id: id, key: 'alias');

  @protected
  void _update();
}

class RecentPeerCard extends BasePeerCard {
  RecentPeerCard({required Peer peer, EdgeInsets? menuPadding, Key? key})
      : super(
            peer: peer,
            tab: PeerTabIndex.recent,
            menuPadding: menuPadding,
            key: key);

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
      BuildContext context) async {
    final hasLicense = await hasProLicenseLocal();
    final List favs = (await bind.mainGetFav()).toList();
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      if (hasLicense) _transferFileAction(context),
      MenuEntryDivider(),
    ];

    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
    if (hasLicense && (isMobile || isDesktop || isWebDesktop)) {
      menuItems.add(_renameAction(context, peer.id));
      menuItems.add(_addImageAction(context, peer.id));
      menuItems.add(_clearImageAction(peer.id));
    }

    if (hasLicense && !favs.contains(peer.id)) {
      menuItems.add(_addFavAction(context, peer.id));
    } else if (favs.contains(peer.id)) {
      menuItems.add(_rmFavAction(peer.id, bind.mainLoadRecentPeers));
    }
    if (hasLicense) {
      menuItems.add(_serviceHistoryAction(context, peer.id));
    }
    final cloudEntry = await _buildCloudContactsMenuEntry(context, peer);
    if (cloudEntry != null) {
      menuItems.add(MenuEntryDivider());
      menuItems.add(cloudEntry);
    }
    menuItems.add(_removeAction(peer.id));
    return menuItems;
  }

  @protected
  @override
  void _update() => bind.mainLoadRecentPeers();
}

class FavoritePeerCard extends BasePeerCard {
  FavoritePeerCard({required Peer peer, EdgeInsets? menuPadding, Key? key})
      : super(
            peer: peer,
            tab: PeerTabIndex.fav,
            menuPadding: menuPadding,
            key: key);

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
      BuildContext context) async {
    final hasLicense = await hasProLicenseLocal();
    final List favs = (await bind.mainGetFav()).toList();
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      if (hasLicense) _transferFileAction(context),
      MenuEntryDivider(),
    ];

    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
    if (hasLicense && (isMobile || isDesktop || isWebDesktop)) {
      menuItems.add(_renameAction(context, peer.id));
      menuItems.add(_addImageAction(context, peer.id));
      menuItems.add(_clearImageAction(peer.id));
    }
    if (hasLicense && !favs.contains(peer.id)) {
      menuItems.add(_addFavAction(context, peer.id));
    } else if (favs.contains(peer.id)) {
      menuItems.add(_rmFavAction(peer.id, bind.mainLoadFavPeers));
    }
    if (hasLicense) {
      menuItems.add(_serviceHistoryAction(context, peer.id));
    }
    final cloudEntry = await _buildCloudContactsMenuEntry(context, peer);
    if (cloudEntry != null) {
      menuItems.add(MenuEntryDivider());
      menuItems.add(cloudEntry);
    }
    menuItems.add(_removeAction(peer.id));
    return menuItems;
  }

  @protected
  @override
  void _update() => bind.mainLoadFavPeers();
}

class CloudContactPeerCard extends BasePeerCard {
  CloudContactPeerCard({
    required Peer peer,
    String cloudSubtitle = '',
    String cloudGroupsLabel = '',
    EdgeInsets? menuPadding,
    Key? key,
  }) : super(
            peer: peer,
            tab: PeerTabIndex.cloudContacts,
            menuPadding: menuPadding,
            subtitleOverride: cloudSubtitle.trim().isEmpty ? null : cloudSubtitle,
            cloudGroupsLabelOverride:
                cloudGroupsLabel.trim().isEmpty ? null : cloudGroupsLabel,
            key: key);

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
      BuildContext context) async {
    final hasLicense = await hasProLicenseLocal();
    final List favs = (await bind.mainGetFav()).toList();
    final menuItems = <MenuEntryBase<String>>[
      _connectAction(context),
      if (hasLicense) _transferFileAction(context),
      MenuEntryDivider(),
    ];

    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
    if (hasLicense && (isMobile || isDesktop || isWebDesktop)) {
      menuItems.add(_renameAction(context, peer.id));
      menuItems.add(_addImageAction(context, peer.id));
      menuItems.add(_clearImageAction(peer.id));
    }
    if (hasLicense && !favs.contains(peer.id)) {
      menuItems.add(_addFavAction(context, peer.id));
    } else if (favs.contains(peer.id)) {
      menuItems.add(_rmFavAction(peer.id, bind.mainLoadFavPeers));
    }
    if (hasLicense) {
      menuItems.add(_serviceHistoryAction(context, peer.id));
    }
    final cloudEntry = await _buildCloudContactsMenuEntry(context, peer);
    if (cloudEntry != null) {
      menuItems.add(MenuEntryDivider());
      menuItems.add(cloudEntry);
    }
    menuItems.add(
      MenuEntryButton<String>(
        childBuilder: (style) => Text(
          translate('Delete Contact'),
          style: style?.copyWith(color: Colors.red),
        ),
        proc: () {
          () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(translate('Delete Contact')),
                content: Text('${peer.alias}\n${peer.id}'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(translate('Cancel')),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    child: Text(translate('Delete')),
                  ),
                ],
              ),
            );
            if (ok != true) return;
            try {
              await CloudContactsService.deleteContact(remoteId: peer.id);
              showToast(translate('Successful'));
              if (context.mounted) {
                await context
                    .findAncestorStateOfType<CloudContactsPageState>()
                    ?.reloadCloudContacts();
              }
            } on CloudContactsException catch (e) {
              showToast(e.message);
            }
          }();
        },
        dismissOnClicked: true,
        padding: menuPadding,
      ),
    );
    return menuItems;
  }

  @protected
  @override
  void _update() {}
}

class DiscoveredPeerCard extends BasePeerCard {
  DiscoveredPeerCard({required Peer peer, EdgeInsets? menuPadding, Key? key})
      : super(
            peer: peer,
            tab: PeerTabIndex.lan,
            menuPadding: menuPadding,
            key: key);

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
      BuildContext context) async {
    final hasLicense = await hasProLicenseLocal();
    final List favs = (await bind.mainGetFav()).toList();
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      if (hasLicense) _transferFileAction(context),
      MenuEntryDivider(),
    ];

    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }

    if (hasLicense && (isMobile || isDesktop || isWebDesktop)) {
      menuItems.add(_renameAction(context, peer.id));
      menuItems.add(_addImageAction(context, peer.id));
      menuItems.add(_clearImageAction(peer.id));
    }
    if (hasLicense && !favs.contains(peer.id)) {
      menuItems.add(_addFavAction(context, peer.id));
    } else if (favs.contains(peer.id)) {
      menuItems.add(_rmFavAction(peer.id, bind.mainLoadLanPeers));
    }
    if (hasLicense) {
      menuItems.add(_serviceHistoryAction(context, peer.id));
    }
    final cloudEntry = await _buildCloudContactsMenuEntry(context, peer);
    if (cloudEntry != null) {
      menuItems.add(MenuEntryDivider());
      menuItems.add(cloudEntry);
    }
    menuItems.add(_removeAction(peer.id));
    return menuItems;
  }

  @protected
  @override
  void _update() => bind.mainLoadLanPeers();
}

class AddressBookPeerCard extends BasePeerCard {
  AddressBookPeerCard({required Peer peer, EdgeInsets? menuPadding, Key? key})
      : super(
            peer: peer,
            tab: PeerTabIndex.ab,
            menuPadding: menuPadding,
            key: key);

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
      BuildContext context) async {
    final hasLicense = await hasProLicenseLocal();
    final List favs = (await bind.mainGetFav()).toList();
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      if (hasLicense) _transferFileAction(context),
      MenuEntryDivider(),
    ];

    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
    if (hasLicense && (isMobile || isDesktop || isWebDesktop)) {
      menuItems.add(_renameAction(context, peer.id));
      menuItems.add(_addImageAction(context, peer.id));
      menuItems.add(_clearImageAction(peer.id));
    }
    if (hasLicense && !favs.contains(peer.id)) {
      menuItems.add(_addFavAction(context, peer.id));
    } else if (favs.contains(peer.id)) {
      menuItems.add(_editFavGroupAction(context, peer.id));
    }
    if (hasLicense) {
      menuItems.add(_serviceHistoryAction(context, peer.id));
    }
    menuItems.add(_removeAction(peer.id));
    return menuItems;
  }

  // address book does not need to update
  @protected
  @override
  void _update() =>
      {}; //gFFI.abModel.pullAb(force: ForcePullAb.current, quiet: true);

  @protected
  MenuEntryBase<String> _editTagAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('Edit Tag'),
        style: style,
      ),
      proc: () {
        editAbTagDialog(gFFI.abModel.getPeerTags(id), (selectedTag) async {
          await gFFI.abModel.changeTagForPeers([id], selectedTag);
        });
      },
      padding: super.menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  MenuEntryBase<String> _editNoteAction(String id) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('Edit note'),
        style: style,
      ),
      proc: () {
        editAbPeerNoteDialog(id);
      },
      padding: super.menuPadding,
      dismissOnClicked: true,
    );
  }

  @protected
  @override
  Future<String> _getAlias(String id) async =>
      gFFI.abModel.find(id)?.alias ?? '';

  MenuEntryBase<String> _changeSharedAbPassword() {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate(
            peer.password.isEmpty ? 'Set shared password' : 'Change Password'),
        style: style,
      ),
      proc: () {
        setSharedAbPasswordDialog(gFFI.abModel.currentName.value, peer);
      },
      padding: super.menuPadding,
      dismissOnClicked: true,
    );
  }

  MenuEntryBase<String> _existIn() {
    final names = gFFI.abModel.idExistIn(peer.id);
    final text = names.join(', ');
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('Exist in'),
        style: style,
      ),
      proc: () {
        gFFI.dialogManager.show((setState, close, context) {
          return CustomAlertDialog(
            title: Text(translate('Exist in')),
            content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(text)]),
            actions: [
              dialogButton(
                "OK",
                icon: Icon(Icons.done_rounded),
                onPressed: close,
              ),
            ],
            onSubmit: close,
            onCancel: close,
          );
        });
      },
      padding: super.menuPadding,
      dismissOnClicked: true,
    );
  }
}

class MyGroupPeerCard extends BasePeerCard {
  MyGroupPeerCard({required Peer peer, EdgeInsets? menuPadding, Key? key})
      : super(
            peer: peer,
            tab: PeerTabIndex.group,
            menuPadding: menuPadding,
            key: key);

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
      BuildContext context) async {
    final hasLicense = await hasProLicenseLocal();
    final List favs = (await bind.mainGetFav()).toList();
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      if (hasLicense) _transferFileAction(context),
      MenuEntryDivider(),
    ];

    if (isWindows) {
      menuItems.add(_createShortCutAction(peer.id));
    }
    if (hasLicense && (isMobile || isDesktop || isWebDesktop)) {
      menuItems.add(_renameAction(context, peer.id));
      menuItems.add(_addImageAction(context, peer.id));
      menuItems.add(_clearImageAction(peer.id));
    }
    if (hasLicense && !favs.contains(peer.id)) {
      menuItems.add(_addFavAction(context, peer.id));
    } else if (favs.contains(peer.id)) {
      menuItems.add(_rmFavAction(peer.id, () async {}));
    }
    menuItems.add(_removeAction(peer.id));
    return menuItems;
  }

  @protected
  @override
  void _update() => gFFI.groupModel.pull();
}

void _rdpDialog(String id) async {
  final maxLength = bind.mainMaxEncryptLen();
  final port = await bind.mainGetPeerOption(id: id, key: 'rdp_port');
  final username = await bind.mainGetPeerOption(id: id, key: 'rdp_username');
  final portController = TextEditingController(text: port);
  final userController = TextEditingController(text: username);
  final passwordController = TextEditingController(
      text: await bind.mainGetPeerOption(id: id, key: 'rdp_password'));
  RxBool secure = true.obs;

  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      String port = portController.text.trim();
      String username = userController.text;
      String password = passwordController.text;
      await bind.mainSetPeerOption(id: id, key: 'rdp_port', value: port);
      await bind.mainSetPeerOption(
          id: id, key: 'rdp_username', value: username);
      await bind.mainSetPeerOption(
          id: id, key: 'rdp_password', value: password);
      showToast(translate('Successful'));
      close();
    }

    return CustomAlertDialog(
      title: Text(translate('RDP Settings')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                isDesktop
                    ? ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 140),
                        child: Text(
                          "${translate('Port')}:",
                          textAlign: TextAlign.right,
                        ).marginOnly(right: 10))
                    : SizedBox.shrink(),
                Expanded(
                  child: TextField(
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(
                          r'^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$'))
                    ],
                    decoration: InputDecoration(
                        labelText: isDesktop ? null : translate('Port'),
                        hintText: '3389'),
                    controller: portController,
                    autofocus: true,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ).marginOnly(bottom: isDesktop ? 8 : 0),
            Obx(() => Row(
                  children: [
                    stateGlobal.isPortrait.isFalse
                        ? ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 140),
                            child: Text(
                              "${translate('Username')}:",
                              textAlign: TextAlign.right,
                            ).marginOnly(right: 10))
                        : SizedBox.shrink(),
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(
                            labelText:
                                isDesktop ? null : translate('Username')),
                        controller: userController,
                      ).workaroundFreezeLinuxMint(),
                    ),
                  ],
                ).marginOnly(bottom: stateGlobal.isPortrait.isFalse ? 8 : 0)),
            Obx(() => Row(
                  children: [
                    stateGlobal.isPortrait.isFalse
                        ? ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 140),
                            child: Text(
                              "${translate('Password')}:",
                              textAlign: TextAlign.right,
                            ).marginOnly(right: 10))
                        : SizedBox.shrink(),
                    Expanded(
                      child: Obx(() => TextField(
                            obscureText: secure.value,
                            maxLength: maxLength,
                            decoration: InputDecoration(
                                labelText:
                                    isDesktop ? null : translate('Password'),
                                suffixIcon: IconButton(
                                    onPressed: () =>
                                        secure.value = !secure.value,
                                    icon: Icon(secure.value
                                        ? Icons.visibility_off
                                        : Icons.visibility))),
                            controller: passwordController,
                          ).workaroundFreezeLinuxMint()),
                    ),
                  ],
                ))
          ],
        ),
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

Widget getOnline(double rightPadding, bool online) {
  return Tooltip(
      message: translate(online ? 'Online' : 'Offline'),
      waitDuration: const Duration(seconds: 1),
      child: Padding(
          padding: EdgeInsets.fromLTRB(0, 4, rightPadding, 4),
          child: CircleAvatar(
              radius: 3, backgroundColor: online ? Colors.green : kColorWarn)));
}

Widget build_more(BuildContext context, {bool invert = false}) {
  final RxBool hover = false.obs;
  return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {},
      onHover: (value) => hover.value = value,
      child: Obx(() => CircleAvatar(
          radius: 14,
          backgroundColor: hover.value
              ? (invert
                  ? Theme.of(context).colorScheme.surface
                  : Theme.of(context).scaffoldBackgroundColor)
              : (invert
                  ? Theme.of(context).scaffoldBackgroundColor
                  : Theme.of(context).colorScheme.surface),
          child: Icon(Icons.more_vert,
              size: 18,
              color: hover.value
                  ? Theme.of(context).textTheme.titleLarge?.color
                  : Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.color
                      ?.withOpacity(0.5)))));
}

class TagPainter extends CustomPainter {
  final double radius;
  late final List<Color> colors;

  TagPainter({required this.radius, required List<Color> colors}) {
    this.colors = colors.reversed.toList();
  }

  @override
  void paint(Canvas canvas, Size size) {
    double x = 0;
    double y = radius;
    for (int i = 0; i < colors.length; i++) {
      Paint paint = Paint();
      paint.color = colors[i];
      x -= radius + 1;
      if (i == colors.length - 1) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      } else {
        Path path = Path();
        path.addArc(Rect.fromCircle(center: Offset(x, y), radius: radius),
            math.pi * 4 / 3, math.pi * 4 / 3);
        path.addArc(
            Rect.fromCircle(center: Offset(x - radius, y), radius: radius),
            math.pi * 5 / 3,
            math.pi * 2 / 3);
        path.fillType = PathFillType.evenOdd;
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

void connectInPeerTab(BuildContext context, Peer peer, PeerTabIndex tab,
    {bool isFileTransfer = false,
    bool isViewCamera = false,
    bool isTcpTunneling = false,
    bool isRDP = false,
    bool isTerminal = false}) async {
  var password = '';
  bool isSharedPassword = false;
  if (tab == PeerTabIndex.ab) {
    // If recent peer's alias is empty, set it to ab's alias
    // Because the platform is not set, it may not take effect, but it is more important not to display if the connection is not successful
    if (peer.alias.isNotEmpty &&
        (await bind.mainGetPeerOption(id: peer.id, key: "alias")).isEmpty) {
      await bind.mainSetPeerAlias(
        id: peer.id,
        alias: peer.alias,
      );
    }
    if (!gFFI.abModel.current.isPersonal()) {
      if (peer.password.isNotEmpty) {
        password = peer.password;
        isSharedPassword = true;
      }
      if (password.isEmpty) {
        final abPassword = gFFI.abModel.getdefaultSharedPassword();
        if (abPassword != null) {
          password = abPassword;
          isSharedPassword = true;
        }
      }
    }
  }
  connect(context, peer.id,
      password: password,
      isSharedPassword: isSharedPassword,
      isFileTransfer: isFileTransfer,
      isTerminal: isTerminal,
      isViewCamera: isViewCamera,
      isTcpTunneling: isTcpTunneling,
      isRDP: isRDP);
}
