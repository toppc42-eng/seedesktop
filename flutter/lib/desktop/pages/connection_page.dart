// main window right pane

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/widgets/connection_page_title.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/desktop/widgets/popup_menu.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/widgets/peer_tab_page.dart';
import '../../common/widgets/promo_banner_carousel.dart';
import '../../common/widgets/premium_paywall_dialog.dart';
import '../../common/widgets/autocomplete.dart';
import '../../models/platform_model.dart';
import '../../desktop/widgets/connection_status_strip.dart';
import '../../desktop/pages/desktop_tab_page.dart';
import '../../desktop/pages/desktop_setting_page.dart';
import '../../desktop/widgets/main_menu_localized.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import '../../utils/agent_heartbeat_manager.dart';
import '../../utils/multi_window_manager.dart';
import '../../utils/freemium_guard.dart';
import '../../utils/license_manager.dart' show getSavedLicenseKey;
import '../../utils/sdfree_account_trial.dart' show getSdFreeOfferRemainingMs;

class OnlineStatusWidget extends StatefulWidget {
  const OnlineStatusWidget({Key? key, this.onSvcStatusChanged})
      : super(key: key);

  final VoidCallback? onSvcStatusChanged;

  @override
  State<OnlineStatusWidget> createState() => _OnlineStatusWidgetState();
}

/// State for the connection page.
class _OnlineStatusWidgetState extends State<OnlineStatusWidget> {
  final _svcStopped = Get.find<RxBool>(tag: 'stop-service');
  final _licenseStatusText = unlicensedStatusDisplayLine().obs;
  Timer? _updateTimer;

  double get em => 14.0;
  double? get height => bind.isIncomingOnly() ? null : em * 3;

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(Duration(seconds: 1), () async {
      updateStatus();
    });
    _loadLicenseStatus();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isIncomingOnly = bind.isIncomingOnly();
    startServiceWidget() => Offstage(
          offstage: !_svcStopped.value,
          child: InkWell(
                  onTap: () async {
                    await start_service(true);
                  },
                  child: Text(translate("Start service"),
                      style: TextStyle(
                          decoration: TextDecoration.underline, fontSize: em)))
              .marginOnly(left: em),
        );

    basicWidget() => Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              height: 8,
              width: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: _svcStopped.value ||
                        stateGlobal.svcStatus.value == SvcStatus.connecting
                    ? kColorWarn
                    : (stateGlobal.svcStatus.value == SvcStatus.ready
                        ? Color.fromARGB(255, 50, 190, 166)
                        : Color.fromARGB(255, 224, 79, 95)),
              ),
            ).marginSymmetric(horizontal: em),
            Container(
              width: isIncomingOnly ? 226 : null,
              child: _buildConnStatusMsg(),
            ),
            Flexible(
              child: Container(
                margin: EdgeInsets.only(left: em),
                child: Obx(
                  () => Text(
                    _licenseStatusText.value,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: em),
                  ),
                ),
              ),
            ),
            // stop
            if (!isIncomingOnly) startServiceWidget(),
          ],
        );

    return Container(
      height: height,
      child: Obx(() => isIncomingOnly
          ? Column(
              children: [
                basicWidget(),
                Align(
                        child: startServiceWidget(),
                        alignment: Alignment.centerLeft)
                    .marginOnly(top: 2.0, left: 22.0),
              ],
            )
          : basicWidget()),
    ).paddingOnly(right: isIncomingOnly ? 8 : 0);
  }

  _buildConnStatusMsg() {
    widget.onSvcStatusChanged?.call();
    return Text(
      _svcStopped.value
          ? translate("Service is not running")
          : stateGlobal.svcStatus.value == SvcStatus.connecting
              ? translate("connecting_status")
              : stateGlobal.svcStatus.value == SvcStatus.notReady
                  ? translate("not_ready_status")
                  : translate('Ready'),
      style: TextStyle(fontSize: em),
    );
  }

  updateStatus() async {
    final status =
        jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
    final statusNum = status['status_num'] as int;
    if (statusNum == 0) {
      stateGlobal.svcStatus.value = SvcStatus.connecting;
    } else if (statusNum == -1) {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    } else if (statusNum == 1) {
      stateGlobal.svcStatus.value = SvcStatus.ready;
    } else {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    }
    try {
      stateGlobal.videoConnCount.value = status['video_conn_count'] as int;
    } catch (_) {}
    await _loadLicenseStatus();
  }

  Future<void> _loadLicenseStatus() async {
    final statusText = await getLicenseStatusDisplayTextLocal();
    if (_licenseStatusText.value != statusText) {
      _licenseStatusText.value = statusText;
    }
  }
}

/// Connection page for connecting to a remote peer.
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({Key? key}) : super(key: key);

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

/// State for the connection page.
class _ConnectionPageState extends State<ConnectionPage>
    with SingleTickerProviderStateMixin, WindowListener {
  static const Color _frameLightGray = Color(0xFFD6D6D6);
  static const Color _numberRed = Color(0xFFE53935);

  /// Matches inner ID box on «Your Desktop»; both panels use the same outer height.
  static const double _innerIdBoxHeight = 88;

  /// Fits remote (title + id + connect) and local (title + id + copy) panels.
  static const double _topFrameMinHeight = 192;
  static const double _bottomBannerHeight = 125;
  static const String _fallbackBannerUrl =
      'https://seedesktop.com/wp-content/uploads/2026/03/SeeDesktop4.png';
  static const List<String> _licensedBannerUrls = [
    'https://seedesktop.com/wp-content/uploads/2026/03/SeeDesktop.png',
  ];
  static const List<String> _unlicensedBannerUrls = [
    'https://seedesktop.com/wp-content/uploads/2026/03/SeeDesktop1.png',
    'https://seedesktop.com/wp-content/uploads/2026/03/SeeDesktop2.png',
    'https://seedesktop.com/wp-content/uploads/2026/03/SeeDesktop3.png',
    'https://seedesktop.com/wp-content/uploads/2026/03/SeeDesktop4.png',
  ];

  /// Controller for the id input bar.
  final _idController = IDTextEditingController();

  final RxBool _idInputFocused = false.obs;
  final FocusNode _idFocusNode = FocusNode();
  final TextEditingController _idEditingController = TextEditingController();

  String selectedConnectionType = 'Connect';

  bool isWindowMinimized = false;

  final AllPeersLoader _allPeersLoader = AllPeersLoader();

  // https://github.com/flutter/flutter/issues/157244
  Iterable<Peer> _autocompleteOpts = [];

  final _menuOpen = false.obs;
  final _bannerHasLicense = false.obs;
  final _bannerInSdFreeTrial = false.obs;
  final _bannerRefreshTs = DateTime.now().millisecondsSinceEpoch.obs;
  final PageController _bannerPageController = PageController();
  Timer? _bannerAutoPlayTimer;
  int _currentBannerIndex = 0;
  static const String _kPrefsHideFreeLicenseWelcomeDialog =
      'hide_free_license_welcome_dialog_v1';

  Future<void> _handleMainMenuAction(String value) async {
    switch (value) {
      case 'settings':
        DesktopTabPage.onAddSetting();
        break;
      case 'account':
        DesktopSettingPage.switch2page(SettingsTabKey.account);
        break;
      case 'backup':
        DesktopSettingPage.switch2page(SettingsTabKey.backup);
        break;
      case 'license':
        DesktopSettingPage.switch2page(SettingsTabKey.license);
        break;
      case 'buy-pro':
        await launchUrl(Uri.parse(kBuyNowUrl));
        break;
    }
  }

  /// Temporary: trigger agent heartbeat immediately (Windows agent testing).
  Widget _buildForceHeartbeatRow() {
    return Padding(
      padding: const EdgeInsets.only(right: 12, left: 4, top: 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () async {
            await AgentHeartbeatManager.instance.sendHeartbeat(force: true);
            BotToast.showText(text: 'Heartbeat sent');
          },
          icon: const Icon(Icons.sync, size: 16),
          label: const Text('Force Heartbeat Now'),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: Colors.blueGrey,
          ),
        ),
      ),
    );
  }

  List<String> get _activeBannerUrls =>
      _bannerHasLicense.value ? _licensedBannerUrls : _unlicensedBannerUrls;

  @override
  void initState() {
    super.initState();
    _allPeersLoader.init(setState);
    _idFocusNode.addListener(onFocusChanged);
    if (_idController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lastRemoteId = await bind.mainGetLastRemoteId();
        if (lastRemoteId != _idController.id) {
          setState(() {
            _idController.id = lastRemoteId;
          });
        }
      });
    }
    Get.put<TextEditingController>(_idEditingController);
    Get.put<IDTextEditingController>(_idController);
    windowManager.addListener(this);
    _refreshBannerLicenseState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowFreeLicenseWelcomeDialog());
    });
  }

  bool _isHebrewUi() {
    final lang = bind.mainGetLocalOption(key: kCommConfKeyLang).trim();
    return lang.toLowerCase().startsWith('he');
  }

  Future<void> _maybeShowFreeLicenseWelcomeDialog() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kPrefsHideFreeLicenseWelcomeDialog) == true) return;
    final savedLicense = (await getSavedLicenseKey())?.trim() ?? '';
    if (savedLicense.isNotEmpty) return;
    if (!mounted) return;
    await _showFreeLicenseWelcomeDialog();
  }

  Future<void> _showFreeLicenseWelcomeDialog() async {
    if (!mounted) return;
    final he = _isHebrewUi();
    var dontShowAgain = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final titleStyle = theme.textTheme.headlineSmall?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w900,
          height: 1.2,
        );
        final bodyStyle = theme.textTheme.bodyLarge?.copyWith(
          fontSize: 19,
          height: 1.5,
          fontWeight: FontWeight.w600,
        );
        final smallStyle = theme.textTheme.bodyMedium?.copyWith(
          fontSize: 15,
          color: theme.colorScheme.onSurfaceVariant,
          decoration: TextDecoration.underline,
        );
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Text(
              he
                  ? 'המעבדה הניידת שלכם מוכנה! 💻'
                  : 'Your Portable Lab Is Ready! 💻',
              textDirection: he ? TextDirection.rtl : TextDirection.ltr,
              style: titleStyle,
            ),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment:
                      he ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(
                      he
                          ? 'קחו שליטה מלאה על המחשבים שלכם בחינם. איך מתחילים?'
                          : 'Take full control of your computers for free. How to start?',
                      textDirection: he ? TextDirection.rtl : TextDirection.ltr,
                      style: bodyStyle,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      he
                          ? '🔑 משיגים קוד: נרשמים באתר ומקבלים קוד רישיון SD-FREE באזור האישי.'
                          : '🔑 Get a code: Register on the website and receive an SD-FREE license code in your account area.',
                      textDirection: he ? TextDirection.rtl : TextDirection.ltr,
                      style: bodyStyle,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      he
                          ? '🚀 מפעילים את התוכנה: מזינים את הקוד כאן ומתחברים לחשבון שלכם.'
                          : '🚀 Activate the software: Enter the code here and connect your account.',
                      textDirection: he ? TextDirection.rtl : TextDirection.ltr,
                      style: bodyStyle,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      he
                          ? '🎁 מקבלים בונוס: נהנים מ-30 יום פתיחה מלאה של כל כלי ה-PRO שלנו במתנה!'
                          : '🎁 Get a bonus: Enjoy 30 days of full access to all PRO tools for free!',
                      textDirection: he ? TextDirection.rtl : TextDirection.ltr,
                      style: bodyStyle,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      translate('sdfree-trial-post-end-body'),
                      textDirection: he ? TextDirection.rtl : TextDirection.ltr,
                      style: bodyStyle,
                    ),
                    const SizedBox(height: 16),
                    CheckboxListTile(
                      value: dontShowAgain,
                      onChanged: (v) =>
                          setLocal(() => dontShowAgain = v == true),
                      title: Text(
                        he ? 'אל תציג יותר' : 'Do not show again',
                        textDirection:
                            he ? TextDirection.rtl : TextDirection.ltr,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                      controlAffinity: he
                          ? ListTileControlAffinity.trailing
                          : ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
            ),
            actionsAlignment: he
                ? MainAxisAlignment.spaceBetween
                : MainAxisAlignment.spaceBetween,
            actions: [
              TextButton(
                onPressed: () async {
                  if (dontShowAgain) {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(
                        _kPrefsHideFreeLicenseWelcomeDialog, true);
                  }
                  if (!mounted) return;
                  Navigator.of(ctx).pop();
                },
                child: Text(
                  he ? 'מאוחר יותר' : 'Later',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: () async {
                  if (dontShowAgain) {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(
                        _kPrefsHideFreeLicenseWelcomeDialog, true);
                  }
                  if (!mounted) return;
                  Navigator.of(ctx).pop();
                  DesktopSettingPage.switch2page(SettingsTabKey.license);
                },
                child: Text(
                  he
                      ? 'הבנתי, ברצוני להזין קוד רישיון עכשיו'
                      : 'Got it, I want to enter a license code now',
                  style: smallStyle,
                ),
              ),
              FilledButton(
                onPressed: () async {
                  if (dontShowAgain) {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(
                        _kPrefsHideFreeLicenseWelcomeDialog, true);
                  }
                  await launchUrl(
                    Uri.parse('https://seedesktop.com/my-account/'),
                    mode: LaunchMode.externalApplication,
                  );
                },
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                ),
                child: Text(
                  he
                      ? 'לקבלת רישיון חינם באתר'
                      : 'Get a Free License on the Website',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _idController.dispose();
    windowManager.removeListener(this);
    _allPeersLoader.clear();
    _idFocusNode.removeListener(onFocusChanged);
    _idFocusNode.dispose();
    _idEditingController.dispose();
    if (Get.isRegistered<IDTextEditingController>()) {
      Get.delete<IDTextEditingController>();
    }
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    super.dispose();
  }

  @override
  void onWindowEvent(String eventName) {
    super.onWindowEvent(eventName);
    if (eventName == 'minimize') {
      isWindowMinimized = true;
    } else if (eventName == 'maximize' || eventName == 'restore') {
      if (isWindowMinimized && isWindows) {
        // windows can't update when minimized.
        Get.forceAppUpdate();
      }
      isWindowMinimized = false;
    }
  }

  @override
  void onWindowEnterFullScreen() {
    // Remove edge border by setting the value to zero.
    stateGlobal.resizeEdgeSize.value = 0;
  }

  @override
  void onWindowLeaveFullScreen() {
    // Restore edge border to default edge size.
    stateGlobal.resizeEdgeSize.value = stateGlobal.isMaximized.isTrue
        ? kMaximizeEdgeSize
        : windowResizeEdgeSize;
  }

  @override
  void onWindowClose() {
    super.onWindowClose();
    bind.mainOnMainWindowClose();
  }

  void onFocusChanged() {
    _idInputFocused.value = _idFocusNode.hasFocus;
    if (_idFocusNode.hasFocus) {
      if (_allPeersLoader.needLoad) {
        _allPeersLoader.getAllPeers();
      }

      final textLength = _idEditingController.value.text.length;
      // Select all to facilitate removing text, just following the behavior of address input of chrome.
      _idEditingController.selection =
          TextSelection(baseOffset: 0, extentOffset: textLength);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInstall = _buildBottomInstallRow(context);
    return Obx(() {
      if (stateGlobal.compactHomeConnectionLayout.value) {
        return _buildCompactHomeLayout(context);
      }
      return _buildFullHomeLayout(context, bottomInstall);
    });
  }

  /// After title-bar restore: only Your Desktop + Control Remote Desktop, equal
  /// vertical halves, centered window (see [StateGlobal.compactHomeConnectionLayout]).
  Widget _buildCompactHomeLayout(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: _buildTopHeaderArea(context, compactHome: true),
          ),
        ),
      ],
    );
  }

  Widget _buildFullHomeLayout(BuildContext context, Widget? bottomInstall) {
    return LayoutBuilder(builder: (context, constraints) {
      final isStacked = constraints.maxWidth < 980;
      final topHeaderHeight = isStacked ? 350.0 : 180.0;
      final bannerHeight = _bannerHasLicense.value ||
              _bannerInSdFreeTrial.value ||
              stateGlobal.hideBottomNotificationBanner.value
          ? 0.0
          : _bottomBannerHeight;
      final installHeight = bottomInstall != null ? 40.0 : 0.0;
      final statusStripHeight =
          (isDesktop || isWebDesktop) && !bind.isOutgoingOnly()
              ? kConnectionStatusStripHeight
              : 0.0;
      final minPeerTabHeight = 200.0;

      final minRequiredHeight = topHeaderHeight +
          bannerHeight +
          installHeight +
          statusStripHeight +
          minPeerTabHeight;

      Widget content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              children: [
                _buildTopHeaderArea(context).marginOnly(top: 10),
                const SizedBox(height: 6),
                Divider().paddingOnly(right: 12),
                if (isDesktop && isWindows) _buildForceHeartbeatRow(),
                if (isDesktop) const SizedBox(height: 4),
                Expanded(
                  child: const PeerTabPage(),
                ),
              ],
            ).paddingOnly(left: 12.0),
          ),
          if (bottomInstall != null) const Divider(height: 1),
          if (bottomInstall != null) bottomInstall,
          _buildBottomNotificationBanner(),
          if ((isDesktop || isWebDesktop) && !bind.isOutgoingOnly())
            const ConnectionStatusStrip(),
        ],
      );

      if (constraints.maxHeight < minRequiredHeight) {
        return SingleChildScrollView(
          child: SizedBox(
            height: minRequiredHeight,
            child: content,
          ),
        );
      }

      return content;
    });
  }

  Widget _buildTopHeaderArea(BuildContext context, {bool compactHome = false}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final localPanel = _buildLocalAccessPanel(context);
        if (compactHome) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  child: localPanel,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildCenterConnectionMenus(context),
                  ],
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  child: _buildRemoteIDTextField(context, inlineMenus: false),
                ),
              ),
            ],
          );
        }
        if (constraints.maxWidth < 980) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildRemoteIDTextField(context, inlineMenus: false),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildCenterConnectionMenus(context),
                  ],
                ),
              ),
              localPanel,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
                child: _buildRemoteIDTextField(context, inlineMenus: false)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: _buildCenterConnectionMenus(context),
            ),
            Expanded(child: localPanel),
          ],
        );
      },
    );
  }

  Widget _buildLocalAccessPanel(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, _) {
          copyId() {
            Clipboard.setData(ClipboardData(text: model.serverId.text));
            showToast(translate("Copied"));
          }

          return Container(
            constraints: const BoxConstraints(
              minHeight: _topFrameMinHeight,
              maxHeight: _topFrameMinHeight,
            ),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: const BorderRadius.all(Radius.circular(13)),
              border: Border.all(color: _frameLightGray),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                getConnectionPageTitle(
                  context,
                  false,
                  titleKey: 'Your Desktop',
                  tooltipKey: 'your_desktop_id_tip',
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onDoubleTap: copyId,
                  child: Container(
                    height: _innerIdBoxHeight,
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      border: Border.all(color: _frameLightGray, width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          formatID(model.serverId.text),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.w600,
                            color: _numberRed,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 28.0,
                        child: ElevatedButton(
                          onPressed: copyId,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _numberRed,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Icon(Icons.copy, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget? _buildBottomInstallRow(BuildContext context) {
    final canInstall =
        isWindows && !bind.isDisableInstallation() && !bind.mainIsInstalled();
    if (!canInstall) return null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 34,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: MyTheme.button,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 4),
              ),
              onPressed: () async {
                await rustDeskWinManager.closeAllSubWindows();
                bind.mainGotoInstall();
              },
              child: Text(translate('Install')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNotificationBanner() {
    return Obx(() {
      if (stateGlobal.hideBottomNotificationBanner.value ||
          _bannerHasLicense.value ||
          _bannerInSdFreeTrial.value) {
        return const SizedBox.shrink();
      }
      return ListenableBuilder(
        listenable: upgradeMarketingEnabledNotifier,
        builder: (context, _) {
          if (!upgradeMarketingEnabledNotifier.value) {
            return const SizedBox.shrink();
          }
          return const PromoBannerCarousel(height: _bottomBannerHeight);
        },
      );
    });
  }

  String _cacheBustedUrl(String url, int ts) {
    final separator = url.contains('?') ? '&' : '?';
    return '$url${separator}t=$ts';
  }

  Widget _buildBannerImage(String url, int ts) {
    return ClipRect(
      child: SizedBox.expand(
        child: Image.network(
          url,
          alignment: Alignment.topLeft,
          fit: BoxFit.none,
          filterQuality: FilterQuality.none,
          errorBuilder: (_, __, ___) => Image.network(
            _cacheBustedUrl(_fallbackBannerUrl, ts),
            alignment: Alignment.topLeft,
            fit: BoxFit.none,
            filterQuality: FilterQuality.none,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  Future<void> _precacheBannerImages(int ts) async {
    if (!mounted) return;
    for (final url in _activeBannerUrls) {
      final imageUrl = _cacheBustedUrl(url, ts);
      try {
        await precacheImage(NetworkImage(imageUrl), context);
      } catch (_) {
        try {
          await precacheImage(
            NetworkImage(_cacheBustedUrl(_fallbackBannerUrl, ts)),
            context,
          );
        } catch (_) {}
      }
    }
  }

  void _startBannerAutoPlay() {
    _stopBannerAutoPlay();
    _bannerAutoPlayTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || stateGlobal.hideBottomNotificationBanner.value) return;
      _goToNextBanner();
    });
  }

  void _stopBannerAutoPlay() {
    _bannerAutoPlayTimer?.cancel();
    _bannerAutoPlayTimer = null;
  }

  void _goToNextBanner() {
    final urls = _activeBannerUrls;
    if (!_bannerPageController.hasClients || urls.length <= 1) return;
    final next = (_currentBannerIndex + 1) % urls.length;
    _goToBannerPage(next);
  }

  void _goToPreviousBanner() {
    final urls = _activeBannerUrls;
    if (!_bannerPageController.hasClients || urls.length <= 1) return;
    final prev = (_currentBannerIndex - 1 + urls.length) % urls.length;
    _goToBannerPage(prev);
  }

  void _goToBannerPage(int index) {
    _bannerPageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _openBannerLink() async {
    await launchUrl(
      Uri.parse('https://seedesktop.com'),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _refreshBannerLicenseState() async {
    final hasLicense = await hasProLicenseLocal();
    final trialRemainingMs = await getSdFreeOfferRemainingMs();
    final inSdFreeTrialPeriod = (trialRemainingMs ?? 0) > 0;
    if (!mounted) return;
    if (_bannerInSdFreeTrial.value != inSdFreeTrialPeriod) {
      _bannerInSdFreeTrial.value = inSdFreeTrialPeriod;
    }
    if (_bannerHasLicense.value != hasLicense) {
      _bannerHasLicense.value = hasLicense;
      _currentBannerIndex = 0;
      if (_bannerPageController.hasClients) {
        _bannerPageController.jumpToPage(0);
      }
      final ts = DateTime.now().millisecondsSinceEpoch;
      _bannerRefreshTs.value = ts;
      _precacheBannerImages(ts);
    }
  }

  /// Callback for the connect button.
  /// Connects to the selected peer.
  void onConnect(
      {bool isFileTransfer = false,
      bool isViewCamera = false,
      bool isTerminal = false}) async {
    await _refreshBannerLicenseState();
    var id = _idController.id;
    if (isTerminal) {
      clearEnvTerminalAdmin();
    }
    await connect(context, id,
        isFileTransfer: isFileTransfer,
        isViewCamera: isViewCamera,
        isTerminal: isTerminal);
    if (id.isNotEmpty) {
      _idController.clear();
      _idEditingController.clear();
    }
  }

  /// Hamburger (settings) menu — same actions as before; used in center gutter or inline.
  Widget _buildMainMenuIconButton(BuildContext context) {
    return Container(
      height: 28.0,
      width: 28.0,
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: PopupMenuButton<String>(
        tooltip: translate('Settings'),
        icon: const Icon(Icons.menu, size: 14),
        padding: EdgeInsets.zero,
        onSelected: _handleMainMenuAction,
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'settings',
            child: mainMenuPopupChild(translate('Settings')),
          ),
          if (!bind.isDisableAccount())
            PopupMenuItem(
              value: 'account',
              child: mainMenuPopupChild(translate('main-menu-log-in-account')),
            ),
          if (!bind.isDisableAccount() && isWindows)
            PopupMenuItem(
              value: 'backup',
              child: mainMenuPopupChild(translate('main-menu-backup-restore')),
            ),
          if (!bind.isDisableAccount())
            PopupMenuItem(
              value: 'license',
              child: mainMenuPopupChild(translate('main-menu-license-manager')),
            ),
          PopupMenuItem(
            value: 'buy-pro',
            child: mainMenuPopupChild(translate('main-menu-buy-pro')),
          ),
        ],
      ),
    );
  }

  /// «More» actions (file transfer, camera, terminal, printer) — PRO gated as before.
  Widget _buildMoreActionsMenuButton(BuildContext context) {
    return Container(
      height: 28.0,
      width: 28.0,
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: StatefulBuilder(
          builder: (context, setState) {
            var offset = Offset(0, 0);
            return Obx(() => InkWell(
                  child: _menuOpen.value
                      ? Transform.rotate(
                          angle: pi,
                          child: Icon(IconFont.more, size: 14),
                        )
                      : Icon(IconFont.more, size: 14),
                  onTapDown: (e) {
                    offset = e.globalPosition;
                  },
                  onTap: () async {
                    if (!await hasProLicenseLocal()) {
                      if (context.mounted) {
                        await showPremiumPaywallDialog(context);
                      }
                      return;
                    }
                    _menuOpen.value = true;
                    final x = offset.dx;
                    final y = offset.dy;
                    final remotePrintingEnabled = option2bool(
                      kOptionEnableRemotePrinter,
                      bind.mainGetLocalOption(key: kOptionEnableRemotePrinter),
                    );
                    await mod_menu
                        .showMenu(
                      context: context,
                      position: RelativeRect.fromLTRB(x, y, x, y),
                      items: [
                        MenuEntryButton<String>(
                          childBuilder: (TextStyle? style) =>
                              mainMenuPopupChild(
                            translate('Transfer file'),
                            style: style,
                          ),
                          proc: () => onConnect(isFileTransfer: true),
                          padding: EdgeInsets.symmetric(
                              horizontal: kDesktopMenuPadding.left),
                          dismissOnClicked: true,
                        ),
                        MenuEntryButton<String>(
                          childBuilder: (TextStyle? style) =>
                              mainMenuPopupChild(
                            translate('View camera'),
                            style: style,
                          ),
                          proc: () => onConnect(isViewCamera: true),
                          padding: EdgeInsets.symmetric(
                              horizontal: kDesktopMenuPadding.left),
                          dismissOnClicked: true,
                        ),
                        MenuEntryButton<String>(
                          childBuilder: (TextStyle? style) =>
                              mainMenuPopupChild(
                            '${translate('Terminal')} (beta)',
                            style: style,
                          ),
                          proc: () => onConnect(isTerminal: true),
                          padding: EdgeInsets.symmetric(
                              horizontal: kDesktopMenuPadding.left),
                          dismissOnClicked: true,
                        ),
                        MenuEntryDivider<String>(),
                        MenuEntryButton<String>(
                          childBuilder: (TextStyle? style) {
                            return mainMenuPopupChild(
                              '${remotePrintingEnabled ? '☑' : '☐'} ${translate('remote-printing-toggle-label')}',
                              style: style,
                            );
                          },
                          proc: () async {
                            final next = !remotePrintingEnabled;
                            await bind.mainSetLocalOption(
                              key: kOptionEnableRemotePrinter,
                              value:
                                  bool2option(kOptionEnableRemotePrinter, next),
                            );
                            showToast(translate('Successful'));
                          },
                          padding: EdgeInsets.symmetric(
                              horizontal: kDesktopMenuPadding.left),
                          dismissOnClicked: true,
                        ),
                      ]
                          .map((e) => e.build(
                              context,
                              const MenuConfig(
                                commonColor: CustomPopupMenuTheme.commonColor,
                                height: CustomPopupMenuTheme.height,
                                dividerHeight:
                                    CustomPopupMenuTheme.dividerHeight,
                              )))
                          .expand((i) => i)
                          .toList(),
                      elevation: 8,
                    )
                        .then((_) {
                      _menuOpen.value = false;
                    });
                  },
                ));
          },
        ),
      ),
    );
  }

  /// Stacked vertically between «Control Remote» and «Your Desktop» (wide) or between sections (narrow).
  Widget _buildCenterConnectionMenus(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildMainMenuIconButton(context),
        const SizedBox(height: 10),
        Obx(() => _bannerHasLicense.value
            ? _buildMoreActionsMenuButton(context)
            : const SizedBox.shrink()),
      ],
    );
  }

  /// UI for the remote ID TextField.
  /// [inlineMenus] — if true, keeps hamburger + more next to Connect (rare); default false (menus in center).
  Widget _buildRemoteIDTextField(BuildContext context,
      {bool inlineMenus = false}) {
    var w = Container(
      width: double.infinity,
      constraints: const BoxConstraints(
        minHeight: _topFrameMinHeight,
        maxHeight: _topFrameMinHeight,
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(13)),
          border: Border.all(color: _frameLightGray)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          getConnectionPageTitle(
            context,
            false,
            tooltipKey: 'remote_id_tip',
          ).marginOnly(bottom: 8),
          Container(
            height: _innerIdBoxHeight,
            decoration: BoxDecoration(
              color: Colors.transparent,
              border: Border.all(color: _frameLightGray, width: 2),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                    child: RawAutocomplete<Peer>(
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    if (textEditingValue.text == '') {
                      _autocompleteOpts = const Iterable<Peer>.empty();
                    } else if (_allPeersLoader.peers.isEmpty &&
                        !_allPeersLoader.isPeersLoaded) {
                      Peer emptyPeer = Peer(
                        id: '',
                        username: '',
                        hostname: '',
                        alias: '',
                        platform: '',
                        tags: [],
                        hash: '',
                        password: '',
                        forceAlwaysRelay: false,
                        rdpPort: '',
                        rdpUsername: '',
                        loginName: '',
                        device_group_name: '',
                        note: '',
                        previewPath: '',
                      );
                      _autocompleteOpts = [emptyPeer];
                    } else {
                      String textWithoutSpaces =
                          textEditingValue.text.replaceAll(" ", "");
                      if (int.tryParse(textWithoutSpaces) != null) {
                        textEditingValue = TextEditingValue(
                          text: textWithoutSpaces,
                          selection: textEditingValue.selection,
                        );
                      }
                      String textToFind = textEditingValue.text.toLowerCase();
                      _autocompleteOpts = _allPeersLoader.peers
                          .where((peer) =>
                              peer.id.toLowerCase().contains(textToFind) ||
                              peer.username
                                  .toLowerCase()
                                  .contains(textToFind) ||
                              peer.hostname
                                  .toLowerCase()
                                  .contains(textToFind) ||
                              peer.alias.toLowerCase().contains(textToFind))
                          .toList();
                    }
                    return _autocompleteOpts;
                  },
                  focusNode: _idFocusNode,
                  textEditingController: _idEditingController,
                  fieldViewBuilder: (
                    BuildContext context,
                    TextEditingController fieldTextEditingController,
                    FocusNode fieldFocusNode,
                    VoidCallback onFieldSubmitted,
                  ) {
                    updateTextAndPreserveSelection(
                        fieldTextEditingController, _idController.text);
                    return Obx(() => TextField(
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.visiblePassword,
                          focusNode: fieldFocusNode,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 48,
                            height: 1.0,
                            fontWeight: FontWeight.w600,
                            color: MyTheme.accent,
                          ),
                          maxLines: 1,
                          cursorColor:
                              Theme.of(context).textTheme.titleLarge?.color,
                          decoration: InputDecoration(
                              filled: false,
                              counterText: '',
                              isDense: true,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              hintText: _idInputFocused.value
                                  ? null
                                  : translate('Enter Remote ID'),
                              hintStyle: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                color: Theme.of(context).hintColor,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 20)),
                          controller: fieldTextEditingController,
                          inputFormatters: [IDTextInputFormatter()],
                          onChanged: (v) {
                            _idController.id = v;
                          },
                          onSubmitted: (_) {
                            onConnect();
                          },
                        ).workaroundFreezeLinuxMint());
                  },
                  onSelected: (option) {
                    setState(() {
                      _idController.id = option.id;
                      FocusScope.of(context).unfocus();
                    });
                  },
                  optionsViewBuilder: (BuildContext context,
                      AutocompleteOnSelected<Peer> onSelected,
                      Iterable<Peer> options) {
                    options = _autocompleteOpts;
                    double maxHeight = options.length * 50;
                    if (options.length == 1) {
                      maxHeight = 52;
                    } else if (options.length == 3) {
                      maxHeight = 146;
                    } else if (options.length == 4) {
                      maxHeight = 193;
                    }
                    maxHeight = maxHeight.clamp(0, 200);

                    return Align(
                      alignment: Alignment.topLeft,
                      child: Container(
                          decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 5,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                              borderRadius: BorderRadius.circular(5),
                              child: Material(
                                elevation: 4,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: maxHeight,
                                    maxWidth: 600,
                                  ),
                                  child: _allPeersLoader.peers.isEmpty &&
                                          !_allPeersLoader.isPeersLoaded
                                      ? Container(
                                          height: 80,
                                          child: Center(
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ))
                                      : Padding(
                                          padding:
                                              const EdgeInsets.only(top: 5),
                                          child: ListView(
                                            children: options
                                                .map((peer) =>
                                                    AutocompletePeerTile(
                                                        onSelect: () =>
                                                            onSelected(peer),
                                                        peer: peer))
                                                .toList(),
                                          ),
                                        ),
                                ),
                              ))),
                    );
                  },
                )),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (inlineMenus) ...[
                  _buildMainMenuIconButton(context),
                  const SizedBox(width: 8),
                  Obx(() => _bannerHasLicense.value
                      ? _buildMoreActionsMenuButton(context)
                      : const SizedBox.shrink()),
                  const SizedBox(width: 8),
                ],
                SizedBox(
                  height: 28.0,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: MyTheme.button,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      onConnect();
                    },
                    child: Text(translate("Connect")),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return w;
  }
}
