import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';

/// What a pressed pointer landed on.
class EditorPointerHold {
  const EditorPointerHold({this.onCanvas = false, this.entityIds = const {}});

  /// Pressed inside the strategy canvas. Presses elsewhere (sidebar, dialogs,
  /// overlays) may drive an edit whose target we cannot see.
  final bool onCanvas;

  /// The canvas items under the pointer.
  final Set<String> entityIds;

  EditorPointerHold copyWith({bool? onCanvas, Set<String>? entityIds}) =>
      EditorPointerHold(
        onCanvas: onCanvas ?? this.onCanvas,
        entityIds: entityIds ?? this.entityIds,
      );
}

final editorPointersProvider =
    NotifierProvider<EditorPointersNotifier, Map<int, EditorPointerHold>>(
        EditorPointersNotifier.new);

/// Pointer-down reaches the deepest listener first: an item's marker, then the
/// canvas, then the app-wide scope. Each adds what it knows to the same hold.
class EditorPointersNotifier extends Notifier<Map<int, EditorPointerHold>> {
  bool _disposed = false;

  @override
  Map<int, EditorPointerHold> build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const {};
  }

  void holdEntity(int pointer, String id) {
    final hold = state[pointer] ?? const EditorPointerHold();
    state = {
      ...state,
      pointer:
          hold.copyWith(onCanvas: true, entityIds: {...hold.entityIds, id}),
    };
  }

  /// Every press holding [heldId] now holds [id] as well.
  void holdAlongside(String heldId, String id) {
    state = {
      for (final MapEntry(key: pointer, value: hold) in state.entries)
        pointer: hold.entityIds.contains(heldId)
            ? hold.copyWith(entityIds: {...hold.entityIds, id})
            : hold,
    };
  }

  void markCanvas(int pointer) {
    final hold = state[pointer] ?? const EditorPointerHold();
    state = {...state, pointer: hold.copyWith(onCanvas: true)};
  }

  void down(int pointer) {
    if (state.containsKey(pointer)) return;
    state = {...state, pointer: const EditorPointerHold()};
  }

  void release(int pointer) {
    // Pointer routing finishes before drag-end/cancel callbacks commit their
    // edits. Keep the hold until all those callbacks have run.
    scheduleMicrotask(() {
      if (!_disposed && state.containsKey(pointer)) {
        state = {...state}..remove(pointer);
      }
    });
  }
}

/// The canvas items a remote update must leave as they are on screen, because
/// the user is in the middle of changing them. Null means a press we cannot
/// attribute is down, so no remote update may apply yet.
final editorHeldEntitiesProvider = Provider<Set<String>?>((ref) {
  final holds = ref.watch(editorPointersProvider).values;
  if (holds.any((hold) => !hold.onCanvas)) return null;
  final placement =
      ref.watch(lineUpProvider.select((state) => state.placement));
  // The edit's lineups stay the same while its ends move, so a drag does not
  // recompute this every frame.
  final editing =
      ref.watch(lineUpProvider.select((state) => state.edit?.linkIds)) != null;
  final drafts = ref.watch(textDraftProvider.select((drafts) => drafts.keys));
  return {
    for (final hold in holds) ...hold.entityIds,
    ...drafts,
    if (placement?.pinnedOriginId case final id?) id,
    if (placement?.pinnedLandingId case final id?) id,
    if (editing) ...ref.read(lineUpProvider).edit!.itemIds,
  };
});

/// Whether anything at all is mid-way: a press, a stroke, a lineup placement
/// or placement edit, or a text draft. Replacing the whole page (a different
/// page than the one on screen) waits for this; merging into the page on
/// screen does not.
final editorBusyProvider = Provider<bool>((ref) {
  final pointers = ref.watch(editorPointersProvider);
  final drawing = ref.watch(
    drawingProvider.select((state) => state.currentElement != null),
  );
  final placement = ref.watch(
    lineUpProvider.select(
      (state) => state.placement != null || state.edit != null,
    ),
  );
  final text =
      ref.watch(textDraftProvider.select((drafts) => drafts.isNotEmpty));
  return pointers.isNotEmpty || drawing || placement || text;
});
