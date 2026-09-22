import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/providers/desktop_update_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/widgets/desktop_update_dialog.dart';
import 'package:icarus/widgets/dialogs/release_notes_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

/// The quiet end of every window strip: an update icon that only appears
/// when there is one to install, then What's new and About. Lives here so
/// the library and the editor never disagree about where they are.
class StripStatusIcons extends ConsumerWidget {
  const StripStatusIcons({super.key});

  static const double _size = 28;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _UpdateIcon(),
          _StripIcon(
            key: const ValueKey('strip-whats-new'),
            tooltip: "What's new",
            icon: LucideIcons.inbox,
            onPressed: () => ReleaseNotesDialog.show(context),
          ),
          const _AboutIcon(),
        ],
      ),
    );
  }
}

class _StripIcon extends StatelessWidget {
  const _StripIcon({
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
        width: StripStatusIcons._size,
        height: StripStatusIcons._size,
        foregroundColor: foregroundColor ?? theme.mutedForeground,
        hoverForegroundColor: theme.foreground,
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
      ),
    );
  }
}

/// Shown only while an update is waiting. Direct Windows installs open the
/// in-app updater; Store and web installs open the same dialog the automatic
/// check shows, so the icon is a second chance at it, not a second design.
class _UpdateIcon extends ConsumerWidget {
  const _UpdateIcon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktopController = ref.watch(desktopUpdateControllerProvider);
    if (desktopController != null) {
      return ListenableBuilder(
        listenable: desktopController,
        builder: (context, _) {
          if (!desktopController.needUpdate) return const SizedBox.shrink();
          return _StripIcon(
            key: const ValueKey('strip-update-available'),
            tooltip: 'Update available',
            icon: LucideIcons.download,
            foregroundColor: Settings.tacticalVioletTheme.primary,
            onPressed: () =>
                DesktopUpdateDialog.show(context, desktopController),
          );
        },
      );
    }

    final status = ref.watch(appUpdateStatusProvider).valueOrNull;
    if (status == null || !status.isUpdateAvailable) {
      return const SizedBox.shrink();
    }
    return _StripIcon(
      key: const ValueKey('strip-update-available'),
      tooltip: 'Update available',
      icon: LucideIcons.download,
      foregroundColor: Settings.tacticalVioletTheme.primary,
      onPressed: () => UpdateChecker.showUpdateDialog(context, status),
    );
  }
}

class _AboutIcon extends StatefulWidget {
  const _AboutIcon();

  @override
  State<_AboutIcon> createState() => _AboutIconState();
}

class _AboutIconState extends State<_AboutIcon> {
  final _popover = ShadPopoverController();

  @override
  void dispose() {
    _popover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadPopover(
      controller: _popover,
      anchor: const ShadAnchorAuto(offset: Offset(0, 6)),
      popover: (context) => SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Icarus',
              style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Version ${Settings.versionName} (${Settings.versionNumber})',
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 12),
            ShadButton.ghost(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              leading: const Icon(LucideIcons.copy, size: 14),
              onPressed: () {
                Clipboard.setData(const ClipboardData(
                  text:
                      'Icarus ${Settings.versionName}+${Settings.versionNumber}',
                ));
                _popover.hide();
                Settings.showToast(
                  message: 'Version copied',
                  backgroundColor: Settings.tacticalVioletTheme.primary,
                );
              },
              child: const Text('Copy version'),
            ),
            ShadButton.ghost(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              leading: const Icon(LucideIcons.messageCircle, size: 14),
              onPressed: () {
                _popover.hide();
                launchUrl(Settings.dicordLink);
              },
              child: const Text('Join the Discord'),
            ),
          ],
        ),
      ),
      child: _StripIcon(
        key: const ValueKey('strip-about'),
        tooltip: 'About Icarus',
        icon: LucideIcons.info,
        onPressed: _popover.toggle,
      ),
    );
  }
}
