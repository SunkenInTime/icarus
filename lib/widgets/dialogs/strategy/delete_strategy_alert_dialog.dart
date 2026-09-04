import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DeleteStrategyAlertDialog extends ConsumerStatefulWidget {
  const DeleteStrategyAlertDialog({
    super.key,
    required this.strategyID,
    required this.name,
    required this.source,
  });
  final String strategyID;
  final String name;
  final StrategySource source;

  @override
  ConsumerState<DeleteStrategyAlertDialog> createState() =>
      _DeleteStrategyAlertDialogState();
}

class _DeleteStrategyAlertDialogState
    extends ConsumerState<DeleteStrategyAlertDialog> {
  bool _isDeleting = false;
  String? _failureMessage;

  Future<void> _delete() async {
    if (_isDeleting) return;
    setState(() {
      _isDeleting = true;
      _failureMessage = null;
    });

    CloudLibraryActionResult? result;
    try {
      result = await ref.read(strategyProvider.notifier).deleteStrategy(
            widget.strategyID,
            source: widget.source,
          );
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Failed to delete a strategy.',
        source: 'strategy_dialog:delete',
        error: error,
        stackTrace: stackTrace,
        promptUser: false,
      );
      if (mounted) {
        setState(() {
          _failureMessage = "Couldn't delete this strategy. Try again.";
        });
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
    if (!mounted) return;
    if (result?.didSucceed == true) {
      Navigator.of(context).pop();
      return;
    }
    if (result != null) {
      setState(() => _failureMessage =
          result!.userMessage ?? "Couldn't delete this strategy. Try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog.alert(
      title: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: "Delete "),
            TextSpan(
              text: widget.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      description: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: "Are you sure you want to delete "),
                TextSpan(
                  text: widget.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: "? This action cannot be undone."),
              ],
            ),
          ),
          if (_failureMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _failureMessage!,
              key: const ValueKey('delete-strategy-failure'),
              style: TextStyle(
                color: Settings.tacticalVioletTheme.destructive,
              ),
            ),
          ],
        ],
      ),
      actions: [
        ShadButton.secondary(
          onPressed: _isDeleting ? null : () => Navigator.of(context).pop(),
          child: const Text(
            "Cancel",
          ),
        ),
        ShadButton.destructive(
          key: const ValueKey('delete-strategy-confirm'),
          onPressed: _isDeleting ? null : _delete,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.delete_forever,
                color: Settings.tacticalVioletTheme.destructiveForeground,
              ),
              const SizedBox(width: 5),
              Text(
                _isDeleting ? 'Deleting...' : 'Delete',
                style: TextStyle(
                  color: Settings.tacticalVioletTheme.destructiveForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
