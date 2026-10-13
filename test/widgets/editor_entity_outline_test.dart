import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/providers/collab/editing_presence_provider.dart';
import 'package:icarus/widgets/draggable_widgets/canonical_positioned.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';
import 'package:icarus/widgets/strategy_presence.dart';

final _teammate = PresencePeer(
  sid: 's-sam',
  uid: 'sam',
  name: 'Sam',
  avatarUrl: null,
  role: 'editor',
  cursor: null,
);

Future<RenderObject> _pumpItem(
  WidgetTester tester, {
  required Widget item,
  Map<String, PresencePeer> editors = const {},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [itemEditorsProvider.overrideWith((ref) => editors)],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 800,
            height: 600,
            child: Stack(
              children: [EditorEntityLayer(id: 'item', child: item)],
            ),
          ),
        ),
      ),
    ),
  );
  return tester.renderObject(
    find.descendant(
      of: find.byType(Listener),
      matching: find.byWidgetPredicate((widget) => widget is Stack),
    ),
  );
}

RRect _outlineAround(Rect box) =>
    RRect.fromRectAndRadius(box.inflate(4), const Radius.circular(6));

void main() {
  testWidgets('an item no teammate is changing has no outline', (
    tester,
  ) async {
    final stack = await _pumpItem(
      tester,
      item: const Positioned(
        left: 100,
        top: 50,
        child: SizedBox(width: 40, height: 40),
      ),
    );

    expect(stack, isNot(paints..rrect()));
  });

  testWidgets('an item a teammate is changing is outlined in their color', (
    tester,
  ) async {
    final stack = await _pumpItem(
      tester,
      editors: {'item': _teammate},
      item: const Positioned(
        left: 100,
        top: 50,
        child: SizedBox(width: 40, height: 40),
      ),
    );

    expect(
      stack,
      paints
        ..rrect(
          rrect: _outlineAround(const Rect.fromLTWH(100, 50, 40, 40)),
          color: presenceColorFor('sam'),
        ),
    );
  });

  testWidgets('a text or image is outlined around its box, not the canvas', (
    tester,
  ) async {
    final stack = await _pumpItem(
      tester,
      editors: {'item': _teammate},
      item: const CanonicalPositionedBox(
        attackScreenPosition: Offset(100, 50),
        isAttack: true,
        child: SizedBox(width: 80, height: 30),
      ),
    );

    expect(
      stack,
      paints
        ..rrect(
          rrect: _outlineAround(const Rect.fromLTWH(100, 50, 80, 30)),
          color: presenceColorFor('sam'),
        ),
    );
  });
}
