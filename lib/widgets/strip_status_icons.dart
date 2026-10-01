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
class UpdateAvailableIcon extends StatelessWidget {
  const UpdateAvailableIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return WaitingUpdateBuilder(
      builder: (context, openUpdate, _) =>
          openUpdate == null ? const SizedBox.shrink() : _icon(openUpdate),
    );
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

/// Builds with what opens the waiting update, or null while none is known:
/// the in-app updater for a direct Windows install, otherwise the dialog the
/// automatic check shows. [isChecking] is true while the update check runs.
class WaitingUpdateBuilder extends ConsumerWidget {
  const WaitingUpdateBuilder({super.key, required this.builder});

  final Widget Function(
    BuildContext context,
    VoidCallback? openUpdate,
    bool isChecking,
  ) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final check = ref.watch(appUpdateStatusProvider);
    final desktopController = ref.watch(desktopUpdateControllerProvider);
    if (desktopController != null) {
      return ListenableBuilder(
        listenable: desktopController,
        builder: (context, _) => builder(
          context,
          desktopController.needUpdate
              ? () => DesktopUpdateDialog.show(context, desktopController)
              : null,
          check.isLoading,
        ),
      );
    }

    final status = check.valueOrNull;
    return builder(
      context,
      status != null && status.isUpdateAvailable
          ? () => UpdateChecker.showUpdateDialog(context, status)
          : null,
      check.isLoading,
    );
  }
}
