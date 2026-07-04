import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
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

    await showShadDialog<void>(
      context: context,
      barrierDismissible: !widget.controller.isMandatory,
      builder: (context) => DesktopUpdateDialog(
        controller: widget.controller,
      ),
      variant: ShadDialogVariant.alert,
    );

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

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final bool canDismiss = !controller.isMandatory;
        final notes = (controller.releaseNotes ?? const <ChangeModel?>[])
            .whereType<ChangeModel>()
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
                          const Positioned(
                            top: 10,
                            left: 10,
                            child: ShadBadge.destructive(
                              child: Text('Required'),
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
                            _PatchNotes(notes: notes),
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

class _PatchNotes extends StatelessWidget {
  const _PatchNotes({required this.notes});

  final List<ChangeModel> notes;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: SingleChildScrollView(
        child: Column(
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
        ),
      ),
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
        return theme.colorScheme.primary;
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
          controller.getLocalization?.restartText ?? 'Restart to update',
        ),
      );
    }

    return ShadButton(
      width: double.infinity,
      onPressed: () => _startDownload(context),
      leading: const Icon(LucideIcons.download),
      child: Text(
        controller.getLocalization?.downloadText ?? 'Download Update',
      ),
    );
  }

  Future<void> _startDownload(BuildContext context) async {
    try {
      await controller.downloadUpdate();
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Failed to download the desktop update. Please try again.',
        error: error,
        stackTrace: stackTrace,
        source: 'DesktopUpdateDialog.downloadUpdate',
      );
    }
  }

  Future<void> _confirmRestart(BuildContext context) async {
    final bool confirmed = await ConfirmAlertDialog.show(
      context: context,
      title: controller.getLocalization?.warningTitleText ?? 'Restart Required',
      content: controller.getLocalization?.restartWarningText ??
          'A restart is required to complete the update installation.\nAny unsaved changes will be lost. Would you like to restart now?',
      confirmText: controller.getLocalization?.warningConfirmText ?? 'Restart',
      cancelText: controller.getLocalization?.warningCancelText ?? 'Not now',
    );

    if (confirmed) {
      try {
        await controller.restartApp();
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          'Failed to apply the downloaded desktop update. Please try downloading it again.',
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
                    curve: Curves.easeOut,
                    width: width * fill,
                    color: theme.colorScheme.primary,
                  ),
                ),
                Center(
                  child: Text(
                    'Downloading… $percent%',
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
