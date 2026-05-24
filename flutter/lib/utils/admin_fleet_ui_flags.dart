import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kPrefsFleetShowMyScripts = 'fleet_show_my_scripts';
const String kPrefsFleetShowPsCatalog = 'fleet_show_ps_catalog';
const String kPrefsFleetShowUserDashboard = 'fleet_show_user_dashboard';
const String kPrefsLocalMenuEditor = 'local_menu_editor_enabled';

/// Fleet policy from `settings.json` (first three admin toggles). Default **true** if unset.
final ValueNotifier<bool> showMyScriptsFleetNotifier = ValueNotifier<bool>(true);
final ValueNotifier<bool> showPsCatalogFleetNotifier = ValueNotifier<bool>(true);
final ValueNotifier<bool> showUserDashboardFleetNotifier = ValueNotifier<bool>(true);

/// Local-only: enable tab visibility context menu (this machine).
final ValueNotifier<bool> localMenuEditorEnabledNotifier =
    ValueNotifier<bool>(false);

Future<void> loadAdminFleetUiPrefs() async {
  final p = await SharedPreferences.getInstance();
  showMyScriptsFleetNotifier.value = p.getBool(kPrefsFleetShowMyScripts) ?? true;
  showPsCatalogFleetNotifier.value = p.getBool(kPrefsFleetShowPsCatalog) ?? true;
  showUserDashboardFleetNotifier.value =
      p.getBool(kPrefsFleetShowUserDashboard) ?? true;
  localMenuEditorEnabledNotifier.value =
      p.getBool(kPrefsLocalMenuEditor) ?? false;
}

Future<void> setShowMyScriptsFleet(bool v) async {
  final p = await SharedPreferences.getInstance();
  await p.setBool(kPrefsFleetShowMyScripts, v);
  showMyScriptsFleetNotifier.value = v;
}

Future<void> setShowPsCatalogFleet(bool v) async {
  final p = await SharedPreferences.getInstance();
  await p.setBool(kPrefsFleetShowPsCatalog, v);
  showPsCatalogFleetNotifier.value = v;
}

Future<void> setShowUserDashboardFleet(bool v) async {
  final p = await SharedPreferences.getInstance();
  await p.setBool(kPrefsFleetShowUserDashboard, v);
  showUserDashboardFleetNotifier.value = v;
}

Future<void> setLocalMenuEditorEnabled(bool v) async {
  final p = await SharedPreferences.getInstance();
  await p.setBool(kPrefsLocalMenuEditor, v);
  localMenuEditorEnabledNotifier.value = v;
}
