import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter/material.dart';
import 'package:icarus/const/release_notes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/windows_desktop_update_controller.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/dither_fire_banner.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DesktopUpdateDialogListener extends StatefulWidget {
  const DesktopUpdateDialogListener({
    super.key,
    required this.controller,
  });

  final WindowsDesktopUpdateController controller;

  @override
  State<DesktopUpdateDialogListener> createState() =>
      _DesktopUpdateDialogListenerState();
}

class _DesktopUpdateDialogListenerState
    extends State<DesktopUpdateDialogListener> {
  bool _dialogOpen = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final shouldShow =
            controller.needUpdate && !controller.skipUpdate && !_dialogOpen;

        if (shouldShow) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showDialog();
          });
        }

        return const SizedBox.shrink();
      },
    );
  }

  Future<void> _showDialog() async {
    if (!mounted || _dialogOpen) {
      return;
    }

    _dialogOpen = true;

    await DesktopUpdateDialog.show(context, widget.controller);

    if (!mounted) {
      return;
    }

    // Whether closed by the X or by tapping outside, don't nag again
    // this session (mandatory updates can't reach this without restarting).
    widget.controller.makeSkipUpdate();

    setState(() {
      _dialogOpen = false;
    });
  }
}

class DesktopUpdateDialog extends StatelessWidget {
  const DesktopUpdateDialog({
    super.key,
    required this.controller,
  });

  final WindowsDesktopUpdateController controller;

  static const double _width = 420;
  static const double _heroHeight = 180;

  static Future<void> show(
    BuildContext context,
    WindowsDesktopUpdateController controller,
  ) {
    return showShadDialog<void>(
      context: context,
      barrierDismissible: !controller.isMandatory,
      builder: (context) => DesktopUpdateDialog(controller: controller),
      variant: ShadDialogVariant.alert,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final bool canDismiss = !controller.isMandatory;
        final notes = (controller.releaseNotes ?? const <ChangeModel?>[])
            .whereType<ChangeModel>()
            .map((note) =>
                ReleaseNoteChange(message: note.message, type: note.type))
            .toList();

        final double fireProgress = controller.isDownloaded
            ? 1
            : controller.isDownloading
                ? controller.downloadProgress
                : 0;

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _width),
            child: Material(
              color: Colors.transparent,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: theme.colorScheme.background,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: theme.colorScheme.border),
                  boxShadow: const [Settings.cardForegroundBackdrop],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Stack(
                      children: [
                        DitherFireBanner(
                          progress: fireProgress,
                          height: _heroHeight,
                          child: Container(
                            width: 170,
                            height: 170,
                            decoration: const BoxDecoration(
                              // Soft dark pool so the lockup stays readable
                              // over the busy halftone field.
                              gradient: RadialGradient(
                                colors: [
                                  Color(0xB30C0612),
                                  Color(0x000C0612),
                                ],
                                stops: [0.35, 1],
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Image.asset(
                                  'assets/logo_mark.png',
                                  width: 116,
                                  height: 116,
                                  filterQuality: FilterQuality.medium,
                                ),
                                Text(
                                  controller.appVersion ?? '',
                                  style: theme.textTheme.small.copyWith(
                                    // Quiet on purpose: findable if you look,
                                    // silent if you don't.
                                    color: const Color(0xff5b5566),
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (controller.isMandatory)
                          Positioned(
                            top: 10,
                            left: 10,
                            child: ShadBadge.destructive(
                              child: Text(
                                context.l10n.desktopUpdateRequiredBadge,
                              ),
                            ),
                          ),
                        if (canDismiss)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: ShadIconButton.ghost(
                              icon: const Icon(LucideIcons.x, size: 16),
                              width: 28,
                              height: 28,
                              padding: EdgeInsets.zero,
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (notes.isNotEmpty) ...[
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 280),
                              child: SingleChildScrollView(
                                child: PatchNotesList(notes: notes),
                              ),
                            ),
                            const SizedBox(height: 18),
                          ],
                          _UpdateButton(controller: controller),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Patch notes as a bulleted column, each bullet tinted by the note's type.
/// Shared by the update dialog and the What's new dialog.
class PatchNotesList extends StatelessWidget {
  const PatchNotesList({super.key, required this.notes});

  final List<ReleaseNoteChange> notes;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  height: 4,
                  width: 4,
                  decoration: BoxDecoration(
                    color: _colorForNoteType(theme, note.type)
                        .withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    note.message,
                    style: theme.textTheme.small.copyWith(
                      color: theme.colorScheme.foreground,
                      fontWeight: FontWeight.w400,
                      height: 1.55,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static Color _colorForNoteType(ShadThemeData theme, String? type) {
    switch (type?.trim().toLowerCase()) {
      case 'fix':
      case 'bugfix':
        return const Color(0xFF4ADE80);
      case 'breaking':
      case 'warning':
        return theme.colorScheme.destructive;
      case 'feature':
        return Settings.accentInk;
      default:
        return theme.colorScheme.mutedForeground;
    }
  }
}

/// Single action that morphs through the update lifecycle:
/// download -> percent progress -> restart to install.
class _UpdateButton extends StatelessWidget {
  const _UpdateButton({required this.controller});

  final WindowsDesktopUpdateController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.isDownloading && !controller.isDownloaded) {
      return _DownloadFillButton(
        progress: controller.downloadProgress,
      );
    }

    if (controller.isDownloaded) {
      return ShadButton(
        width: double.infinity,
        onPressed: () => _confirmRestart(context),
        leading: const Icon(LucideIcons.rotateCcw),
        child: Text(
          controller.getLocalization?.restartText ??
              context.l10n.desktopUpdateRestartToUpdate,
        ),
      );
    }

    return ShadButton(
      width: double.infinity,
      onPressed: () => _startDownload(context),
      leading: const Icon(LucideIcons.download),
      child: Text(
        controller.getLocalization?.downloadText ??
            context.l10n.desktopUpdateDownload,
      ),
    );
  }

  Future<void> _startDownload(BuildContext context) async {
    final l10n = context.l10n;
    try {
      await controller.downloadUpdate();
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        l10n.desktopUpdateDownloadFailed,
        error: error,
        stackTrace: stackTrace,
        source: 'DesktopUpdateDialog.downloadUpdate',
      );
    }
  }

  Future<void> _confirmRestart(BuildContext context) async {
    final l10n = context.l10n;
    final bool confirmed = await ConfirmAlertDialog.show(
      context: context,
      title: controller.getLocalization?.warningTitleText ??
          l10n.desktopUpdateRestartRequiredTitle,
      content: controller.getLocalization?.restartWarningText ??
          l10n.desktopUpdateRestartWarning,
      confirmText: controller.getLocalization?.warningConfirmText ??
          l10n.desktopUpdateRestartConfirm,
      cancelText: controller.getLocalization?.warningCancelText ??
          l10n.desktopUpdateRestartCancel,
    );

    if (confirmed) {
      try {
        await controller.restartApp();
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          l10n.desktopUpdateApplyFailed,
          error: error,
          stackTrace: stackTrace,
          source: 'DesktopUpdateDialog.restartToUpdate',
        );
      }
    }
  }
}

/// Download button whose background fills left-to-right with primary violet
/// as progress advances.
class _DownloadFillButton extends StatelessWidget {
  const _DownloadFillButton({
    required this.progress,
  });

  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final fill = progress.clamp(0.0, 1.0);
    final percent = (fill * 100).toInt();

    return SizedBox(
      width: double.infinity,
      height: 40,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;

          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: theme.colorScheme.secondary),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    curve: Settings.easeOut,
                    width: width * fill,
                    color: Settings.accentInk,
                  ),
                ),
                Center(
                  child: Text(
                    context.l10n.desktopUpdateDownloading(percent),
                    style: theme.textTheme.small.copyWith(
                      color: theme.colorScheme.foreground,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
