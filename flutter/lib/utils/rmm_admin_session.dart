import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kPrefsRmmScriptsUiVisible = 'admin_rmm_scripts_ui_visible';

/// When **true**, My Devices, Script Manager, the local RMM sidebar, and PowerShell
/// script entry points are shown for everyone on this machine.
/// When **false**, they stay hidden for all users until an admin enables them in
/// Settings → Admin (after password).
///
/// Persisted in [SharedPreferences]. Default when unset: **false** (hidden).
final ValueNotifier<bool> rmmScriptsUiVisibleNotifier = ValueNotifier<bool>(false);

Future<void> loadRmmScriptsUiPref() async {
  final prefs = await SharedPreferences.getInstance();
  rmmScriptsUiVisibleNotifier.value =
      prefs.getBool(kPrefsRmmScriptsUiVisible) ?? false;
}

Future<void> setRmmScriptsUiVisible(bool visible) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kPrefsRmmScriptsUiVisible, visible);
  rmmScriptsUiVisibleNotifier.value = visible;
}
