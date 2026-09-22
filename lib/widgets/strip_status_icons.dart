import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/providers/desktop_update_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/widgets/desktop_update_dialog.dart';
import 'package:icarus/widgets/dialogs/release_notes_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double kStripIconSize = 28;

/// A ghost icon sized for the window strip.
class StripIcon extends StatelessWidget {
  const StripIcon({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.foregroundColor,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return ShadTooltip(
      builder: (context) => Text(tooltip),
      child: ShadIconButton.ghost(
        width: kStripIconSize,
        height: kStripIconSize,
        foregroundColor: foregroundColor ?? theme.mutedForeground,
        hoverForegroundColor: theme.foreground,
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
      ),
    );
  }
}

/// Opens every shipped version's patch notes.
class WhatsNewIcon extends StatelessWidget {
  const WhatsNewIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return StripIcon(
      key: const ValueKey('strip-whats-new'),
      tooltip: "What's new",
      icon: LucideIcons.inbox,
      onPressed: () => ReleaseNotesDialog.show(context),
    );
  }
}

/// Exists only while an update is waiting, on every window strip. Direct
/// Windows installs open the in-app updater; Store and web installs reopen
/// the dialog the automatic check shows, so it is a second chance at the
/// same thing, not a second design.
class UpdateAvailableIcon extends ConsumerWidget {
  const UpdateAvailableIcon({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktopController = ref.watch(desktopUpdateControllerProvider);
    if (desktopController != null) {
      return ListenableBuilder(
        listenable: desktopController,
        builder: (context, _) {
          if (!desktopController.needUpdate) return const SizedBox.shrink();
          return _icon(
            () => DesktopUpdateDialog.show(context, desktopController),
          );
        },
      );
    }

    final status = ref.watch(appUpdateStatusProvider).valueOrNull;
    if (status == null || !status.isUpdateAvailable) {
      return const SizedBox.shrink();
    }
    return _icon(() => UpdateChecker.showUpdateDialog(context, status));
  }

  Widget _icon(VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: StripIcon(
        key: const ValueKey('strip-update-available'),
        tooltip: 'Update available',
        icon: LucideIcons.download,
        foregroundColor: Settings.tacticalVioletTheme.primary,
        onPressed: onPressed,
      ),
    );
  }
}
