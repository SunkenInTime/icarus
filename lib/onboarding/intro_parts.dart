import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/widgets/window_chrome.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

double eased(double ms, double from, double to) =>
    Settings.easeOut.transform(((ms - from) / (to - from)).clamp(0.0, 1.0));

Ticker whenFramesAreCalm(TickerProvider vsync, VoidCallback onCalm) {
  const calmGap = Duration(milliseconds: 50);
  const longestWait = Duration(milliseconds: 1500);
  var last = Duration.zero;
  var calmFrames = 0;
  late final Ticker ticker;
  ticker = vsync.createTicker((elapsed) {
    final gap = elapsed - last;
    last = elapsed;
    final calm = elapsed > Duration.zero && gap < calmGap;
    calmFrames = calm ? calmFrames + 1 : 0;
    if (calmFrames < 2 && elapsed < longestWait) return;
    ticker.stop();
    onCalm();
  });
  return ticker..start();
}

class BareStrip extends StatelessWidget {
  const BareStrip({super.key, this.onSkip});

  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kWindowStripHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MacTrafficLightInset(),
          const Expanded(child: WindowDragArea(child: SizedBox.expand())),
          if (onSkip != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ShadButton.ghost(
                  key: const ValueKey('onboarding-skip'),
                  size: ShadButtonSize.sm,
                  foregroundColor: Settings.tacticalVioletTheme.mutedForeground,
                  hoverForegroundColor: Settings.tacticalVioletTheme.foreground,
                  onPressed: onSkip,
                  child: Text(context.l10n.onboardingSkip),
                ),
              ),
            ),
          const WindowCaptionButtons(),
        ],
      ),
    );
  }
}

class KeyCapture extends StatefulWidget {
  const KeyCapture({super.key, required this.onKey, required this.child});

  final ValueChanged<KeyEvent> onKey;
  final Widget child;

  @override
  State<KeyCapture> createState() => _KeyCaptureState();
}

class _KeyCaptureState extends State<KeyCapture> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_capture);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_capture);
    super.dispose();
  }

  KeyEventResult _capture(KeyEvent event) {
    widget.onKey(event);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
