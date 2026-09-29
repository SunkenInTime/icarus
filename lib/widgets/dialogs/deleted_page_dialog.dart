import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
      _error = _isGone
          ? null
          : 'Could not restore the page. Check your connection and try '
              'again, or discard your changes.';
    });
  }

  Future<void> _discard() async {
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
      _error = 'Could not leave this page yet: changes to it are still being '
          'sent, or another page could not load. Try again in a moment.';
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

    return ShadDialog.alert(
      title: const Text('This page was deleted'),
      description: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isGone
                ? '“$name” can no longer be restored, so your latest changes '
                    'to it could not be saved.'
                : '“$name” was deleted while you were editing it. Restore it '
                    'to keep your latest changes, or discard them.',
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
            child: const Text('Discard changes'),
          )
        else ...[
          ShadButton.secondary(
            onPressed: _isBusy ? null : _discard,
            child: const Text('Discard changes'),
          ),
          ShadButton(
            onPressed: _isBusy ? null : _restore,
            child: Text(_isRestoring ? 'Restoring…' : 'Restore page'),
          ),
        ],
      ],
    );
  }
}
