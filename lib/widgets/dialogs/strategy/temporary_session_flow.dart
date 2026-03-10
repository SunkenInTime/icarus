import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/dialogs/strategy/save_strategy_details_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum TemporarySaveIntent {
  cancel,
  overwriteOriginal,
  saveAsNew,
  discard,
}

Future<TemporarySaveIntent?> _showTemporaryCopyDialog(
  BuildContext context, {
  required bool includeDiscard,
}) {
  return showShadDialog<TemporarySaveIntent>(
    context: context,
    builder: (context) => ShadDialog(
      title: const Text('Save Temporary Changes?'),
      description: const Text(
        'Choose where to apply this temporary copy before leaving.',
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () =>
              Navigator.of(context).pop(TemporarySaveIntent.cancel),
          child: const Text('Cancel'),
        ),
        if (includeDiscard)
          ShadButton.secondary(
            onPressed: () =>
                Navigator.of(context).pop(TemporarySaveIntent.discard),
            child: const Text('Discard'),
          ),
        ShadButton.secondary(
          onPressed: () =>
              Navigator.of(context).pop(TemporarySaveIntent.saveAsNew),
          child: const Text('Save as New'),
        ),
        ShadButton(
          onPressed: () =>
              Navigator.of(context).pop(TemporarySaveIntent.overwriteOriginal),
          child: const Text('Overwrite Original'),
        ),
      ],
    ),
  );
}

Future<TemporarySaveIntent?> _showQuickBoardDialog(
  BuildContext context, {
  required bool includeDiscard,
}) {
  return showShadDialog<TemporarySaveIntent>(
    context: context,
    builder: (context) => ShadDialog(
      title: const Text('Save Quick Board?'),
      description: const Text(
        'Quick Boards are temporary. Save now or discard this session.',
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () =>
              Navigator.of(context).pop(TemporarySaveIntent.cancel),
          child: const Text('Cancel'),
        ),
        if (includeDiscard)
          ShadButton.secondary(
            onPressed: () =>
                Navigator.of(context).pop(TemporarySaveIntent.discard),
            child: const Text('Discard'),
          ),
        ShadButton(
          onPressed: () => Navigator.of(context).pop(TemporarySaveIntent.saveAsNew),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<bool> resolveTemporarySessionForNavigation({
  required BuildContext context,
  required WidgetRef ref,
}) async {
  final strategyState = ref.read(strategyProvider);
  if (!strategyState.isTemporarySession) return true;
  final strategyNotifier = ref.read(strategyProvider.notifier);

  final intent = strategyState.isQuickBoard
      ? await _showQuickBoardDialog(context, includeDiscard: true)
      : await _showTemporaryCopyDialog(context, includeDiscard: true);
  if (intent == null || intent == TemporarySaveIntent.cancel) return false;

  if (intent == TemporarySaveIntent.discard) {
    await strategyNotifier.discardTemporarySession();
    return true;
  }
  if (intent == TemporarySaveIntent.overwriteOriginal) {
    await strategyNotifier.overwriteOriginalFromTemporaryCopy();
    return true;
  }

  final sourceName = strategyState.stratName ?? 'Strategy';
  final sourceStrategy = strategyNotifier.currentStrategyData();
  final details = await showStrategySaveDetailsDialog(
    context: context,
    title: strategyState.isQuickBoard ? 'Save Quick Board' : 'Save as New',
    confirmLabel: 'Save',
    initialName: strategyState.isQuickBoard ? sourceName : '$sourceName (Copy)',
    initialFolderId: sourceStrategy?.folderID,
  );
  if (details == null) return false;
  await strategyNotifier.saveTemporarySessionAsNewStrategy(
    name: details.name,
    folderID: details.folderId,
  );
  return true;
}

Future<bool> resolveTemporarySessionForManualSave({
  required BuildContext context,
  required WidgetRef ref,
}) async {
  final strategyState = ref.read(strategyProvider);
  if (!strategyState.isTemporarySession) {
    await ref
        .read(strategyProvider.notifier)
        .forceSaveNow(ref.read(strategyProvider).id);
    return true;
  }
  final strategyNotifier = ref.read(strategyProvider.notifier);

  if (strategyState.isTemporaryCopy) {
    final intent =
        await _showTemporaryCopyDialog(context, includeDiscard: false);
    if (intent == null || intent == TemporarySaveIntent.cancel) return false;
    if (intent == TemporarySaveIntent.overwriteOriginal) {
      await strategyNotifier.overwriteOriginalFromTemporaryCopy();
      return true;
    }
  }

  final sourceName = strategyState.stratName ?? 'Strategy';
  final sourceStrategy = strategyNotifier.currentStrategyData();
  final details = await showStrategySaveDetailsDialog(
    context: context,
    title: strategyState.isQuickBoard ? 'Save Quick Board' : 'Save as New',
    confirmLabel: 'Save',
    initialName: strategyState.isQuickBoard ? sourceName : '$sourceName (Copy)',
    initialFolderId: sourceStrategy?.folderID,
  );
  if (details == null) return false;
  await strategyNotifier.saveTemporarySessionAsNewStrategy(
    name: details.name,
    folderID: details.folderId,
  );
  return true;
}
