import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/admin_settings_service.dart';
import 'package:flutter_hbb/utils/license_api_router.dart';
import 'package:flutter_hbb/utils/license_manager.dart';
import 'package:flutter_hbb/utils/sdfree_account_trial.dart';

String _tr(String key) => platformFFI.translate(key, localeName);

const String kPrefsShowUpgradePresentation = 'admin_show_upgrade_presentation';

/// When false, non‑Pro users skip the countdown dialog and the main window hides the promo carousel.
final ValueNotifier<bool> upgradeMarketingEnabledNotifier = ValueNotifier(true);

Future<void> loadUpgradeMarketingPref() async {
  final prefs = await SharedPreferences.getInstance();
  upgradeMarketingEnabledNotifier.value =
      prefs.getBool(kPrefsShowUpgradePresentation) ?? true;
}

Future<void> setUpgradeMarketingPref(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kPrefsShowUpgradePresentation, value);
  upgradeMarketingEnabledNotifier.value = value;
}

const String kFirstLaunchTimestampKey = 'first_launch_timestamp';
const int kFreemiumTrialDays = 14;
const int kFreemiumDelayEarlySeconds = 30;
const int kFreemiumDelayLateSeconds = 60;
const int kFreeSessionLimitSeconds = 1800;
const String kBuyNowUrl = 'https://seedesktop.com';
const Duration _kTempRmmCheckTimeout = Duration(seconds: 5);
const int _kTempRmmCacheMs = 15000;
// On a transient failure (timeout / network blip / non-200) keep the previous
// known value alive and re-poll sooner instead of flipping to "false". This
// guarantees the controlee stays on PRO-RMM throughout the session and does
// not briefly revert to its own license because of one bad request.
const int _kTempRmmErrorRetryMs = 5000;

bool _tempRmmCachedValue = false;
int _tempRmmCachedAtMs = 0;

Uri get _tempRmmEndpointUri =>
    Uri.parse('$kLicenseServerBaseUrl/get_temporary_rmm_inheritance');

/// Shown after license-related status text (settings + status strip).
const String kLicenseStatusWebsiteSuffix = ' • https://seedesktop.com';

/// Text without the trailing website suffix (for pairing with a tappable link).
String licenseStatusWithoutWebsiteSuffix(String full) {
  if (full.endsWith(kLicenseStatusWebsiteSuffix)) {
    return full.substring(0, full.length - kLicenseStatusWebsiteSuffix.length);
  }
  return full;
}

/// Only active PRO may select/copy the masked license display; FREE / unlicensed / grace / expired cannot.
Future<bool> shouldAllowLicenseDisplayCopyLocal() async {
  if (await isSdfreeProRmmTrialUnlocked()) return true;
  return await getLocalLicenseTier() == LocalLicenseTier.proActive;
}

enum LocalLicenseTier {
  unlicensed,
  free,
  proActive,
  proExpired,
}

DateTime? _parseSavedExpiryUtc(String rawValue) {
  var value = rawValue.trim();
  if (value.isEmpty) return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    value = '${value}T23:59:59';
  }
  if (value.contains(' ') && !value.contains('T')) {
    value = value.replaceFirst(' ', 'T');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

Future<LocalLicenseTier> getLocalLicenseTier() async {
  final prefs = await SharedPreferences.getInstance();
  final key = (await getSavedLicenseKey())?.trim() ?? '';
  if (key.isEmpty) {
    return LocalLicenseTier.unlicensed;
  }
  final upperKey = key.toUpperCase();
  if (upperKey.startsWith('SD-FREE-')) {
    return LocalLicenseTier.free;
  }
  if (!upperKey.startsWith('SD-')) {
    return LocalLicenseTier.unlicensed;
  }
  final graceStartMs = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (graceStartMs > 0) {
    final elapsed = DateTime.now().millisecondsSinceEpoch - graceStartMs;
    if (elapsed >= kLicenseGracePeriodMs) {
      await clearLicensePrefs();
      return LocalLicenseTier.unlicensed;
    }
    // During grace mode, behave like FREE (no 30-min forced disconnect).
    return LocalLicenseTier.free;
  }
  final isForcedExpired = prefs.getBool(kLicenseIsExpiredPrefsKey) ?? false;
  if (isForcedExpired) {
    return LocalLicenseTier.proExpired;
  }
  final expiryRaw = prefs.getString(kLicenseExpiryIsoPrefsKey)?.trim() ?? '';
  final expiry = _parseSavedExpiryUtc(expiryRaw);
  if (expiry == null) {
    // Keep active when backend marked the key valid but did not provide a parseable date.
    return LocalLicenseTier.proActive;
  }
  if (DateTime.now().isAfter(expiry)) {
    return LocalLicenseTier.proExpired;
  }
  return LocalLicenseTier.proActive;
}

Future<bool> hasValidLicenseLocal() async {
  final key = await getSavedLicenseKey();
  return key != null && key.trim().isNotEmpty;
}

Future<bool> isUnlicensedLocal() async {
  return (await getLocalLicenseTier()) == LocalLicenseTier.unlicensed;
}

Future<bool> isFreeTierLicenseLocal() async {
  return (await getLocalLicenseTier()) == LocalLicenseTier.free;
}

/// True only for **SD-FREE-*** keys (not grace / other free-tier behaviour).
Future<bool> hasSdfreeLicenseLocal() async {
  final key = (await getSavedLicenseKey())?.trim().toUpperCase() ?? '';
  return key.startsWith('SD-FREE-');
}

Future<bool> isExpiredProLicenseLocal() async {
  return (await getLocalLicenseTier()) == LocalLicenseTier.proExpired;
}

void _markTempRmmCheckFailedSoftly(int now) {
  // Re-poll sooner than the success TTL while keeping the last good value.
  final softCachedAt = now - _kTempRmmCacheMs + _kTempRmmErrorRetryMs;
  _tempRmmCachedAtMs = softCachedAt < 0 ? 0 : softCachedAt;
}

Future<bool> _hasTemporaryRmmInheritanceLocal() async {
  if (kIsWeb) return false;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - _tempRmmCachedAtMs <= _kTempRmmCacheMs) {
    return _tempRmmCachedValue;
  }
  try {
    final myId = (await bind.mainGetMyId()).trim();
    if (myId.isEmpty) {
      _markTempRmmCheckFailedSoftly(now);
      return _tempRmmCachedValue;
    }
    final res = await LicenseApiRouter.post(
      _tempRmmEndpointUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'peer_id': myId}),
      requestTimeout: _kTempRmmCheckTimeout,
    );
    if (res.statusCode != 200) {
      _markTempRmmCheckFailedSoftly(now);
      return _tempRmmCachedValue;
    }
    final m = jsonDecode(res.body);
    final ok = m is Map && m['effective_rmm'] == true;
    _tempRmmCachedValue = ok;
    _tempRmmCachedAtMs = now;
    return ok;
  } catch (_) {
    _markTempRmmCheckFailedSoftly(now);
    return _tempRmmCachedValue;
  }
}

Future<bool> hasProLicenseLocal() async {
  if (await isSdfreeProRmmTrialUnlocked()) return true;
  if ((await getLocalLicenseTier()) == LocalLicenseTier.proActive) return true;
  return await _hasTemporaryRmmInheritanceLocal();
}

/// Cloud Contacts tab/API — PRO only (blocks unlicensed and SD-FREE keys).
Future<bool> canUseCloudContactsLocal() => hasProLicenseLocal();

/// True only for **SD-PRORMM-*** keys.
Future<bool> hasRmmLicenseLocal() async {
  if (await isSdfreeProRmmTrialUnlocked()) return true;
  final key = (await getSavedLicenseKey())?.trim().toUpperCase() ?? '';
  if (key.startsWith('SD-PRORMM-')) return true;
  return await _hasTemporaryRmmInheritanceLocal();
}

/// **Pro-RMM tier only** — saved license key starts with `SD-PRORMM-`.
/// Used for UI that must not appear for FREE / unlicensed / SD-PRO-only agents.
/// Does not use trial-unlock shortcuts so visibility matches the product key on disk.
Future<bool> isProRmmLicenseKeyPresentLocal() async {
  final key = (await getSavedLicenseKey())?.trim().toUpperCase() ?? '';
  return key.startsWith('SD-PRORMM-');
}

/// Eligibility gate for RMM IT troubleshooting chat visibility/usage.
/// - Active for real `SD-PRORMM-*` keys.
/// - Also active for `SD-FREE-*` while the 30-day Pro-RMM trial unlock is valid.
Future<bool> canUseRmmItTroubleshootingChatLocal() async {
  if (await isProRmmLicenseKeyPresentLocal()) return true;
  if (await isSdfreeProRmmTrialUnlocked()) return true;
  return await _hasTemporaryRmmInheritanceLocal();
}

/// Canonical tier string for VPS (`license_tier` column) sent on agent heartbeat.
/// - **`pro-rmm`** — saved key starts with `SD-PRORMM-`.
/// - **`pro`** — active paid PRO-class license (non–PRORMM key, [LocalLicenseTier.proActive]).
/// - **`free`** — unlicensed, `SD-FREE-*`, grace window, or expired PRO.
Future<String> licenseTierForHeartbeatPayload() async {
  if (await isProRmmLicenseKeyPresentLocal()) {
    return 'pro-rmm';
  }
  final tier = await getLocalLicenseTier();
  if (tier == LocalLicenseTier.proActive) {
    return 'pro';
  }
  return 'free';
}

/// Backward-compatible helper: RMM suite includes all PRO capabilities.
Future<bool> hasProOrRmmLicenseLocal() async {
  return await hasProLicenseLocal() || await hasRmmLicenseLocal();
}

Future<bool> shouldEnforceThirtyMinuteTimeoutLocal() async {
  final tier = await getLocalLicenseTier();
  return tier == LocalLicenseTier.unlicensed ||
      tier == LocalLicenseTier.proExpired;
}

Future<int?> getProDaysUntilExpiryLocal() async {
  final prefs = await SharedPreferences.getInstance();
  final key = (await getSavedLicenseKey())?.trim() ?? '';
  if (key.isEmpty || key.toUpperCase().startsWith('SD-FREE-')) {
    return null;
  }
  final expiryRaw = prefs.getString(kLicenseExpiryIsoPrefsKey)?.trim() ?? '';
  final expiry = _parseSavedExpiryUtc(expiryRaw);
  if (expiry == null) return null;
  final now = DateTime.now();
  return expiry.difference(now).inDays;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

/// Same structure as Free / PRO lines (Licensed + Status + site link).
String unlicensedStatusDisplayLine() =>
    'Licensed: —  •  Status: Unlicensed (one remote session; PRO removes limits)$kLicenseStatusWebsiteSuffix';

Future<String?> getProRenewalDateDisplayLocal() async {
  final prefs = await SharedPreferences.getInstance();
  final key = (await getSavedLicenseKey())?.trim() ?? '';
  if (key.isEmpty || key.toUpperCase().startsWith('SD-FREE-')) {
    return null;
  }
  final expiryRaw = prefs.getString(kLicenseExpiryIsoPrefsKey)?.trim() ?? '';
  final expiry = _parseSavedExpiryUtc(expiryRaw);
  if (expiry == null) return null;
  return '${expiry.year}-${_twoDigits(expiry.month)}-${_twoDigits(expiry.day)} '
      '${_twoDigits(expiry.hour)}:${_twoDigits(expiry.minute)}';
}

Future<String> getLicenseStatusDisplayTextLocal(
    {int renewalWindowDays = 30}) async {
  final prefs = await SharedPreferences.getInstance();
  final savedLicense = (await getSavedLicenseKey())?.trim() ?? '';
  if (savedLicense.isEmpty) {
    return unlicensedStatusDisplayLine();
  }
  final graceStartMs = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (graceStartMs > 0) {
    final elapsed = DateTime.now().millisecondsSinceEpoch - graceStartMs;
    final remainingMs = kLicenseGracePeriodMs - elapsed;
    if (remainingMs <= 0) {
      return unlicensedStatusDisplayLine();
    }
    final remainingHours = (remainingMs / (60 * 60 * 1000)).ceil();
    return 'Licensed: ${maskLicense(savedLicense)}  •  '
        'Status: Temporary Free Mode (${remainingHours}h left)$kLicenseStatusWebsiteSuffix';
  }
  final base = 'Licensed: ${maskLicense(savedLicense)}';
  final tier = await getLocalLicenseTier();
  if (tier == LocalLicenseTier.proExpired) {
    return '$base  •  Status: PRO Expired - Running in Free Mode$kLicenseStatusWebsiteSuffix';
  }
  if (tier == LocalLicenseTier.proActive) {
    final days = await getProDaysUntilExpiryLocal();
    if (days != null && days <= renewalWindowDays) {
      final normalizedDays = days < 0 ? 0 : days;
      return '$base  •  Renew in $normalizedDays day${normalizedDays == 1 ? '' : 's'}$kLicenseStatusWebsiteSuffix';
    }
    return '$base$kLicenseStatusWebsiteSuffix';
  }
  if (tier == LocalLicenseTier.free) {
    if (await hasSdfreeLicenseLocal()) {
      await ensureSdFreeFirstSeenMigrated();
      final remaining = await getSdFreeOfferRemainingMs();
      if (remaining != null && remaining > 0) {
        final s = formatSdFreeTrialCountdownFromMs(remaining);
        if (await isSdfreeProRmmTrialUnlocked()) {
          return '$base  •  ${_tr('sdfree_trial_status_line_active').replaceAll('%s', s)}$kLicenseStatusWebsiteSuffix';
        }
        if (!isAccountConnectedForSdfreeTrial()) {
          return '$base  •  ${_tr('sdfree_trial_status_line_sign_in').replaceAll('%s', s)}$kLicenseStatusWebsiteSuffix';
        }
      }
    }
  }
  return '$base$kLicenseStatusWebsiteSuffix';
}

Future<int> ensureFirstLaunchTimestamp() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getInt(kFirstLaunchTimestampKey);
  if (existing != null && existing > 0) {
    return existing;
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  await prefs.setInt(kFirstLaunchTimestampKey, now);
  return now;
}

Future<bool> shouldAllowConnectionWithFreemiumGate(BuildContext context) async {
  if (await hasProLicenseLocal()) {
    return true;
  }
  // SD-FREE lifetime keys: no countdown promo before connect.
  if (await hasSdfreeLicenseLocal()) {
    return true;
  }

  if (!upgradeMarketingEnabledNotifier.value) {
    return true;
  }

  await AdminSettingsService.startSync();
  final adminDelaySeconds = AdminSettingsService.promoDelaySeconds;
  if (adminDelaySeconds <= 0) {
    return true;
  }

  final firstLaunch = await ensureFirstLaunchTimestamp();
  final firstLaunchDate = DateTime.fromMillisecondsSinceEpoch(firstLaunch);
  final daysPassed = DateTime.now().difference(firstLaunchDate).inDays;
  final fallbackDelaySeconds = daysPassed <= kFreemiumTrialDays
      ? kFreemiumDelayEarlySeconds
      : kFreemiumDelayLateSeconds;
  final delaySeconds =
      adminDelaySeconds > 0 ? adminDelaySeconds : fallbackDelaySeconds;

  return showFreemiumNagDialog(context, delaySeconds: delaySeconds);
}

Future<bool> showFreemiumNagDialog(BuildContext context,
    {required int delaySeconds}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: _FreemiumNagDialog(
        delaySeconds: delaySeconds,
        onComplete: () {
          if (Navigator.of(dialogContext, rootNavigator: true).canPop()) {
            Navigator.of(dialogContext, rootNavigator: true).pop(true);
          }
        },
      ),
    ),
  );
  return result == true;
}

Future<void> showConcurrentConnectionLicenseDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      title: Text(_tr('pro-concurrent-title')),
      content: Text(_tr('pro-concurrent-body')),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext, rootNavigator: true).pop(),
          child: Text(_tr('pro-concurrent-close')),
        ),
        ElevatedButton(
          onPressed: () {
            launchUrlString(kBuyNowUrl);
            Navigator.of(dialogContext, rootNavigator: true).pop();
          },
          child: Text(_tr('pro-concurrent-upgrade')),
        ),
      ],
    ),
  );
}

Future<void> showFreeTierSessionLimitDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: Color(0xFF0A6BFF)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _tr('session-limit-title'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F8FF),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _tr('session-limit-body'),
          style: const TextStyle(fontSize: 14.5, height: 1.35),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext, rootNavigator: true).pop(),
          child: Text(_tr('session-limit-cancel')),
        ),
        ElevatedButton(
          onPressed: () {
            launchUrlString(kBuyNowUrl);
            Navigator.of(dialogContext, rootNavigator: true).pop();
          },
          child: Text(_tr('session-limit-upgrade')),
        ),
      ],
    ),
  );
}

/// Returns true if the user confirms switching to [newPeerId] (current session to [currentPeerId] will end).
Future<bool> showFreeTierSwitchConnectionConfirmDialog(
  BuildContext context,
  String currentPeerId,
  String newPeerId,
) async {
  final oldFmt = formatID(currentPeerId);
  final newFmt = formatID(newPeerId);
  final body = _tr('free-switch-session-body')
      .replaceAll('{old}', oldFmt)
      .replaceAll('{new}', newFmt);
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.swap_horiz_rounded, color: Color(0xFF0A6BFF)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _tr('free-switch-session-title'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Text(
          body,
          style: const TextStyle(fontSize: 14.5, height: 1.4),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext, rootNavigator: true).pop(false),
          child: Text(_tr('free-switch-session-stay')),
        ),
        ElevatedButton(
          onPressed: () =>
              Navigator.of(dialogContext, rootNavigator: true).pop(true),
          child: Text(_tr('free-switch-session-switch')),
        ),
      ],
    ),
  );
  return result == true;
}

Future<void> showFreeSessionLimitReachedDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(_tr('free-session-expired-title')),
        content: Text(_tr('free-session-expired-body')),
        actions: [
          ElevatedButton(
            onPressed: () {
              launchUrlString(kBuyNowUrl);
            },
            child: Text(_tr('free-session-open-site')),
          ),
          TextButton(
            onPressed: () {
              if (Navigator.of(dialogContext, rootNavigator: true).canPop()) {
                Navigator.of(dialogContext, rootNavigator: true).pop();
              }
            },
            child: Text(_tr('free-session-ok')),
          ),
        ],
      ),
    ),
  );
}

class _FreemiumNagDialog extends StatefulWidget {
  final int delaySeconds;
  final VoidCallback onComplete;

  const _FreemiumNagDialog({
    required this.delaySeconds,
    required this.onComplete,
  });

  @override
  State<_FreemiumNagDialog> createState() => _FreemiumNagDialogState();
}

class _FreemiumNagDialogState extends State<_FreemiumNagDialog> {
  Timer? _countdownTimer;
  late int _remainingSeconds;
  bool _canConnect = false;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.delaySeconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_remainingSeconds > 1) {
        setState(() {
          _remainingSeconds -= 1;
        });
      } else {
        timer.cancel();
        setState(() {
          _remainingSeconds = 0;
          _canConnect = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.delaySeconds <= 0 ? 1 : widget.delaySeconds;
    final progress = 1 - (_remainingSeconds / total);
    final maxH = MediaQuery.sizeOf(context).height * 0.34;

    const featKeys = <String>[
      'promo-nag-feat-secure',
      'promo-nag-feat-print',
      'promo-nag-feat-unlim',
      'promo-nag-feat-files',
      'promo-nag-feat-ab',
    ];

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 480, maxHeight: maxH),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tr('promo-nag-title'),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _tr('promo-nag-sub'),
                        style: const TextStyle(
                            fontSize: 11.5, color: Colors.black87, height: 1.2),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF6F8FF),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _tr('promo-nag-regular'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 11,
                                color: Colors.grey,
                                decoration: TextDecoration.lineThrough,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _tr('promo-nag-deal'),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFB45309),
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _tr('promo-nag-includes'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 2),
                            for (final k in featKeys)
                              _FeatureItem(_tr(k), highlight: false),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () => launchUrlString(kBuyNowUrl),
                child: Text(_tr('promo-buy-now')),
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: progress.clamp(0, 1),
                minHeight: 3,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 3),
              Text(
                _canConnect
                    ? _tr('promo-countdown-done')
                    : _tr('promo-countdown-wait')
                        .replaceAll('{}', '$_remainingSeconds'),
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600, height: 1.2),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              OutlinedButton(
                onPressed: _canConnect ? widget.onComplete : null,
                child: Text(_tr('promo-connect')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final String text;
  final bool highlight;

  const _FeatureItem(this.text, {this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 12,
            color:
                highlight ? const Color(0xFFD97706) : const Color(0xFF0A6BFF),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 10,
                height: 1.15,
                fontWeight: highlight ? FontWeight.w800 : FontWeight.w500,
                color: highlight ? const Color(0xFF92400E) : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
