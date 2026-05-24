/// Web / non-IO: SeeDesktop Cleanup settings live on Windows only.
class LocalCleanupStorage {
  static Future<Map<String, dynamic>> loadMerged() async =>
      <String, dynamic>{};

  static Future<void> save(Map<String, dynamic> data) async {}

  static String? readLastLog() => null;

  static String cleanupExePath() => '';

  static Future<int> runAutoCleanupDetached() async => -1;
}
