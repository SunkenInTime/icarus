import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Tells the user that the page on screen was deleted (by a teammate,
/// almost always) while it held their unsaved work, and lets them restore
/// the page, which saves that work, or discard the work. The canvas stays on the page until they
/// choose, so the dialog cannot be dismissed any other way.
class DeletedPageDialog extends ConsumerStatefulWidget {
  const DeletedPageDialog({super.key, required this.page});

  final DeletedPage page;

  static Future<void> show(BuildContext context, DeletedPage page) {
    return showShadDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => DeletedPageDialog(page: page),
    );
  }

  @override
  ConsumerState<DeletedPageDialog> createState() => _DeletedPageDialogState();
}

class _DeletedPageDialogState extends ConsumerState<DeletedPageDialog> {
  bool _isRestoring = false;
  bool _isLeaving = false;

  /// The server can no longer restore the page; discarding is all that is
  /// left.
  bool _isGone = false;
  String? _error;

  bool get _isBusy => _isRestoring || _isLeaving;

  Future<void> _restore() async {
    final l10n = context.l10n;
    setState(() {
      _isRestoring = true;
      _error = null;
    });
    final outcome = await ref
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();
    if (!mounted) return;
    if (outcome == DeletedPageRestore.restored) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _isRestoring = false;
      _isGone = outcome == DeletedPageRestore.gone;
      _error = _isGone ? null : l10n.deletedPageRestoreFailed;
    });
  }

  Future<void> _discard() async {
    final l10n = context.l10n;
    setState(() {
      _isLeaving = true;
      _error = null;
    });
    final left =
        await ref.read(strategyPageSessionProvider.notifier).leaveDeletedPage();
    if (!mounted) return;
    if (left) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _isLeaving = false;
      _error = l10n.deletedPageLeaveFailed;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Leaving the strategy resets the session; nothing is left to read.
    ref.listen(strategyPageSessionProvider.select((state) => state.deletedPage),
        (_, next) {
      if (next == null && !_isBusy) Navigator.of(context).pop();
    });
    final theme = ShadTheme.of(context);
    final name = widget.page.name;
    final l10n = context.l10n;

    return ShadDialog.alert(
      title: Text(l10n.deletedPageTitle),
      description: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isGone
                ? l10n.deletedPageGone(name)
                : l10n.deletedPageDescription(name),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.destructive),
            ),
          ],
        ],
      ),
      actions: [
        if (_isGone)
          ShadButton(
            onPressed: _isBusy ? null : _discard,
            child: Text(l10n.deletedPageDiscardChanges),
          )
        else ...[
          ShadButton.secondary(
            onPressed: _isBusy ? null : _discard,
            child: Text(l10n.deletedPageDiscardChanges),
          ),
          ShadButton(
            onPressed: _isBusy ? null : _restore,
            child: Text(_isRestoring
                ? l10n.deletedPageRestoring
                : l10n.deletedPageRestore),
          ),
        ],
      ],
    );
  }
}
