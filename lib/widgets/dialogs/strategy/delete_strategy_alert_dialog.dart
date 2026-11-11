import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
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
    final l10n = context.l10n;
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
          _failureMessage = l10n.deleteStrategyFailed;
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
      setState(() =>
          _failureMessage = result!.userMessage ?? l10n.deleteStrategyFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ShadDialog.alert(
      title: Text.rich(
        TextSpan(
          children: _withBoldName(l10n.deleteStrategyTitle(_nameMarker)),
        ),
      ),
      description: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: _withBoldName(l10n.deleteStrategyConfirm(_nameMarker)),
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
          child: Text(
            l10n.commonCancel,
          ),
        ),
        ShadButton.destructive(
          key: const ValueKey('delete-strategy-confirm'),
          onPressed: _isDeleting ? null : _delete,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                LucideIcons.trash2,
                color: Settings.tacticalVioletTheme.destructiveForeground,
              ),
              const SizedBox(width: 5),
              Text(
                _isDeleting ? l10n.deleteStrategyDeleting : l10n.commonDelete,
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

  static const _nameMarker = '\u{E000}';

  /// [message] with the strategy's name, in bold, where [_nameMarker] is.
  List<InlineSpan> _withBoldName(String message) {
    final parts = message.split(_nameMarker);
    return [
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0)
          TextSpan(
            text: widget.name,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        if (parts[i].isNotEmpty) TextSpan(text: parts[i]),
      ],
    ];
  }
}
