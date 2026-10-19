import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Which page a multi-page screenshot is on, of how many; null while the
/// strategy is still being saved.
typedef ScreenshotProgress = ({int page, int total});

/// Shown while several pages are captured: how far along, and a way to stop.
/// It is modal on purpose: a capture switches the app's coordinates to the
/// screenshot's, so the canvas must not take edits until it is done.
class ScreenshotProgressDialog extends StatelessWidget {
  const ScreenshotProgressDialog({
    super.key,
    required this.progress,
    required this.onCancel,
  });

  final ValueListenable<ScreenshotProgress?> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      constraints: const BoxConstraints(maxWidth: 420),
      title: const Text('Capturing screenshots'),
      actions: [
        ShadButton.destructive(
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints.tightFor(width: 372),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: ValueListenableBuilder<ScreenshotProgress?>(
              valueListenable: progress,
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
    );
  }
}
