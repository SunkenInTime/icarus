import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';

final pinnedItemsProvider =
    NotifierProvider<PinnedItemsProvider, Map<String, int>>(
        PinnedItemsProvider.new);

/// Tracks which strategies/folders are pinned to the home screen.
///
/// Stored as a Hive box keyed by the item's id, with the pin timestamp
/// (milliseconds since epoch) as the value. The timestamp gives us ordering.
/// State is a `Map<String, int>` of id -> pinnedAt.
class PinnedItemsProvider extends Notifier<Map<String, int>> {
  Box<int> get _box => Hive.box<int>(HiveBoxNames.pinnedItemsBox);

  @override
  Map<String, int> build() {
    return _readFromBox();
  }

  bool isPinned(String id) => state.containsKey(id);

  /// Pinned ids, most recently pinned first.
  List<String> pinnedIdsByRecency() {
    final entries = state.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => e.key).toList();
  }

  Future<void> togglePin(String id) async {
    if (isPinned(id)) {
      await removePin(id);
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await _box.put(id, now);
    state = {...state, id: now};
  }

  Future<void> removePin(String id) async {
    if (!isPinned(id)) return;
    await _box.delete(id);
    state = {...state}..remove(id);
  }

  Map<String, int> _readFromBox() {
    final result = <String, int>{};
    for (final key in _box.keys) {
      if (key is! String) continue; // resilient to stale/invalid keys
      final value = _box.get(key);
      if (value == null) continue;
      result[key] = value;
    }
    return result;
  }
}
