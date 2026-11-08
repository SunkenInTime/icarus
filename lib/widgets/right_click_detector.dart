import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Detects right-clicks on [child]. Use this, not a [GestureDetector]'s
/// onSecondaryTap callbacks.
///
/// A right-click here is never part of another gesture: it is this widget's
/// as soon as the button goes down. In a [GestureDetector] it can lose to a
/// pinch. On a Mac, a two-finger tap on the trackpad first starts a trackpad
/// pan/zoom, and while the fingers are down the right-click arrives. The
/// canvas's [InteractiveViewer] is already following the pan/zoom, takes the
/// right-click as one more finger of the same pinch and wins it, so the tap
/// never fires.
///
/// The deepest [RightClickDetector] under the pointer gets the right-click.
class RightClickDetector extends StatelessWidget {
  const RightClickDetector({
    super.key,
    this.onDown,
    this.onUp,
    this.onClick,
    this.behavior,
    required this.child,
  });

  final GestureTapDownCallback? onDown;
  final GestureTapUpCallback? onUp;
  final GestureTapCallback? onClick;
  final HitTestBehavior? behavior;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: behavior,
      gestures: {
        _RightClickRecognizer:
            GestureRecognizerFactoryWithHandlers<_RightClickRecognizer>(
          () => _RightClickRecognizer(debugOwner: this),
          (recognizer) => recognizer
            ..onSecondaryTapDown = onDown
            ..onSecondaryTapUp = onUp
            ..onSecondaryTap = onClick,
        ),
      },
      child: child,
    );
  }
}

class _RightClickRecognizer extends TapGestureRecognizer {
  _RightClickRecognizer({super.debugOwner})
      : super(allowedButtonsFilter: (buttons) => buttons == kSecondaryButton);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    // Claimed while the arena is still open. The first claim wins, and the
    // deepest detector under the pointer claims first.
    resolvePointer(event.pointer, GestureDisposition.accepted);
  }
}
