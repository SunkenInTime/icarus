import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/hover_dot_grid.dart';

// Its own file: HoverDotGrid caches the shader load in a static, and a load
// started inside another test's fake clock never finishes for this one.
void main() {
  late Directory tempDir;

  setUpAll(() {
    registerIcarusAdapters(Hive);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-hover-glow-');
    Hive.init(tempDir.path);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('turning hidden dots back on shows no stale glow',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    Future<void> setOpacity(double value) => tester.runAsync(() => container
        .read(appPreferencesProvider.notifier)
        .setBackgroundDotOpacity(value));
    Future<void> frames() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 200, height: 200, child: HoverDotGrid()),
        ),
      ),
    );
    // The shader loads on the real event loop.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    double glow() {
      final paint = tester.widget<CustomPaint>(find.descendant(
        of: find.byType(HoverDotGrid),
        matching: find.byType(CustomPaint),
      ));
      return (paint.painter as dynamic).hover as double;
    }

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(50, 50));
    await mouse.moveTo(const Offset(80, 80));
    await frames();
    expect(glow(), greaterThan(0.5));

    // Hide the dots, then leave the grid while they're hidden.
    await setOpacity(0);
    await tester.pump();
    await mouse.moveTo(const Offset(400, 400));
    await mouse.removePointer();

    await setOpacity(1);
    await frames();
    expect(glow(), 0);
  });
}
