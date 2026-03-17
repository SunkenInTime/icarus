import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/center_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/custom_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/resizable_square_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('Square ability icon counter-rotation', () {
    testWidgets('CustomSquareWidget counter-rotates the ability icon',
        (tester) async {
      const rotation = math.pi / 3;

      await _pumpWidget(
        tester,
        CustomSquareWidget(
          color: Colors.green,
          width: 120,
          height: 60,
          distanceBetweenAOE: 12,
          rotation: rotation,
          iconPath: 'assets/agents/Cypher/1.webp',
          id: 'custom-square',
          isAlly: true,
          hasTopborder: false,
          hasSideBorders: false,
          isWall: false,
          isTransparent: false,
        ),
      );

      expect(
        _findAbilityTransformByAngle(tester, expectedAngle: -rotation),
        findsOneWidget,
      );
    });

    testWidgets('CenterSquareWidget counter-rotates the ability icon',
        (tester) async {
      const rotation = math.pi / 4;

      await _pumpWidget(
        tester,
        CenterSquareWidget(
          width: 80,
          height: 80,
          iconPath: 'assets/agents/Cypher/1.webp',
          color: Colors.blue,
          rotation: rotation,
          id: 'center-square',
          isAlly: true,
        ),
      );

      expect(
        _findAbilityTransformByAngle(tester, expectedAngle: -rotation),
        findsOneWidget,
      );
    });

    testWidgets('ResizableSquareWidget counter-rotates the ability icon',
        (tester) async {
      const rotation = math.pi / 6;

      await _pumpWidget(
        tester,
        ResizableSquareWidget(
          color: Colors.red,
          width: 100,
          maxLength: 180,
          minLength: 60,
          iconPath: 'assets/agents/Cypher/1.webp',
          distanceBetweenAOE: 10,
          length: 120,
          id: 'resizable-square',
          isAlly: true,
          isWall: false,
          isTransparent: false,
          hasTopborder: false,
          hasSideBorders: false,
          rotation: rotation,
        ),
      );

      expect(
        _findAbilityTransformByAngle(tester, expectedAngle: -rotation),
        findsOneWidget,
      );
    });

    testWidgets('Zero rotation leaves the icon transform neutral',
        (tester) async {
      await _pumpWidget(
        tester,
        CustomSquareWidget(
          color: Colors.orange,
          width: 100,
          height: 50,
          distanceBetweenAOE: 0,
          rotation: 0,
          iconPath: 'assets/agents/Cypher/1.webp',
          id: 'custom-square-zero',
          isAlly: true,
          hasTopborder: false,
          hasSideBorders: false,
          isWall: false,
          isTransparent: false,
        ),
      );

      expect(
        _findAbilityTransformByAngle(tester, expectedAngle: 0),
        findsOneWidget,
      );
    });
  });
}

Future<void> _pumpWidget(WidgetTester tester, Widget child) async {
  final container = ProviderContainer();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: child,
          ),
        ),
      ),
    ),
  );

  await tester.pump();
}

Finder _findAbilityTransformByAngle(
  WidgetTester tester, {
  required double expectedAngle,
}) {
  return find.byWidgetPredicate((widget) {
    if (widget is! Transform) {
      return false;
    }

    final element = tester.element(find.byWidget(widget));
    final hasAbilityWidgetDescendant = find
        .descendant(
          of: find.byElementPredicate((candidate) => candidate == element),
          matching: find.byType(AbilityWidget),
        )
        .evaluate()
        .isNotEmpty;

    if (!hasAbilityWidgetDescendant) {
      return false;
    }

    final matrix = widget.transform;
    final angle = math.atan2(matrix.entry(1, 0), matrix.entry(0, 0));
    return (angle - expectedAngle).abs() < 0.0001;
  });
}
