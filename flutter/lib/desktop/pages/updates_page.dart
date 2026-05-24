import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/ota_scheduled_task_windows.dart';
import 'package:flutter_hbb/utils/ota_update_service.dart';
import 'package:get/get.dart';
import '../../utils/version_helper.dart';

Future<void> checkForSeeDesktopUpdates(
    BuildContext context, String currentVersion) async {
  await OtaUpdateService.showCheckResultDialog(context);
}

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({super.key});

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  bool _checking = false;
  bool _registeringTask = false;
  late String _statusMessage = translate('updates-check-prompt');
  String _currentVersion = '-';
  bool _dailyScheduleEnabled = true;
  TimeOfDay _scheduleTime = OtaWindowsScheduledTask.defaultScheduleTime;

  @override
  void initState() {
    super.initState();
    _loadCurrentVersion();
    OtaUpdateService.startAutoChecks();
    if (isWindows) {
      _dailyScheduleEnabled = OtaUpdateService.dailySilentScheduleEnabled;
      _scheduleTime = OtaUpdateService.dailySilentScheduleTime;
      unawaited(_refreshOtaTaskStateFromOs());
    }
  }

  Future<void> _refreshOtaTaskStateFromOs() async {
    await OtaWindowsScheduledTask.refreshRegistrationStateFromOs();
    if (!mounted) return;
    setState(() {});
  }

  String _formatSchedule(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _persistSchedule({bool syncTaskIfRegistered = false}) async {
    await OtaUpdateService.persistDailySilentSchedule(
      enabled: _dailyScheduleEnabled,
      time: _scheduleTime,
    );
    if (!syncTaskIfRegistered || !isWindows) return;
    await OtaWindowsScheduledTask.refreshRegistrationStateFromOs();
    if (!OtaWindowsScheduledTask.taskRegistered) return;
    if (!OtaWindowsScheduledTask.needsSyncWithSavedSettings()) return;
    await OtaUpdateService.registerWindowsScheduledTask();
    if (mounted) setState(() {});
  }

  Future<void> _registerScheduledTask() async {
    setState(() => _registeringTask = true);
    await _persistSchedule();
    await OtaUpdateService.registerWindowsScheduledTask();
    if (mounted) {
      setState(() => _registeringTask = false);
    }
  }

  Future<void> _loadCurrentVersion() async {
    final version = await getUnifiedAppVersion();
    if (!mounted) return;
    setState(() {
      _currentVersion = version;
    });
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _checking = true;
      _statusMessage = translate('updates-checking');
    });

    try {
      final currentVersion = await getUnifiedAppVersion();
      if (!mounted) return;
      await OtaUpdateService.checkNow();
      if (!mounted) return;
      if (!stateGlobal.hasOtaUpdate.value) {
        setState(() {
          _currentVersion = currentVersion;
          _checking = false;
          final cloud = stateGlobal.otaLatestVersion.value.trim();
          _statusMessage = cloud.isNotEmpty
              ? translate('ota-check-up-to-date')
                  .replaceAll('{current}', currentVersion)
                  .replaceAll('{latest}', cloud)
              : translate('updates-check-done');
        });
        return;
      }
      await OtaUpdateService.showCheckResultDialog(context);
      if (!mounted) return;
      setState(() {
        _currentVersion = currentVersion;
        _checking = false;
        _statusMessage = translate('updates-new-version')
            .replaceAll('{}', stateGlobal.otaLatestVersion.value);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _statusMessage = translate('updates-check-failed');
      });
    }
  }

  double _pagePadding(double width) {
    if (width < 400) return 8;
    if (width < 720) return 12;
    return 16;
  }

  double _contentMaxWidth(double width) {
    if (width > 900) return 720;
    return width;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final pad = _pagePadding(width);
        final narrow = width < 520;
        final cs = Theme.of(context).colorScheme;

        return SingleChildScrollView(
          padding: EdgeInsets.all(pad),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: _contentMaxWidth(width)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    translate('Software Updates'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    translate('updates-current-version')
                        .replaceAll('{}', _currentVersion),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  _buildPrimaryAction(context, narrow: narrow),
                  const SizedBox(height: 12),
                  SelectableText(
                    _statusMessage,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (isWindows) ...[
                    const Divider(height: 28),
                    Text(
                      translate('ota-silent-schedule-title'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      translate('ota-silent-schedule-intro'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(translate('ota-daily-enabled-title')),
                      subtitle: Text(translate('ota-daily-enabled-subtitle')),
                      value: _dailyScheduleEnabled,
                      onChanged: (v) async {
                        setState(() => _dailyScheduleEnabled = v);
                        await _persistSchedule(syncTaskIfRegistered: true);
                      },
                    ),
                    _buildScheduleTimeRow(context, narrow: narrow),
                    const SizedBox(height: 8),
                    _buildRegisterTaskButton(narrow: narrow),
                    if (OtaWindowsScheduledTask.lastSyncInfo != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        OtaWindowsScheduledTask.lastSyncInfo!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.primary,
                            ),
                      ),
                    ],
                    if (OtaWindowsScheduledTask.lastSyncError != null) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        OtaWindowsScheduledTask.lastSyncError!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.error,
                            ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPrimaryAction(BuildContext context, {required bool narrow}) {
    final btn = Obx(() {
      final hasUpdate = stateGlobal.hasOtaUpdate.value;
      return ElevatedButton.icon(
        onPressed: _checking
            ? null
            : () async {
                if (hasUpdate) {
                  await OtaUpdateService.openDownload(context);
                } else {
                  await _checkForUpdates();
                }
              },
        icon: _checking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.sync),
                  if (hasUpdate)
                    const Positioned(
                      right: -2,
                      top: -2,
                      child: _UpdateDot(),
                    ),
                ],
              ),
        label: Text(
          hasUpdate
              ? translate('updates-download-btn')
              : translate('updates-check-btn'),
        ),
      );
    });

    if (narrow) {
      return SizedBox(width: double.infinity, child: btn);
    }
    return Align(alignment: Alignment.centerLeft, child: btn);
  }

  Widget _buildScheduleTimeRow(BuildContext context, {required bool narrow}) {
    final timeLabel = _formatSchedule(_scheduleTime);
    final changeBtn = TextButton(
      onPressed: !_dailyScheduleEnabled
          ? null
          : () async {
              final t = await showTimePicker(
                context: context,
                initialTime: _scheduleTime,
              );
              if (t != null && mounted) {
                setState(() => _scheduleTime = t);
                await _persistSchedule(syncTaskIfRegistered: true);
              }
            },
      child: Text(translate('ota-change-time')),
    );

    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(translate('ota-daily-time-title')),
            subtitle: Text(timeLabel),
          ),
          Align(alignment: Alignment.centerLeft, child: changeBtn),
        ],
      );
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(translate('ota-daily-time-title')),
      subtitle: Text(timeLabel),
      trailing: changeBtn,
    );
  }

  Widget _buildRegisterTaskButton({required bool narrow}) {
    final btn = OutlinedButton.icon(
      onPressed: _registeringTask ? null : _registerScheduledTask,
      icon: _registeringTask
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.schedule),
      label: Text(translate('ota-register-task-btn')),
    );

    if (narrow) {
      return SizedBox(width: double.infinity, child: btn);
    }
    return Align(alignment: Alignment.centerLeft, child: btn);
  }
}

class _UpdateDot extends StatelessWidget {
  const _UpdateDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(
        color: Colors.red,
        shape: BoxShape.circle,
      ),
    );
  }
}
