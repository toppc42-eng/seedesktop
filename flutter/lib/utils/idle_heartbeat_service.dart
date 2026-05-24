import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/license_api_router.dart';

/// Periodic global presence for the VPS (`/api/global_heartbeat`).
/// Runs regardless of license, login, or active remote sessions.
class IdleHeartbeatService {
  IdleHeartbeatService._();
  static final IdleHeartbeatService instance = IdleHeartbeatService._();

  static final Uri _endpoint =
      Uri.parse('https://api.seedesktop.com/api/global_heartbeat');

  Timer? _timer;
  bool _tickInFlight = false;
  static const Duration _period = Duration(seconds: 120);

  /// One timer per Dart isolate; safe to call multiple times.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_period, (_) => unawaited(_tick()));
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_tickInFlight) return;
    _tickInFlight = true;
    try {
      final peerId = (await bind.mainGetUuid()).trim();
      if (peerId.isEmpty) return;
      await LicenseApiRouter.post(
        _endpoint,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'machine_id': peerId, 'peer_id': peerId}),
        requestTimeout: const Duration(seconds: 15),
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[IdleHeartbeat] tick failed (ignored): $e');
        debugPrint('$st');
      }
    } finally {
      _tickInFlight = false;
    }
  }
}
