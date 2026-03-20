import 'package:desktop_updater/desktop_updater.dart';
import 'package:desktop_updater/updater_controller.dart';
import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/windows_desktop_update_restart_service.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DesktopUpdateDialogListener extends StatefulWidget {
  const DesktopUpdateDialogListener({
    super.key,
    required this.controller,
  });

  final DesktopUpdaterController controller;

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
        final shouldShow = controller.needUpdate &&
            !controller.skipUpdate &&
            !_dialogOpen;

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
      barrierDismissible: false,
      builder: (context) => DesktopUpdateDialog(
        controller: widget.controller,
      ),
      variant: ShadDialogVariant.alert,
    );

    if (!mounted) {
      return;
    }

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

  final DesktopUpdaterController controller;

  @override
  Widget build(BuildContext context) {
    final shadTheme = ShadTheme.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final bool canDismiss = !controller.isMandatory &&
            !controller.isDownloading &&
            !controller.isDownloaded;
        final String versionLabel = controller.appVersion ?? 'Latest version';
        final String appLabel = controller.appName ?? 'Icarus';
        final String headline = getLocalizedString(
              controller.getLocalization?.newVersionAvailableText ??
                  '{} {} is available',
              [appLabel, versionLabel],
            ) ??
            '$appLabel $versionLabel is available';
        final String summary = getLocalizedString(
              controller.getLocalization?.newVersionLongText ??
                  'A desktop update is ready. Downloading will fetch {} MB of files.',
              [_formatMegabytes(controller.downloadSize ?? 0)],
            ) ??
            '';

        return ShadDialog.alert(
          title: Row(
            children: [
              Container(
                height: 40,
                width: 40,
                decoration: BoxDecoration(
                  color: shadTheme.colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  controller.isDownloaded
                      ? LucideIcons.badgeCheck
                      : LucideIcons.download,
                  color: shadTheme.colorScheme.primary,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      controller.getLocalization?.updateAvailableText ??
                          'Update Available',
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ShadBadge.secondary(
                          child: Text(versionLabel),
                        ),
                        if (controller.isMandatory)
                          const ShadBadge.destructive(
                            child: Text('Required'),
                          )
                        else
                          const ShadBadge.outline(
                            child: Text('Direct Download'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          closeIcon: canDismiss
              ? ShadIconButton.ghost(
                  icon: const Icon(LucideIcons.x, size: 16),
                  width: 20,
                  height: 20,
                  padding: EdgeInsets.zero,
                  onPressed: () => _dismissForLater(context),
                )
              : null,
          description: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                headline,
                style: shadTheme.textTheme.small.copyWith(
                  color: shadTheme.colorScheme.foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (summary.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(summary),
              ],
              const SizedBox(height: 16),
              _StatusPanel(
                controller: controller,
              ),
              if ((controller.releaseNotes ?? const <ChangeModel?>[]).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: _ReleaseNotesPanel(
                    notes: controller.releaseNotes ?? const <ChangeModel?>[],
                  ),
                ),
            ],
          ),
          actions: _buildActions(context),
        );
      },
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    if (controller.isDownloading && !controller.isDownloaded) {
      return [
        ShadButton.secondary(
          onPressed: null,
          leading: const SizedBox(
            height: 16,
            width: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          child: Text(
            '${(controller.downloadProgress * 100).toInt()}% downloaded',
          ),
        ),
      ];
    }

    if (controller.isDownloaded) {
      return [
        ShadButton.secondary(
          onPressed: () async {
            final bool confirmed = await ConfirmAlertDialog.show(
              context: context,
              title: controller.getLocalization?.warningTitleText ??
                  'Restart Required',
              content: controller.getLocalization?.restartWarningText ??
                  'A restart is required to complete the update installation.\nAny unsaved changes will be lost. Would you like to restart now?',
              confirmText:
                  controller.getLocalization?.warningConfirmText ?? 'Restart',
              cancelText:
                  controller.getLocalization?.warningCancelText ?? 'Not now',
            );

            if (confirmed) {
              try {
                await WindowsDesktopUpdateRestartService()
                    .restartIntoDownloadedUpdate();
              } catch (error, stackTrace) {
                AppErrorReporter.reportError(
                  'Failed to apply the downloaded desktop update. Please close and reopen Icarus, then try again.',
                  error: error,
                  stackTrace: stackTrace,
                  source: 'DesktopUpdateDialog.restartToUpdate',
                );
                controller.makeSkipUpdate();
                if (!context.mounted) {
                  return;
                }
                Navigator.of(context).pop();
              }
            }
          },
          leading: const Icon(LucideIcons.rotateCcw),
          child: Text(
            controller.getLocalization?.restartText ?? 'Restart to update',
          ),
        ),
      ];
    }

    return [
      if (!controller.isMandatory)
        ShadButton.secondary(
          onPressed: () => _dismissForLater(context),
          child: Text(
            controller.getLocalization?.skipThisVersionText ?? 'Later',
          ),
        ),
      ShadButton(
        onPressed: controller.downloadUpdate,
        leading: const Icon(LucideIcons.download),
        child: Text(
          controller.getLocalization?.downloadText ?? 'Download Update',
        ),
      ),
    ];
  }

  void _dismissForLater(BuildContext context) {
    controller.makeSkipUpdate();
    Navigator.of(context).pop();
  }

  static String _formatMegabytes(double sizeInKilobytes) {
    return (sizeInKilobytes / 1024).toStringAsFixed(2);
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.controller,
  });

  final DesktopUpdaterController controller;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final bool isDownloading = controller.isDownloading && !controller.isDownloaded;
    final bool isDownloaded = controller.isDownloaded;

    String title;
    String subtitle;
    IconData icon;

    if (isDownloaded) {
      title = 'Update ready to install';
      subtitle = 'Restart Icarus to finish applying version ${controller.appVersion ?? ''}.';
      icon = LucideIcons.badgeCheck;
    } else if (isDownloading) {
      title = 'Downloading update';
      subtitle =
          '${(controller.downloadProgress * 100).toInt()}% complete • ${_formatMegabytes(controller.downloadedSize)} MB of ${_formatMegabytes(controller.downloadSize ?? 0)} MB';
      icon = LucideIcons.loaderCircle;
    } else {
      title = 'Ready to download';
      subtitle =
          '${_formatMegabytes(controller.downloadSize ?? 0)} MB will be downloaded and applied on restart.';
      icon = LucideIcons.download;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.border),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: isDownloaded
                    ? const Color(0xFF4ADE80)
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: theme.textTheme.muted,
          ),
          const SizedBox(height: 12),
          ShadProgress(
            value: isDownloaded ? 1 : (isDownloading ? controller.downloadProgress : 0),
            minHeight: 10,
            borderRadius: BorderRadius.circular(999),
            innerBorderRadius: BorderRadius.circular(999),
            backgroundColor: theme.colorScheme.secondary,
            color: isDownloaded
                ? const Color(0xFF4ADE80)
                : theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }

  static String _formatMegabytes(double sizeInKilobytes) {
    return (sizeInKilobytes / 1024).toStringAsFixed(2);
  }
}

class _ReleaseNotesPanel extends StatelessWidget {
  const _ReleaseNotesPanel({
    required this.notes,
  });

  final List<ChangeModel?> notes;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'What is changing',
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          ...notes.whereType<ChangeModel>().map(
                (note) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        height: 6,
                        width: 6,
                        decoration: BoxDecoration(
                          color: _colorForNoteType(theme, note.type),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (note.type != null && note.type!.trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: ShadBadge.outline(
                                  child: Text(note.type!.trim()),
                                ),
                              ),
                            Text(
                              note.message,
                              style: theme.textTheme.small.copyWith(
                                color: theme.colorScheme.foreground,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
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
