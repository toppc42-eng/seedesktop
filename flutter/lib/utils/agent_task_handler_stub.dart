/// Stub when `dart:io` is unavailable (web).

Future<void> checkAndSubmitPendingLogs() async {}

Future<void> handleInboundPendingTask(String taskName) async {}

/// No-op on web; Windows implementation runs WMI in `agent_task_handler_io.dart`.
Future<Map<String, String>> collectHardwareTelemetryForHeartbeat() async =>
    {};
