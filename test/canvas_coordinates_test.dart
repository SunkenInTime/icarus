import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/widgets/canvas_coordinates.dart';

class _Canvas extends StatefulWidget {
  const _Canvas();

  @override
  State<_Canvas> createState() => _CanvasState();
}

class _CanvasState extends State<_Canvas> with CanvasCoordinates {
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          layOutCoordinates(Size(height * 16 / 9, height));
          return const SizedBox.expand();
        },
      );
}

/// A screen without a canvas that sets the coordinates as it builds, the way
/// the library did under the editor before #405.
class _Stray extends StatelessWidget {
  const _Stray();

  @override
  Widget build(BuildContext context) {
    CoordinateSystem(playAreaSize: const Size(1440, 810));
    return const SizedBox.expand();
  }
}

void main() {
  testWidgets('a canvas on screen reports coordinates something replaced',
      (tester) async {
    await tester.pumpWidget(const _Canvas());
    expect(tester.takeException(), isNull);

    CoordinateSystem(playAreaSize: const Size(1440, 810));
    tester.binding.scheduleFrame();
    await tester.pump();

    final error = tester.takeException();
    expect(error, isA<FlutterError>());
    expect(
      '$error',
      allOf(
        contains('Something replaced the canvas coordinates.'),
        contains('1440.0×810.0'),
      ),
    );

    // Once per wrong size, not once per frame.
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen under the canvas that sets the coordinates is caught',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const _Stray(),
    ));
    navigatorKey.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => const _Canvas()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    tester.element(find.byType(_Stray, skipOffstage: false)).markNeedsBuild();
    await tester.pump();

    expect(tester.takeException(), isA<FlutterError>());
  });

  testWidgets('a canvas covered by another leaves the coordinates to it',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const _Canvas(),
    ));
    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Padding(
        padding: EdgeInsets.only(top: 100),
        child: _Canvas(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Back on screen, the canvas underneath takes them back.
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
        CoordinateSystem.instance.playAreaSize, const Size(600 * 16 / 9, 600));
  });

  test('only a canvas sets the coordinates', () {
    final setters = <String>[];
    final construction = RegExp(r'(?<!factory )\bCoordinateSystem\(');
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      if (construction.hasMatch(file.readAsStringSync())) {
        setters.add(file.path.replaceAll(r'\', '/'));
      }
    }
    // Every canvas sets them through CanvasCoordinates.layOutCoordinates,
    // which checks them; a screen that works the canvas size out on its own
    // goes stale the day the canvas layout changes (#405).
    expect(setters, ['lib/widgets/canvas_coordinates.dart']);
  });
}
