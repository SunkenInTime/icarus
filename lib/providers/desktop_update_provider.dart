import 'dart:io';

import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/services/windows_desktop_update_controller.dart';

/// The updater's words. The package fills each `{}` in order (app name,
/// version, download size).
DesktopUpdateLocalization desktopUpdateLocalization(AppLocalizations l10n) =>
    DesktopUpdateLocalization(
      updateAvailableText: l10n.updateMsgUpdateAvailable,
      newVersionAvailableText: l10n.updateMsgNewVersionAvailable('{}', '{}'),
      newVersionLongText: l10n.updateMsgNewVersionLong('{}'),
      downloadText: l10n.updateMsgDownload,
      restartText: l10n.updateMsgRestartToUpdate,
      skipThisVersionText: l10n.updateMsgLater,
      warningTitleText: l10n.updateMsgRestartRequiredTitle,
      restartWarningText: l10n.updateMsgRestartWarning,
      warningCancelText: l10n.updateMsgRestartCancel,
      warningConfirmText: l10n.updateMsgRestartConfirm,
    );

/// The in-app updater for direct Windows installs. Null everywhere else:
/// the Store, macOS, and web update through their own channels, and the
/// Store check has to fail first before we know this is a direct install.
final desktopUpdateControllerProvider =
    Provider<WindowsDesktopUpdateController?>((ref) {
  if (kDebugMode && kDebugForceDesktopUpdateDialog) {
    final controller = WindowsDesktopUpdateController.debugPreview(
      localization: desktopUpdateLocalization(ref.read(l10nProvider)),
    );
    _followLanguage(ref, controller);
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
    localization: desktopUpdateLocalization(ref.read(l10nProvider)),
  );
  _followLanguage(ref, controller);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Keeps the updater's words in the app's language without replacing the
/// controller, which may be mid-download.
void _followLanguage(Ref ref, WindowsDesktopUpdateController controller) {
  ref.listen(l10nProvider, (_, l10n) {
    controller.localization = desktopUpdateLocalization(l10n);
  });
}
