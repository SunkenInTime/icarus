import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Asks what happens to unsaved work on the page on screen after a teammate
/// deleted it: restore the page with the work, or discard the work. The
/// session keeps the canvas on the page until one is chosen, so the dialog
/// cannot be dismissed without choosing.
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
  bool _isBusy = false;
  String? _error;

  Future<void> _restore() async {
    setState(() {
      _isBusy = true;
      _error = null;
    });
    final restored = await ref
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();
    if (!mounted) return;
    if (restored) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _isBusy = false;
      _error = 'Could not restore the page. Your changes are still on '
          'screen. Check your connection and try again.';
    });
  }

  Future<void> _discard() async {
    setState(() {
      _isBusy = true;
      _error = null;
    });
    await ref
        .read(strategyPageSessionProvider.notifier)
        .discardDeletedPageWork();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Leaving the strategy resets the session; nothing is left to decide.
    ref.listen(strategyPageSessionProvider.select((state) => state.deletedPage),
        (_, next) {
      if (next == null && !_isBusy) Navigator.of(context).pop();
    });
    final theme = ShadTheme.of(context);

    return ShadDialog.alert(
      title: const Text('A teammate deleted this page'),
      description: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '“${widget.page.name}” was deleted while you were editing it, so '
            'your latest changes to it are not saved. Restore the page with '
            'your changes, or discard them.',
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
        ShadButton.secondary(
          onPressed: _isBusy ? null : _discard,
          child: const Text('Discard changes'),
        ),
        ShadButton(
          onPressed: _isBusy ? null : _restore,
          child: const Text('Restore page'),
        ),
      ],
    );
  }
}
