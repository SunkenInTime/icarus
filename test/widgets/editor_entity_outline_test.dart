import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/providers/collab/editing_presence_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
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

/// An item whose drawn shape, 40 x 20, sits inside a larger box.
const _item = Positioned(
  left: 100,
  top: 50,
  child: Padding(
    padding: EdgeInsets.all(8),
    child: EditorItemOutline(child: SizedBox(width: 40, height: 20)),
  ),
);

Future<void> _pump(
  WidgetTester tester, {
  required Widget canvas,
  Map<String, PresencePeer> editors = const {},
  double zoom = 1,
}) async {
  final container = ProviderContainer(
    overrides: [itemEditorsProvider.overrideWith((ref) => editors)],
  );
  addTearDown(container.dispose);
  container.read(screenZoomProvider.notifier).updateZoom(zoom);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 800, height: 600, child: canvas),
        ),
      ),
    ),
  );
}

RenderObject _outline(WidgetTester tester) =>
    tester.renderObject(find.byType(EditorItemOutline));

void main() {
  testWidgets('an item no teammate is changing has no outline', (
    tester,
  ) async {
    await _pump(
      tester,
      canvas: const Stack(
        children: [EditorEntityLayer(id: 'item', child: _item)],
      ),
      editors: {'other': _teammate},
    );

    expect(_outline(tester), isNot(paints..rrect()));
  });

  testWidgets('an item a teammate is changing is outlined in their color', (
    tester,
  ) async {
    await _pump(
      tester,
      canvas: const Stack(
        children: [EditorEntityLayer(id: 'item', child: _item)],
      ),
      editors: {'item': _teammate},
    );

    // Around the marked shape, wherever it sits in the item.
    expect(
      _outline(tester),
      paints
        ..rrect(
          rrect: RRect.fromRectAndRadius(
            const Rect.fromLTWH(0, 0, 40, 20).inflate(4),
            const Radius.circular(6),
          ),
          color: presenceColorFor('sam'),
          strokeWidth: 2,
        ),
    );
  });

  testWidgets('the outline keeps its width on screen when zoomed', (
    tester,
  ) async {
    await _pump(
      tester,
      canvas: const Stack(
        children: [EditorEntityLayer(id: 'item', child: _item)],
      ),
      editors: {'item': _teammate},
      zoom: 2,
    );

    expect(
      _outline(tester),
      paints
        ..rrect(
          rrect: RRect.fromRectAndRadius(
            const Rect.fromLTWH(0, 0, 40, 20).inflate(2),
            const Radius.circular(3),
          ),
          strokeWidth: 1,
        ),
    );
  });

  testWidgets('a shape outside an item layer (a drag, an export) is bare', (
    tester,
  ) async {
    await _pump(
      tester,
      canvas: const Stack(children: [_item]),
      editors: {'item': _teammate},
    );

    expect(_outline(tester), isNot(paints..rrect()));
  });
}
