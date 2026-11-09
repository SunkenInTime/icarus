import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/press_scale.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

Widget _press(
  BuildContext context, {
  required bool pressable,
  required Widget child,
}) =>
    PressScale(enabled: pressable, child: child);

Future<void> _pumpButton(
  WidgetTester tester, {
  VoidCallback? onPressed,
  double width = 100,
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    ShadApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: ShadButtonWrapper(
          wrap: _press,
          child: Center(
            child: ShadButton(
              width: width,
              onPressed: onPressed,
              child: const Text('Save'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The scale the button's label is drawn at, 1 at rest.
double _paintedScale(WidgetTester tester) {
  final label = find.text('Save');
  final rect = tester.getRect(label);
  return rect.width / tester.getSize(label).width;
}

void main() {
  testWidgets('a held Shad button shrinks and comes back on release',
      (tester) async {
    await _pumpButton(tester, onPressed: () {});
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ShadButton)),
    );
    await tester.pump();
    // It starts on pointer down, before the tap is decided.
    await tester.pump(const Duration(milliseconds: 16));
    expect(_paintedScale(tester), lessThan(1));

    await tester.pump(Settings.pressDuration);
    expect(_paintedScale(tester), closeTo(Settings.pressScale, 1e-9));

    await gesture.up();
    await tester.pump();
    await tester.pump(Settings.pressDuration);
    expect(_paintedScale(tester), 1);
  });

  testWidgets('a press whose release was lost lets go on the next hover',
      (tester) async {
    await _pumpButton(tester, onPressed: () {});
    final center = tester.getCenter(find.byType(ShadButton));
    await tester.startGesture(center, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.pump(Settings.pressDuration);
    expect(_paintedScale(tester), closeTo(Settings.pressScale, 1e-9));

    // The up never arrives; the same mouse comes back with no button held.
    await tester.sendEventToBinding(
      PointerHoverEvent(
        kind: PointerDeviceKind.mouse,
        device: 1, // every test mouse is device 1
        position: center,
      ),
    );
    await tester.pump();
    await tester.pump(Settings.pressDuration);
    expect(_paintedScale(tester), 1);
  });

  testWidgets('the click lands on release, no later than without the press',
      (tester) async {
    var clicks = 0;
    await _pumpButton(tester, onPressed: () => clicks++);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ShadButton)),
    );
    await gesture.up();
    expect(clicks, 1);
  });

  testWidgets('a button without onPressed does not press', (tester) async {
    await _pumpButton(tester);
    await tester.startGesture(tester.getCenter(find.byType(ShadButton)));
    await tester.pump();
    await tester.pump(Settings.pressDuration);
    expect(_paintedScale(tester), 1);
  });

  testWidgets('a right-click does not press', (tester) async {
    await _pumpButton(tester, onPressed: () {});
    await tester.startGesture(
      tester.getCenter(find.byType(ShadButton)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump();
    await tester.pump(Settings.pressDuration);
    expect(_paintedScale(tester), 1);
  });

  testWidgets('a wide button shrinks less', (tester) async {
    await _pumpButton(tester, onPressed: () {}, width: 400);
    await tester.startGesture(tester.getCenter(find.byType(ShadButton)));
    await tester.pump();
    await tester.pump(Settings.pressDuration);
    // Its edges move in by pressMaxInset, not 3% of 400 px.
    expect(
      _paintedScale(tester),
      closeTo(1 - 2 * Settings.pressMaxInset / 400, 1e-9),
    );
  });

  testWidgets('with reduced motion the press snaps', (tester) async {
    await _pumpButton(tester, onPressed: () {}, disableAnimations: true);
    await tester.startGesture(tester.getCenter(find.byType(ShadButton)));
    await tester.pump();
    await tester.pump();
    expect(_paintedScale(tester), closeTo(Settings.pressScale, 1e-9));
  });
}
