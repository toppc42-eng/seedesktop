import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_hbb/common.dart' show gFFI;
import 'package:flutter_hbb/utils/cloud_sync_service.dart';
import 'package:flutter_hbb/utils/license_manager.dart' show getSavedLicenseKey;

const String kSdFreeTrialKeyPrefs = 'sd_free_trial_key_for_clock';
const String kSdFreeTrialFirstSeenMs = 'sd_free_trial_first_seen_ms';
const int kSdFreeProTrialDurationMs = 30 * 24 * 60 * 60 * 1000;

/// True when either cloud OTP session or hbbs account is present (same idea as [DesktopAccountStatusStrip]).
bool isAccountConnectedForSdfreeTrial() {
  if (CloudSyncService.hasToken) return true;
  if (gFFI.userModel.userName.value.trim().isNotEmpty) return true;
  return false;
}

/// After [saveLicenseToPrefs]: record 30-day window start from first time this SD-FREE key is bound.
Future<void> recordSdFreeKeyOnLicenseSave(
    String previousKeyTrimmed, String nextKeyTrimmed) async {
  final n = nextKeyTrimmed.trim();
  final upper = n.toUpperCase();
  final prefs = await SharedPreferences.getInstance();
  if (!upper.startsWith('SD-FREE-')) {
    await prefs.remove(kSdFreeTrialKeyPrefs);
    await prefs.remove(kSdFreeTrialFirstSeenMs);
    return;
  }
  final storedKey = (prefs.getString(kSdFreeTrialKeyPrefs) ?? '').trim();
  if (n == storedKey) {
    if ((prefs.getInt(kSdFreeTrialFirstSeenMs) ?? 0) <= 0) {
      await prefs.setInt(
          kSdFreeTrialFirstSeenMs, DateTime.now().millisecondsSinceEpoch);
    }
    return;
  }
  await prefs.setString(kSdFreeTrialKeyPrefs, n);
  await prefs.setInt(
      kSdFreeTrialFirstSeenMs, DateTime.now().millisecondsSinceEpoch);
}

/// If an SD-FREE license exists but no trial clock yet (e.g. upgrade from older build), start now.
Future<void> ensureSdFreeFirstSeenMigrated() async {
  final prefs = await SharedPreferences.getInstance();
  final license = (await getSavedLicenseKey())?.trim() ?? '';
  if (!license.toUpperCase().startsWith('SD-FREE-')) return;
  final storedKey = (prefs.getString(kSdFreeTrialKeyPrefs) ?? '').trim();
  final first = prefs.getInt(kSdFreeTrialFirstSeenMs) ?? 0;
  if (storedKey.isEmpty && first <= 0) {
    await prefs.setString(kSdFreeTrialKeyPrefs, license);
    await prefs.setInt(
        kSdFreeTrialFirstSeenMs, DateTime.now().millisecondsSinceEpoch);
  } else if (license == storedKey && first <= 0) {
    await prefs.setInt(
        kSdFreeTrialFirstSeenMs, DateTime.now().millisecondsSinceEpoch);
  }
}

Future<void> clearSdFreeAccountTrialPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(kSdFreeTrialKeyPrefs);
  await prefs.remove(kSdFreeTrialFirstSeenMs);
}

int? _firstSeenMs(SharedPreferences prefs) {
  final v = prefs.getInt(kSdFreeTrialFirstSeenMs) ?? 0;
  if (v <= 0) return null;
  return v;
}

/// Pro + RMM features: SD-FREE key, account connected, and within 30 days of first-seen for this key.
Future<bool> isSdfreeProRmmTrialUnlocked() async {
  final key = (await getSavedLicenseKey())?.trim().toUpperCase() ?? '';
  if (!key.startsWith('SD-FREE-')) return false;
  await ensureSdFreeFirstSeenMigrated();
  final first = _firstSeenMs(await SharedPreferences.getInstance());
  if (first == null) return false;
  if (DateTime.now().millisecondsSinceEpoch >=
      first + kSdFreeProTrialDurationMs) {
    return false;
  }
  if (!isAccountConnectedForSdfreeTrial()) return false;
  return true;
}

/// Remaining ms until 30-day offer ends (from first-seen), or null if not applicable.
Future<int?> getSdFreeOfferRemainingMs() async {
  final key = (await getSavedLicenseKey())?.trim().toUpperCase() ?? '';
  if (!key.startsWith('SD-FREE-')) return null;
  await ensureSdFreeFirstSeenMigrated();
  final p2 = await SharedPreferences.getInstance();
  final first = _firstSeenMs(p2);
  if (first == null) return null;
  final end = first + kSdFreeProTrialDurationMs;
  final left = end - DateTime.now().millisecondsSinceEpoch;
  return left <= 0 ? 0 : left;
}

String formatSdFreeTrialCountdownFromMs(int remainingMs) {
  var left = remainingMs;
  if (left < 0) left = 0;
  final totalMin = (left + 59999) ~/ 60000;
  final d = totalMin ~/ (24 * 60);
  final h = (totalMin % (24 * 60)) ~/ 60;
  final m = totalMin % 60;
  return '${d}d ${h}h ${m}m';
}
