import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Tells the user that a teammate deleted the page on screen and their
/// unsaved work on it cannot be saved. The canvas stays on the page until
/// they have read it, so the dialog cannot be dismissed any other way.
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

  Future<void> _leave() async {
    setState(() {
      _isBusy = true;
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
      _isBusy = false;
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

    return ShadDialog.alert(
      title: const Text('A teammate deleted this page'),
      description: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '“${widget.page.name}” was deleted while you were editing it, so '
            'your latest changes to it could not be saved.',
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
        ShadButton(
          onPressed: _isBusy ? null : _leave,
          child: const Text('OK'),
        ),
      ],
    );
  }
}
