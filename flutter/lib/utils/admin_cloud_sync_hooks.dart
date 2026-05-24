/// Registered from [main] (desktop) so [AdminSettingsService] can apply fleet-wide
/// policy from `settings.json` without importing freemium / RMM UI modules (cycles).
class AdminCloudSyncHooks {
  static Future<void> Function(bool value)? onRmmScriptsUiVisible;
  static Future<void> Function(bool value)? onUpgradeMarketingVisible;
}
