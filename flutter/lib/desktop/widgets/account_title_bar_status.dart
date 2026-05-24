import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/login.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/cloud_sync_service.dart';
import 'package:get/get.dart';

/// Cloud OTP / hbbs login status for the **bottom** [ConnectionStatusStrip]
/// (previously shown in the window title bar).
class DesktopAccountStatusStrip extends StatelessWidget {
  const DesktopAccountStatusStrip({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (bind.isDisableAccount()) {
      return const SizedBox.shrink();
    }
    final textColor = Theme.of(context).textTheme.bodySmall?.color;
    return Obx(() {
      CloudSyncService.authRevision.value;
      final hbbsUser = gFFI.userModel.userName.value;
      final hbbsEmail = gFFI.userModel.userEmail.value;
      final err = gFFI.userModel.networkError.value.trim();

      final cloudOn = CloudSyncService.hasToken;
      final cloudEm = CloudSyncService.savedEmail.trim();

      final hbbsOn = hbbsUser.trim().isNotEmpty;
      final loggedIn = cloudOn || hbbsOn;

      final email = cloudEm.isNotEmpty
          ? cloudEm
          : hbbsEmail.trim().isNotEmpty
              ? hbbsEmail.trim()
              : hbbsUser.trim();

      final statusText = !loggedIn
          ? translate('title_bar_account_status_not_connected')
          : email.isNotEmpty
              ? '${translate('title_bar_account_status_connected')}: $email'
              : translate('title_bar_account_status_connected');

      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Tooltip(
          message: email.isNotEmpty && loggedIn ? email : statusText,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.person_outline,
                size: 14,
                color: textColor?.withOpacity(0.88),
              ),
              const SizedBox(width: 2),
              TextButton(
                onPressed: () async {
                  if (loggedIn) {
                    if (CloudSyncService.hasToken) {
                      await CloudSyncService.clearSession();
                    }
                    if (gFFI.userModel.userName.value.trim().isNotEmpty) {
                      logOutConfirmDialog();
                    }
                  } else {
                    DesktopSettingPage.switch2page(SettingsTabKey.account);
                  }
                },
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  loggedIn
                      ? translate('title_bar_account_sign_out')
                      : translate('title_bar_account_send_code'),
                  style: const TextStyle(fontSize: 10.5),
                ),
              ),
              const SizedBox(width: 2),
              Flexible(
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: (hbbsOn && err.isNotEmpty && !cloudOn)
                        ? Colors.orange.shade800
                        : textColor?.withOpacity(0.78),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// Center of [ConnectionStatusStrip]: connect prompt when logged out; email + logout when logged in.
class DesktopAccountStatusCenter extends StatelessWidget {
  const DesktopAccountStatusCenter({Key? key}) : super(key: key);

  Future<void> _logout() async {
    if (CloudSyncService.hasToken) {
      await CloudSyncService.clearSession();
    }
    if (gFFI.userModel.userName.value.trim().isNotEmpty) {
      logOutConfirmDialog();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (bind.isDisableAccount()) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Obx(() {
      CloudSyncService.authRevision.value;
      final hbbsUser = gFFI.userModel.userName.value;
      final hbbsEmail = gFFI.userModel.userEmail.value;
      final err = gFFI.userModel.networkError.value.trim();

      final cloudOn = CloudSyncService.hasToken;
      final cloudEm = CloudSyncService.savedEmail.trim();

      final hbbsOn = hbbsUser.trim().isNotEmpty;
      final loggedIn = cloudOn || hbbsOn;

      final email = cloudEm.isNotEmpty
          ? cloudEm
          : hbbsEmail.trim().isNotEmpty
              ? hbbsEmail.trim()
              : hbbsUser.trim();

      if (!loggedIn) {
        return TextButton(
          onPressed: () {
            DesktopSettingPage.switch2page(SettingsTabKey.account);
          },
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            translate('status_bar_connect_to_account'),
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: colorScheme.primary,
            ),
          ),
        );
      }

      final emailColor = (hbbsOn && err.isNotEmpty && !cloudOn)
          ? Colors.orange.shade800
          : theme.textTheme.bodyMedium?.color;

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Tooltip(
              message: email.isNotEmpty ? email : '',
              child: Text(
                email.isNotEmpty ? email : translate('title_bar_account_status_connected'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: emailColor,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async => _logout(),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              translate('title_bar_account_sign_out'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: colorScheme.primary,
              ),
            ),
          ),
        ],
      );
    });
  }
}
