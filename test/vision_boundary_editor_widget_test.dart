import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/vision_boundary_editor_provider.dart';
import 'package:icarus/view_cone/vision_boundary_edit_document.dart';
import 'package:icarus/widgets/vision_boundary_editor.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _AscentMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HUD moves every boundary through one shared control',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [mapProvider.overrideWith(_AscentMapProvider.new)],
    );
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container.read(visionBoundaryEditorProvider.notifier).open(
            map: MapValue.ascent,
            attackTargetBounds: const Rect.fromLTRB(100, 50, 1100, 950),
          ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: VisionBoundaryEditorHud(),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('vision-boundary-editor-panel')),
      findsOneWidget,
    );
    expect(
      find.text('Attack, defense, and every elevation update together.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    final initial = container.read(visionBoundaryEditorProvider).draft!;
    await tester.tap(find.text('Everything'));
    await tester.pump();
    expect(
      container.read(visionBoundaryEditorProvider).scope,
      VisionBoundaryEditScope.all,
    );

    await tester.tap(find.byIcon(Icons.keyboard_arrow_right));
    await tester.pumpAndSettle();
    var state = container.read(visionBoundaryEditorProvider);
    expect(state.draft!.outer.first, initial.outer.first + const Offset(1, 0));
    expect(state.isDirty, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    state = container.read(visionBoundaryEditorProvider);
    expect(state.draft!.signature, initial.signature);
    expect(state.isDirty, isFalse);
  });
}
