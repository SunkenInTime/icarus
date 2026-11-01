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
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Opened from a menu that is still closing, which hands focus back to the
    // canvas: an autofocus here would lose it, and the note would be typed
    // into the app's shortcuts.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeFocus());
    Future<void>.delayed(const Duration(milliseconds: 250), _takeFocus);
  }

  void _takeFocus() {
    if (mounted && !_focus.hasFocus) _focus.requestFocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Keeps what's typed in this dialog away from the app's shortcuts, wherever
  /// focus is in it. Keys that work the dialog itself still pass.
  KeyEventResult _keepKey(FocusNode node, KeyEvent event) {
    final dialogKeys = {
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.space,
    };
    return dialogKeys.contains(event.logicalKey)
        ? KeyEventResult.ignored
        : KeyEventResult.skipRemainingHandlers;
  }

  void _done() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final muted = ShadTheme.of(context).textTheme.muted;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _keepKey,
      child: ShadDialog(
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
                focusNode: _focus,
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
      ),
    );
  }
}
