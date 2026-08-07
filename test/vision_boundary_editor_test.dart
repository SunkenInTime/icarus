import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/vision_boundary_editor_provider.dart';
import 'package:icarus/view_cone/vision_boundary_edit_document.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VisionBoundaryMapDraft', () {
    final draft = VisionBoundaryMapDraft.fromJson(
      map: MapValue.ascent,
      value: const {
        'sourceBounds': [0, 0, 100, 200],
        'outer': [
          [0, 0],
          [100, 0],
          [100, 200],
          [0, 200],
        ],
        'interiors': [
          [
            [10, 20],
            [20, 20],
            [20, 30],
          ],
        ],
        'heightBoxes': [
          [
            [40, 50],
            [50, 50],
            [50, 60],
          ],
        ],
        'structuralChains': [
          [
            [60, 70],
            [70, 80],
          ],
        ],
      },
    );

    test('projects and unprojects attack and defense coordinates', () {
      const target = Rect.fromLTRB(200, 100, 600, 900);
      const source = Offset(25, 50);

      final attack = draft.project(
        source,
        attackTargetBounds: target,
        isDefense: false,
      );
      final defense = draft.project(
        source,
        attackTargetBounds: target,
        isDefense: true,
      );

      expect(attack, const Offset(300, 300));
      expect(
        defense,
        closeToOffset(const Offset(1000 * (16 / 9) - 300, 700), 0.001),
      );
      expect(
        draft.unproject(
          attack,
          attackTargetBounds: target,
          isDefense: false,
        ),
        closeToOffset(source, 0.001),
      );
      expect(
        draft.unproject(
          defense,
          attackTargetBounds: target,
          isDefense: true,
        ),
        closeToOffset(source, 0.001),
      );
    });

    test('normalizes legacy empty stroke-radius lists by contour', () {
      final restored = VisionBoundaryMapDraft.fromJson(
        map: MapValue.ascent,
        value: {
          ...draft.toJson(),
          'collisionRadii': const {
            'outer': 6.5,
            'interiors': <double>[],
            'heightBoxes': <double>[],
            'structuralChains': <double>[],
          },
        },
      );

      expect(
        restored.collisionRadius(
          const VisionBoundaryContourRef(VisionBoundaryContourKind.outer),
        ),
        6.5,
      );
      expect(restored.toJson()['collisionRadii'], {
        'outer': 6.5,
        'interiors': [0],
        'heightBoxes': [0],
        'structuralChains': [0],
      });
    });

    test('moves a point, a contour, or every contour independently', () {
      const interior = VisionBoundaryContourRef(
        VisionBoundaryContourKind.interior,
      );
      const selection = VisionBoundarySelection(
        contour: interior,
        pointIndex: 1,
      );

      final pointMoved = draft.move(
        selection: selection,
        scope: VisionBoundaryEditScope.point,
        sourceDelta: const Offset(3, -2),
      );
      expect(pointMoved.interiors.single[1], const Offset(23, 18));
      expect(pointMoved.interiors.single[0], draft.interiors.single[0]);
      expect(pointMoved.outer, draft.outer);

      final contourMoved = draft.move(
        selection: selection,
        scope: VisionBoundaryEditScope.contour,
        sourceDelta: const Offset(3, -2),
      );
      expect(contourMoved.interiors.single.first, const Offset(13, 18));
      expect(contourMoved.outer, draft.outer);
      expect(contourMoved.heightBoxes, draft.heightBoxes);

      final allMoved = draft.move(
        selection: null,
        scope: VisionBoundaryEditScope.all,
        sourceDelta: const Offset(3, -2),
      );
      expect(allMoved.outer.first, const Offset(3, -2));
      expect(allMoved.interiors.single.first, const Offset(13, 18));
      expect(allMoved.heightBoxes.single.first, const Offset(43, 48));
      expect(allMoved.structuralChains.single.first, const Offset(63, 68));
    });

    test('merges per-map edits without changing other reference maps', () {
      final merged = mergeVisionBoundaryDocuments(
        reference: {
          'version': 1,
          'maps': {
            'ascent': draft.toJson(),
            'summit': {'marker': 'reference'},
          },
        },
        edits: {
          'version': 1,
          'maps': {
            'ascent': {'marker': 'edited'},
          },
        },
      );
      final maps = merged['maps']! as Map<String, dynamic>;

      expect(maps['ascent'], {'marker': 'edited'});
      expect(maps['summit'], {'marker': 'reference'});
    });
  });

  test('provider previews, commits, undoes, and discards one shared edit',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(visionBoundaryEditorProvider.notifier);

    await notifier.open(
      map: MapValue.ascent,
      attackTargetBounds: const Rect.fromLTRB(100, 50, 1100, 950),
      boundary: SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: await rootBundle.loadString('assets/maps/ascent_map.svg'),
      ),
    );
    final initial = container.read(visionBoundaryEditorProvider).draft!;
    notifier.setScope(VisionBoundaryEditScope.all);
    notifier.beginEdit();
    notifier.moveSelectionBy(const Offset(2, 3));

    var state = container.read(visionBoundaryEditorProvider);
    expect(state.draft!.outer.first, initial.outer.first + const Offset(2, 3));
    expect(state.committedDraft, same(initial));

    notifier.commitEdit();
    state = container.read(visionBoundaryEditorProvider);
    expect(state.isDirty, isTrue);
    expect(state.committedDraft, same(state.draft));
    expect(notifier.canUndo, isTrue);

    notifier.undo();
    state = container.read(visionBoundaryEditorProvider);
    expect(state.draft!.signature, initial.signature);
    expect(state.isDirty, isFalse);
    expect(notifier.canRedo, isTrue);

    notifier.redo();
    expect(container.read(visionBoundaryEditorProvider).isDirty, isTrue);
    notifier.discardChanges();
    state = container.read(visionBoundaryEditorProvider);
    expect(state.draft!.signature, initial.signature);
    expect(state.isDirty, isFalse);
    expect(notifier.close(), isTrue);
  });
}

Matcher closeToOffset(Offset expected, double tolerance) => predicate<Offset>(
      (actual) => (actual - expected).distance <= tolerance,
      'an offset within $tolerance of $expected',
    );
