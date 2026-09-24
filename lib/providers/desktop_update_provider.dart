import 'dart:io';

import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/services/windows_desktop_update_controller.dart';

const desktopUpdateLocalization = DesktopUpdateLocalization(
  updateAvailableText: 'Update Available',
  newVersionAvailableText: '{} {} is available',
  newVersionLongText:
      'A desktop update is ready. Downloading will fetch {} MB of files.',
  downloadText: 'Download Update',
  restartText: 'Restart to update',
  skipThisVersionText: 'Later',
  warningTitleText: 'Restart Required',
  restartWarningText:
      'Icarus needs to restart to finish installing the update. Unsaved changes will be lost. Restart now?',
  warningCancelText: 'Not now',
  warningConfirmText: 'Restart',
);

/// The in-app updater for direct Windows installs. Null everywhere else:
/// the Store, macOS, and web update through their own channels, and the
/// Store check has to fail first before we know this is a direct install.
final desktopUpdateControllerProvider =
    Provider<WindowsDesktopUpdateController?>((ref) {
  if (kDebugMode && kDebugForceDesktopUpdateDialog) {
    final controller = WindowsDesktopUpdateController.debugPreview(
      localization: desktopUpdateLocalization,
    );
    ref.onDispose(controller.dispose);
    return controller;
  }

  final status = ref.watch(appUpdateStatusProvider).valueOrNull;
  if (status == null) return null;

  final bool isDirectWindowsInstall =
      !kIsWeb && Platform.isWindows && !status.isSupported;
  if (!isDirectWindowsInstall) return null;

  debugPrint(
    'Desktop updater channel: $kResolvedUpdateChannel | Manifest: ${Settings.desktopUpdaterArchiveUrl}',
  );
  final controller = WindowsDesktopUpdateController(
    appArchiveUrl: Settings.desktopUpdaterArchiveUrl,
    localization: desktopUpdateLocalization,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
