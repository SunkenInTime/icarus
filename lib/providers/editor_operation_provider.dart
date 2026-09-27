import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';

final editorPointersProvider =
    NotifierProvider<EditorPointersNotifier, Set<int>>(
        EditorPointersNotifier.new);

class EditorPointersNotifier extends Notifier<Set<int>> {
  bool _disposed = false;

  @override
  Set<int> build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const {};
  }

  void down(int pointer) => state = {...state, pointer};

  void release(int pointer) {
    // Pointer routing finishes before drag-end/cancel callbacks commit their
    // edits. Keep the page protected until all those callbacks have run.
    scheduleMicrotask(() {
      if (!_disposed && state.contains(pointer)) {
        state = {...state}..remove(pointer);
      }
    });
  }
}

/// A selected tool can be idle. Only unfinished work delays remote hydration.
final editorOperationActiveProvider = Provider<bool>((ref) {
  final pointers = ref.watch(editorPointersProvider);
  final drawing = ref.watch(
    drawingProvider.select((state) => state.currentElement != null),
  );
  final placement = ref.watch(
    lineUpProvider.select((state) => state.placement != null),
  );
  final text =
      ref.watch(textDraftProvider.select((drafts) => drafts.isNotEmpty));
  return pointers.isNotEmpty || drawing || placement || text;
});
