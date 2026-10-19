import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Which page a multi-page screenshot is on, of how many; null while the
/// strategy is still being saved.
typedef ScreenshotProgress = ({int page, int total});

/// Shown while several pages are captured: how far along, and a way to stop.
///
/// It stays up until the capture has stopped, and only the app closes it: a
/// capture switches the app's coordinates to the screenshot's, so the canvas
/// must not take a click or a drag until it is done. Cancel asks the capture
/// to stop and says so; the dialog closes once it has.
class ScreenshotProgressDialog extends StatefulWidget {
  const ScreenshotProgressDialog({
    super.key,
    required this.progress,
    required this.onCancel,
  });

  final ValueListenable<ScreenshotProgress?> progress;
  final VoidCallback onCancel;

  @override
  State<ScreenshotProgressDialog> createState() =>
      _ScreenshotProgressDialogState();
}

class _ScreenshotProgressDialogState extends State<ScreenshotProgressDialog> {
  bool _cancelling = false;

  void _cancel() {
    setState(() => _cancelling = true);
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: ShadDialog(
        constraints: const BoxConstraints(maxWidth: 420),
        title: const Text('Capturing screenshots'),
        closeIcon: const SizedBox.shrink(),
        actions: [
          ShadButton.destructive(
            enabled: !_cancelling,
            onPressed: _cancel,
            child: Text(_cancelling ? 'Cancelling…' : 'Cancel'),
          ),
        ],
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints.tightFor(width: 372),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: ValueListenableBuilder<ScreenshotProgress?>(
                valueListenable: widget.progress,
                builder: (context, value, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      value == null
                          ? 'Saving your changes'
                          : 'Page ${value.page} of ${value.total}',
                      style: TextStyle(color: colors.foreground),
                    ),
                    const SizedBox(height: 12),
                    ShadProgress(
                      value: value == null ? 0 : (value.page - 1) / value.total,
                      minHeight: 8,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
