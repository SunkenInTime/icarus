import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The longest note an item can keep.
const captionMaxLength = 2000;

/// Asks for an item's caption, starting from [initial]. Returns what the user
/// finished with, empty when they cleared it, or null when they backed out.
Future<String?> showCaptionDialog(
  BuildContext context, {
  required String initial,
}) {
  return showShadDialog<String>(
    context: context,
    builder: (_) => _CaptionDialog(initial: initial),
  );
}

class _CaptionDialog extends StatefulWidget {
  const _CaptionDialog({required this.initial});

  final String initial;

  @override
  State<_CaptionDialog> createState() => _CaptionDialogState();
}

class _CaptionDialogState extends State<_CaptionDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _done() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final muted = ShadTheme.of(context).textTheme.muted;
    return ShadDialog(
      title: Text(widget.initial.isEmpty ? 'Create caption' : 'Edit caption'),
      constraints: const BoxConstraints(maxWidth: 520),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShadInput(
              controller: _controller,
              autofocus: true,
              minLines: 6,
              maxLines: 10,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              inputFormatters: [
                LengthLimitingTextInputFormatter(captionMaxLength),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text('Links open when clicked.', style: muted),
                ),
                ShadButton(
                  onPressed: _done,
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
