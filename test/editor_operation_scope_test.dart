import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/editor_operation_provider.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

void main() {
  for (final cancel in [false, true]) {
    testWidgets(
        'pointer ${cancel ? 'cancel' : 'up'} releases after gesture callbacks',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var protectedDuringCommit = false;
      var committed = false;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: EditorOperationScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (_) {},
              onPanEnd: (_) {
                protectedDuringCommit =
                    container.read(editorPointersProvider).isNotEmpty;
                committed = true;
              },
              onPanCancel: () {
                protectedDuringCommit =
                    container.read(editorPointersProvider).isNotEmpty;
                committed = true;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ));
      final gesture = await tester.startGesture(const Offset(100, 100));
      await gesture.moveBy(const Offset(60, 0));
      expect(container.read(editorPointersProvider), isNotEmpty);
      if (cancel) {
        await gesture.cancel();
      } else {
        await gesture.up();
      }
      await tester.pump();
      expect(committed, isTrue);
      expect(protectedDuringCommit, isTrue);
      expect(container.read(editorPointersProvider), isEmpty);
    });
  }

  testWidgets(
      'all pointers must finish and unmount releases remaining pointers',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const EditorOperationScope(child: SizedBox.expand()),
    ));
    final first = await tester.startGesture(const Offset(20, 20), pointer: 1);
    final second = await tester.startGesture(const Offset(40, 40), pointer: 2);
    expect(container.read(editorPointersProvider).length, 2);
    await first.up();
    await tester.pump();
    expect(container.read(editorPointersProvider), {2});
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(container.read(editorPointersProvider), isEmpty);
    await second.cancel();
  });

  testWidgets('hover from the same device releases a pointer whose up was lost',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const EditorOperationScope(child: SizedBox.expand()),
    ));
    tester.binding.handlePointerEvent(const PointerDownEvent(
      pointer: 7,
      device: 3,
      kind: PointerDeviceKind.mouse,
      position: Offset(20, 20),
    ));
    expect(container.read(editorPointersProvider), {7});
    tester.binding.handlePointerEvent(const PointerHoverEvent(
      device: 4,
      kind: PointerDeviceKind.mouse,
      position: Offset(30, 30),
    ));
    await tester.pump();
    expect(container.read(editorPointersProvider), {7});
    tester.binding.handlePointerEvent(const PointerHoverEvent(
      device: 3,
      kind: PointerDeviceKind.mouse,
      position: Offset(30, 30),
    ));
    await tester.pump();
    expect(container.read(editorPointersProvider), isEmpty);
  });

  testWidgets('a trackpad pan/zoom holds until it ends, even while hovering',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const EditorOperationScope(child: SizedBox.expand()),
    ));
    tester.binding.handlePointerEvent(const PointerPanZoomStartEvent(
      pointer: 9,
      device: 5,
      position: Offset(20, 20),
    ));
    expect(container.read(editorPointersProvider), {9});
    tester.binding.handlePointerEvent(const PointerHoverEvent(
      device: 5,
      kind: PointerDeviceKind.mouse,
      position: Offset(30, 30),
    ));
    await tester.pump();
    expect(container.read(editorPointersProvider), {9});
    tester.binding.handlePointerEvent(const PointerPanZoomEndEvent(
      pointer: 9,
      device: 5,
      position: Offset(20, 20),
    ));
    await tester.pump();
    expect(container.read(editorPointersProvider), isEmpty);
  });
}
