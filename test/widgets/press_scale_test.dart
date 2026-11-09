import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
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

  testWidgets('the press is painted about the middle, not a corner',
      (tester) async {
    final frame = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: frame,
            child: SizedBox(
              width: 200,
              height: 100,
              child: Center(
                child: PressScale(
                  child: Container(
                    width: 80,
                    height: 40,
                    color: const Color(0xFFFFFFFF),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // The white box's edges, read from the painted pixels.
    Future<Rect> paintedBox() async {
      final boundary =
          frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage();
        return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      }))!;
      double white(int x, int y) => bytes.getUint8((y * 200 + x) * 4) / 255;
      final row = [for (var x = 0; x < 200; x++) white(x, 50)];
      final column = [for (var y = 0; y < 100; y++) white(100, y)];
      final width = row.reduce((a, b) => a + b);
      final height = column.reduce((a, b) => a + b);
      final left = row.takeWhile((c) => c < 1).fold(0.0, (a, c) => a + 1 - c);
      final top = column.takeWhile((c) => c < 1).fold(0.0, (a, c) => a + 1 - c);
      return Rect.fromLTWH(left, top, width, height);
    }

    final rest = await paintedBox();
    await tester.startGesture(tester.getCenter(find.byType(PressScale)));
    await tester.pump();
    await tester.pump(Settings.pressDuration);
    final held = await paintedBox();

    expect(held.width, closeTo(rest.width * Settings.pressScale, 0.05));
    expect(held.center.dx, closeTo(rest.center.dx, 0.05));
    expect(held.center.dy, closeTo(rest.center.dy, 0.05));
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
