import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/utils/agent_heartbeat_manager.dart';

/// Selected row in [MyDevicesPage] for the right-hand RMM sidebar.
class MyDevicesRmmSelection extends ChangeNotifier {
  MyDevicesRmmSelection._();
  static final MyDevicesRmmSelection instance = MyDevicesRmmSelection._();

  AgentInfo? _selected;
  AgentInfo? get selected => _selected;

  void select(AgentInfo agent) {
    _selected = agent;
    notifyListeners();
  }

  void clear() {
    if (_selected == null) return;
    _selected = null;
    notifyListeners();
  }
}
