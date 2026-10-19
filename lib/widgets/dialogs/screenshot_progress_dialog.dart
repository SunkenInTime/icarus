import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Which page a multi-page screenshot is on, of how many; null while the
/// strategy is still being saved.
typedef ScreenshotProgress = ({int page, int total});

/// Shown while several pages are captured: how far along, and a way to stop.
///
/// It stays up until the capture has stopped, so a cancelled capture never
/// looks finished while it is still writing. Cancel asks the capture to stop
/// and says so; when [done] turns true the dialog closes its own route, even
/// if another dialog has opened above it meanwhile.
class ScreenshotProgressDialog extends StatefulWidget {
  const ScreenshotProgressDialog({
    super.key,
    required this.progress,
    required this.done,
    required this.onCancel,
  });

  final ValueListenable<ScreenshotProgress?> progress;
  final ValueListenable<bool> done;
  final VoidCallback onCancel;

  @override
  State<ScreenshotProgressDialog> createState() =>
      _ScreenshotProgressDialogState();
}

class _ScreenshotProgressDialogState extends State<ScreenshotProgressDialog> {
  bool _cancelling = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.done.addListener(_closeWhenDone);
    // The capture may have finished before the dialog first built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _closeWhenDone());
  }

  @override
  void dispose() {
    widget.done.removeListener(_closeWhenDone);
    super.dispose();
  }

  void _closeWhenDone() {
    if (_closed || !mounted || !widget.done.value) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _closed = true;
    final navigator = Navigator.of(context);
    // Pop only when this dialog is on top; under another dialog, take out
    // just this one.
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

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
