import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/account_title_bar_status.dart';
import 'package:flutter_hbb/desktop/widgets/see_desk_login_dialog.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';
import 'package:flutter_hbb/utils/license_api_router.dart';
import 'package:flutter_hbb/utils/license_manager.dart';
import 'package:flutter_hbb/utils/license_restart.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Full-width bottom status strip (desktop home), flush to window bottom.
/// Single line, max height [kConnectionStatusStripHeight].
const double kConnectionStatusStripHeight = 44;

class ConnectionStatusStrip extends StatefulWidget {
  const ConnectionStatusStrip({super.key});

  @override
  State<ConnectionStatusStrip> createState() => _ConnectionStatusStripState();
}

class _ConnectionStatusStripState extends State<ConnectionStatusStrip> {
  static const String _expectedKey =
      'KafXrl4RSnR62ccbm15Jk8kd7sBSYaW9JxSXbGw8224=';

  Timer? _timer;
  String _licenseStatusText = unlicensedStatusDisplayLine();
  bool _isExpiredProLicense = false;
  bool _allowLicenseDisplayCopy = false;
  bool _showBuyPro = false;

  late final TapGestureRecognizer _websiteTap = TapGestureRecognizer()
    ..onTap = () => launchUrlString(kBuyNowUrl);

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshStatus();
    });
  }

  @override
  void dispose() {
    _websiteTap.dispose();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
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
    } catch (_) {}

    final nextStatus = await getLicenseStatusDisplayTextLocal();
    final expiredPro = await isExpiredProLicenseLocal();
    final allowCopy = await shouldAllowLicenseDisplayCopyLocal();
    final nextShowBuyPro = nextStatus.toLowerCase().contains('free') ||
        nextStatus.toLowerCase().contains('unlicensed');
    if (mounted &&
        (nextStatus != _licenseStatusText ||
            expiredPro != _isExpiredProLicense ||
            allowCopy != _allowLicenseDisplayCopy ||
            nextShowBuyPro != _showBuyPro)) {
      setState(() {
        _licenseStatusText = nextStatus;
        _isExpiredProLicense = expiredPro;
        _allowLicenseDisplayCopy = allowCopy;
        _showBuyPro = nextShowBuyPro;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final color = theme.textTheme.bodyMedium?.color;
    final borderColor = theme.dividerColor;
    final barBg = theme.brightness == Brightness.dark
        ? colorScheme.surfaceContainerHighest.withOpacity(0.55)
        : Color.lerp(
              colorScheme.surfaceContainerHighest,
              colorScheme.surface,
              0.65,
            ) ??
            colorScheme.surfaceContainerHighest.withOpacity(0.4);

    return Material(
      color: barBg,
      elevation: 0,
      child: SizedBox(
        height: kConnectionStatusStripHeight,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: borderColor.withOpacity(0.9), width: 1),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: Image.asset(
                        'assets/see-desktop-tray.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ValueListenableBuilder<String>(
                        valueListenable: LicenseApiRouter.hostLabelNotifier,
                        builder: (context, apiLabel, _) {
                          return Obx(() {
                  final svc = stateGlobal.svcStatus.value;
                  final server = bind
                      .mainGetOptionSync(key: 'custom-rendezvous-server')
                      .trim();
                  final key = bind.mainGetOptionSync(key: 'key').trim();
                  final targetComputer =
                      bind.mainGetLocalOption(key: 'last_remote_id').trim();
                  final normalizedServer = server.toLowerCase();
                  final isSeedesktopHost =
                      normalizedServer.contains('seedesktop') ||
                          normalizedServer.contains('see-desk');
                  final isSeedesktopServer = server.isNotEmpty &&
                      (key == _expectedKey || isSeedesktopHost);
                  final isReady = svc == SvcStatus.ready;
                  final statusText = svc == SvcStatus.connecting
                      ? translate("connecting_status")
                      : svc == SvcStatus.notReady
                          ? translate("not_ready_status")
                          : (isSeedesktopServer
                              ? 'Ready - Connected to SeeDesktop'
                              : translate('Ready'));
                  final targetText = targetComputer.isNotEmpty
                      ? '  •  Target: $targetComputer'
                      : '';
                  final dotColor = svc == SvcStatus.connecting
                      ? kColorWarn
                      : (svc == SvcStatus.ready
                          ? const Color.fromARGB(255, 50, 190, 166)
                          : const Color.fromARGB(255, 224, 79, 95));
                  final licenseServerStatus =
                      LicenseHeartbeatManager.instance.status.value;
                  final showLicenseReconnectHint = isReady &&
                      isSeedesktopServer &&
                      licenseServerStatus == LicenseServerStatus.reconnecting;
                  final serverSuffix = showLicenseReconnectHint
                      ? '  •  Reconnecting license server'
                      : '';

                  final conn = '$statusText$targetText$serverSuffix';
                  final licMain =
                      licenseStatusWithoutWebsiteSuffix(_licenseStatusText);
                  final hasLink =
                      _licenseStatusText.endsWith(kLicenseStatusWebsiteSuffix);

                  const baseSize = 11.0;
                  final baseStyle = TextStyle(
                    fontSize: baseSize,
                    color: color,
                    height: 1.05,
                  );
                  final linkStyle = baseStyle.copyWith(
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                  );

                  final spans = <InlineSpan>[
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          color: dotColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    TextSpan(text: conn, style: baseStyle),
                    TextSpan(text: ' • ', style: baseStyle),
                    TextSpan(text: licMain, style: baseStyle),
                    TextSpan(text: ' • ', style: baseStyle),
                    TextSpan(
                      text: apiLabel,
                      style: baseStyle.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (hasLink)
                      TextSpan(
                        text: kLicenseStatusWebsiteSuffix,
                        style: linkStyle,
                        recognizer: _websiteTap,
                      ),
                  ];

                  Widget line = RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(children: spans),
                  );
                  if (!_allowLicenseDisplayCopy) {
                    line = SelectionContainer.disabled(child: line);
                  }

                  return line;
                });
                        },
                      ),
                    ),
                  ],
                ),
              ),
              if (!bind.isDisableAccount())
                const DesktopAccountStatusCenter(),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Obx(() {
                final svc = stateGlobal.svcStatus.value;
                final serviceOk = svc == SvcStatus.ready;
                final serviceLabel =
                    serviceOk ? 'Service: Running' : 'Service: Not running';
                final serviceColor = serviceOk
                    ? const Color(0xFF16A34A)
                    : const Color(0xFFDC2626);
                return Row(
                  children: [
                    Text(
                      serviceLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: serviceColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!serviceOk) ...[
                      const SizedBox(width: 4),
                      SizedBox(
                        height: 22,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFDC2626),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            visualDensity: VisualDensity.compact,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () async {
                            await start_service(true);
                            await _refreshStatus();
                          },
                          child: const Text(
                            'הפעל Service',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                  ],
                );
              }),
              if (_isExpiredProLicense) ...[
                SizedBox(
                  height: 22,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      visualDensity: VisualDensity.compact,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => launchUrlString(kBuyNowUrl),
                    child: const Text('Renew', style: TextStyle(fontSize: 11)),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  height: 22,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      visualDensity: VisualDensity.compact,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () async {
                      await refreshLicenseStatusFromServer();
                      BotToast.showText(text: 'License status refreshed.');
                      await restartSeeDesktopAfterLicenseChange();
                      await _refreshStatus();
                    },
                    child:
                        const Text('Refresh', style: TextStyle(fontSize: 11)),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              SizedBox(
                height: 22,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    visualDensity: VisualDensity.compact,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () async {
                    await showSeeDeskLoginDialog(context);
                    await _refreshStatus();
                  },
                  child: Text(
                    translate('Change License'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                height: 22,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    visualDensity: VisualDensity.compact,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () async {
                    final err = await releaseLicenseFullLogout();
                    await _refreshStatus();
                    BotToast.showText(text: err ?? 'Logged out of license.');
                    await reloadAllWindows();
                  },
                  child: const Text(
                    'Release',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ),
              if (_showBuyPro) ...[
                const SizedBox(width: 4),
                SizedBox(
                  height: 22,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      visualDensity: VisualDensity.compact,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => launchUrlString(kBuyNowUrl),
                    child:
                        const Text('Buy PRO', style: TextStyle(fontSize: 11)),
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
  }
}
