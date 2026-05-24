import 'dart:io';

/// DNS resolution probe — quick check before failing over to backup API.
Future<bool> licenseHasInternetConnectivity() async {
  try {
    final r = await InternetAddress.lookup(
      'connectivitycheck.gstatic.com',
    ).timeout(const Duration(seconds: 3));
    return r.isNotEmpty;
  } catch (_) {
    try {
      final r2 =
          await InternetAddress.lookup('google.com').timeout(const Duration(seconds: 3));
      return r2.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
