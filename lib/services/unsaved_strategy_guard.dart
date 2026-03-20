import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum UnsavedStrategyDecision {
  save,
  dontSave,
  cancel,
}

Future<UnsavedStrategyDecision> showUnsavedStrategyDialog(
  BuildContext context,
) async {
  final result = await showShadDialog<UnsavedStrategyDecision>(
    context: context,
    builder: (context) {
      return ShadDialog.alert(
        title: const Text('Save changes?'),
        description: const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'This strategy has unsaved changes. Do you want to save before leaving?',
          ),
        ),
        actions: [
          ShadButton.secondary(
            onPressed: () {
              Navigator.of(context).pop(UnsavedStrategyDecision.cancel);
            },
            child: const Text('Cancel'),
          ),
          ShadButton.destructive(
            onPressed: () {
              Navigator.of(context).pop(UnsavedStrategyDecision.dontSave);
            },
            child: const Text("Don't Save"),
          ),
          ShadButton(
            onPressed: () {
              Navigator.of(context).pop(UnsavedStrategyDecision.save);
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );

  return result ?? UnsavedStrategyDecision.cancel;
}

Future<bool> guardUnsavedStrategyExit({
  required BuildContext context,
  required WidgetRef ref,
  required Future<void> Function() onContinue,
  required String source,
}) async {
  final strategyState = ref.read(strategyProvider);
  if (strategyState.stratName == null || strategyState.isSaved) {
    await onContinue();
    return true;
  }

  final decision = await showUnsavedStrategyDialog(context);
  switch (decision) {
    case UnsavedStrategyDecision.save:
      try {
        await ref
            .read(strategyProvider.notifier)
            .forceSaveNow(strategyState.id);
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          'Failed to save strategy before leaving.',
          error: error,
          stackTrace: stackTrace,
          source: source,
        );
        return false;
      }
      await onContinue();
      return true;
    case UnsavedStrategyDecision.dontSave:
      ref.read(strategyProvider.notifier).cancelPendingSave();
      await onContinue();
      return true;
    case UnsavedStrategyDecision.cancel:
      return false;
  }
}
