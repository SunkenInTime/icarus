import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';

final pinnedItemsProvider =
    NotifierProvider<PinnedItemsProvider, Map<String, int>>(
        PinnedItemsProvider.new);

const _legacyTimestampThreshold = 1000000000000;

List<String> pinnedIdsInManualOrder(Map<String, int> pinned) {
  final entries = pinned.entries.toList()..sort(_comparePinnedEntries);
  return entries.map((e) => e.key).toList();
}

int _comparePinnedEntries(MapEntry<String, int> a, MapEntry<String, int> b) {
  final hasLegacyTimestamp = a.value > _legacyTimestampThreshold ||
      b.value > _legacyTimestampThreshold;
  if (hasLegacyTimestamp) return b.value.compareTo(a.value);
  return a.value.compareTo(b.value);
}

/// Tracks which strategies/folders are pinned to the home screen.
///
/// Stored as a Hive box keyed by the item's id, with a zero-based manual sort
/// index as the value. State is a `Map<String, int>` of id -> order.
class PinnedItemsProvider extends Notifier<Map<String, int>> {
  Box<int> get _box => Hive.box<int>(HiveBoxNames.pinnedItemsBox);

  @override
  Map<String, int> build() {
    return _readFromBox();
  }

  bool isPinned(String id) => state.containsKey(id);

  List<String> pinnedIdsByManualOrder() => pinnedIdsInManualOrder(state);

  @Deprecated('Use pinnedIdsByManualOrder')
  List<String> pinnedIdsByRecency() => pinnedIdsByManualOrder();

  Future<void> togglePin(String id) async {
    if (isPinned(id)) {
      await removePin(id);
      return;
    }
    await _saveOrder([id, ...pinnedIdsByManualOrder()]);
  }

  Future<void> removePin(String id) async {
    if (!isPinned(id)) return;
    final orderedIds = pinnedIdsByManualOrder()..remove(id);
    await _saveOrder(orderedIds);
  }

  Future<void> movePinUp(String id) async {
    final orderedIds = pinnedIdsByManualOrder();
    final index = orderedIds.indexOf(id);
    if (index <= 0) return;
    orderedIds
      ..removeAt(index)
      ..insert(index - 1, id);
    await _saveOrder(orderedIds);
  }

  Future<void> movePinDown(String id) async {
    final orderedIds = pinnedIdsByManualOrder();
    final index = orderedIds.indexOf(id);
    if (index == -1 || index == orderedIds.length - 1) return;
    orderedIds
      ..removeAt(index)
      ..insert(index + 1, id);
    await _saveOrder(orderedIds);
  }

  Future<void> movePinToTop(String id) async {
    final orderedIds = pinnedIdsByManualOrder();
    if (!orderedIds.remove(id)) return;
    await _saveOrder([id, ...orderedIds]);
  }

  Future<void> movePin({
    required String id,
    required String targetId,
    required bool insertAfterTarget,
  }) async {
    if (id == targetId || !isPinned(id) || !isPinned(targetId)) return;

    final orderedIds = pinnedIdsByManualOrder()..remove(id);
    final targetIndex = orderedIds.indexOf(targetId);
    if (targetIndex == -1) return;

    orderedIds.insert(
      targetIndex + (insertAfterTarget ? 1 : 0),
      id,
    );
    await _saveOrder(orderedIds);
  }

  Future<void> _saveOrder(List<String> orderedIds) async {
    final nextState = <String, int>{
      for (final entry in orderedIds.asMap().entries) entry.value: entry.key,
    };
    await _box.putAll(nextState);
    final staleKeys = _box.keys
        .where((key) => key is! String || !nextState.containsKey(key))
        .toList();
    await _box.deleteAll(staleKeys);
    state = nextState;
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
