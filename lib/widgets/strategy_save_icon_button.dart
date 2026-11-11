import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/auto_save_notifier.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';
import 'package:icarus/widgets/loading_spinner.dart';

const saveFailedMessage = "Couldn't save this strategy. Try again.";

/// Saves the open strategy immediately and tells the user where the work now
/// is: saved, saved on this device and waiting to sync, or not saved. The
/// answer is read from the library and the outboxes after the save, never
/// assumed from the press.
Future<void> saveStrategyNow(BuildContext context, WidgetRef ref) async {
  final strategyId = ref.read(strategyProvider).strategyId;
  if (strategyId == null) return;
  final pressedAt = DateTime.now();
  var threw = false;
  try {
    await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
  } catch (error, stackTrace) {
    threw = true;
    AppErrorReporter.reportError(
      saveFailedMessage,
      error: error,
      stackTrace: stackTrace,
      source: 'saveStrategyNow',
      // The toast below tells the user.
      promptUser: false,
    );
  }
  if (!context.mounted) return;

  final (:message, :failed) = threw
      ? (message: context.l10n.saveButtonFailed, failed: true)
      : ref.read(strategyProvider).source == StrategySource.cloud
          ? _cloudSaveOutcome(ref)
          : _localSaveOutcome(ref, pressedAt);

  if (failed) {
    Settings.showToast(
      message: message,
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
    return;
  }

  toastification.showCustom(
    context: context,
    autoCloseDuration: const Duration(seconds: 3),
    alignment: Alignment.bottomCenter,
    builder: (context, holder) {
      return Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Settings.tacticalVioletTheme.border),
        ),
        child: Text(
          message,
          style: ShadTheme.of(context)
              .textTheme
              .small
              .copyWith(color: Settings.tacticalVioletTheme.foreground),
        ),
      );
    },
  );
}

/// A local save landed only if it wrote the library after the press. A
/// strategy missing from the library is skipped without a write.
({String message, bool failed}) _localSaveOutcome(
  WidgetRef ref,
  DateTime pressedAt,
) {
  final lastPersistedAt = ref.read(strategySaveStateProvider).lastPersistedAt;
  final persisted =
      lastPersistedAt != null && !lastPersistedAt.isBefore(pressedAt);
  final l10n = ref.read(l10nProvider);
  return persisted
      ? (message: l10n.saveButtonSaved, failed: false)
      : (message: l10n.saveButtonFailed, failed: true);
}

/// A cloud save is in the outbox unless a write to it failed; whether it has
/// reached the server is the sync status, worded as the sync button words it.
({String message, bool failed}) _cloudSaveOutcome(WidgetRef ref) {
  final opQueue = ref.read(strategyOpQueueProvider);
  final mediaQueue = ref.read(cloudMediaUploadQueueProvider);
  final l10n = ref.read(l10nProvider);
  if (opQueue.hasDurabilityFailure || mediaQueue.durabilityError != null) {
    return (message: l10n.syncErrorUnverifiedCloudWork, failed: true);
  }
  final saveState = ref.read(strategySaveStateProvider);
  final message = switch (ref.read(cloudSyncStatusProvider)) {
    CloudSyncStatus.synced => l10n.saveButtonSaved,
    CloudSyncStatus.editing => l10n.saveButtonEditNotSynced,
    CloudSyncStatus.syncing => saveState.hasPendingMediaSync
        ? l10n.saveButtonSyncingMedia
        : l10n.saveButtonSyncing,
    CloudSyncStatus.offline =>
      offlineSyncLabel(
        ref.read(l10nProvider),
        ref.read(openStrategyUnsentChangesProvider),
      ),
    CloudSyncStatus.attention => saveState.mediaSyncErrorCount > 0
        ? l10n.saveButtonMediaNeedsRetry
        : l10n.saveButtonNeedsAttention,
  };
  return (message: message, failed: false);
}

/// The save button of a local strategy. Shows a spinner while an auto-save
/// runs and a green check when it lands, then rests on what is true: a check
/// when everything on the canvas is in the library, the save glyph when
/// something is not.
class AutoSaveButton extends ConsumerStatefulWidget {
  const AutoSaveButton({
    super.key,
    this.style = kEditorToolbarButtonStyle,
  });

  final EditorToolbarButtonStyle style;

  @override
  ConsumerState<AutoSaveButton> createState() => _AutoSaveButtonState();
}

class _AutoSaveButtonState extends ConsumerState<AutoSaveButton> {
  _Phase _phase = _Phase.idle;
  Timer? _successTimer;
  Timer? _idleTimer;
  int _lastPing = 0;

  @override
  void initState() {
    super.initState();
    _lastPing = ref.read(autoSaveProvider);
  }

  @override
  void dispose() {
    _successTimer?.cancel();
    _idleTimer?.cancel();
    super.dispose();
  }

  void _startAutoSaveAnimation() {
    if (!mounted) return;
    _successTimer?.cancel();
    _idleTimer?.cancel();
    setState(() => _phase = _Phase.loading);
    _successTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _phase = _Phase.success);
      _idleTimer = Timer(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() => _phase = _Phase.idle);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final ping = ref.watch(autoSaveProvider);
    final canEditPages = ref.watch(
      currentStrategyCapabilitiesProvider.select(
        (capabilities) => capabilities.canEditPages,
      ),
    );
    final unsaved = ref.watch(
      strategySaveStateProvider.select(
        (saveState) => saveState.isDirty || saveState.isSaving,
      ),
    );

    if (ping != _lastPing) {
      _lastPing = ping;
      _startAutoSaveAnimation();
    }

    final size = widget.style.iconSize;
    final Widget resting = unsaved || !canEditPages
        ? const Icon(LucideIcons.save200, key: ValueKey('idle'))
        : const Icon(LucideIcons.check200, key: ValueKey('saved'));
    final Widget icon = switch (_phase) {
      _Phase.idle => resting,
      _Phase.loading => SizedBox(
          key: const ValueKey('loading'),
          width: size - 2,
          height: size - 2,
          child: LoadingSpinner(
            strokeWidth: 1.8,
            color: Settings.tacticalVioletTheme.mutedForeground,
          ),
        ),
      // An edit made while the spinner ran has not been saved.
      _Phase.success when unsaved => resting,
      _Phase.success => const Icon(
          LucideIcons.check200,
          key: ValueKey('success'),
          color: Settings.allyBGColor,
        ),
    };

    return EditorToolbarButton(
      key: const ValueKey('local-save-button'),
      style: widget.style,
      tooltip: canEditPages
          ? context.l10n.commonSave
          : context.l10n.saveButtonViewOnlyTooltip,
      enabled: canEditPages,
      onPressed: () => saveStrategyNow(context, ref),
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        switchInCurve: Settings.easeOut,
        switchOutCurve: Settings.easeOut.flipped,
        child: icon,
      ),
    );
  }
}

enum _Phase { idle, loading, success }
