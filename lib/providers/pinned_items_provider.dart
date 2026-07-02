import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';

final pinnedItemsProvider =
    NotifierProvider<PinnedItemsProvider, Map<String, int>>(
  PinnedItemsProvider.new,
);

const _legacyTimestampThreshold = 1000000000000;

List<String> pinnedIdsInManualOrder(Map<String, int> pinned) {
  final entries = pinned.entries.toList()..sort(_comparePinnedEntries);
  return entries.map((entry) => entry.key).toList();
}

List<T> sortPinnedItemsFirst<T>(
  Iterable<T> items,
  Map<String, int> pinned,
  String Function(T item) idOf,
) {
  if (pinned.isEmpty) return items.toList();

  final orderedPinnedIds = pinnedIdsInManualOrder(pinned);
  final pinnedOrder = {
    for (final entry in orderedPinnedIds.asMap().entries)
      entry.value: entry.key,
  };
  final pinnedItems = <T>[];
  final unpinnedItems = <T>[];

  for (final item in items) {
    final id = idOf(item);
    if (pinnedOrder.containsKey(id)) {
      pinnedItems.add(item);
    } else {
      unpinnedItems.add(item);
    }
  }

  pinnedItems.sort(
    (a, b) => pinnedOrder[idOf(a)]!.compareTo(pinnedOrder[idOf(b)]!),
  );
  return [...pinnedItems, ...unpinnedItems];
}

int _comparePinnedEntries(MapEntry<String, int> a, MapEntry<String, int> b) {
  final hasLegacyTimestamp = a.value > _legacyTimestampThreshold ||
      b.value > _legacyTimestampThreshold;
  if (hasLegacyTimestamp) return b.value.compareTo(a.value);
  return a.value.compareTo(b.value);
}

class PinnedItemsProvider extends Notifier<Map<String, int>> {
  Box<int>? get _openBoxOrNull {
    if (!Hive.isBoxOpen(HiveBoxNames.pinnedItemsBox)) return null;
    return Hive.box<int>(HiveBoxNames.pinnedItemsBox);
  }

  @override
  Map<String, int> build() {
    final box = _openBoxOrNull;
    if (box == null) return const {};
    return _readFromBox(box);
  }

  bool isPinned(String id) => state.containsKey(id);

  List<String> pinnedIdsByManualOrder() => pinnedIdsInManualOrder(state);

  Future<void> togglePin(String id) async {
    await _ensureLoaded();
    if (isPinned(id)) {
      await removePin(id);
      return;
    }

    await _saveOrder([id, ...pinnedIdsByManualOrder()]);
  }

  Future<void> removePin(String id) async {
    await _ensureLoaded();
    if (!isPinned(id)) return;

    final orderedIds = pinnedIdsByManualOrder()..remove(id);
    await _saveOrder(orderedIds);
  }

  Future<void> movePin({
    required String id,
    required String targetId,
    required bool insertAfterTarget,
  }) async {
    await _ensureLoaded();
    if (id == targetId || !isPinned(id) || !isPinned(targetId)) return;

    final orderedIds = pinnedIdsByManualOrder()..remove(id);
    final targetIndex = orderedIds.indexOf(targetId);
    if (targetIndex == -1) return;

    orderedIds.insert(targetIndex + (insertAfterTarget ? 1 : 0), id);
    await _saveOrder(orderedIds);
  }

  Future<void> _saveOrder(List<String> orderedIds) async {
    final box = await _ensureBoxOpen();
    final nextState = <String, int>{
      for (final entry in orderedIds.asMap().entries) entry.value: entry.key,
    };

    await box.putAll(nextState);

    final staleKeys = box.keys
        .where((key) => key is! String || !nextState.containsKey(key))
        .toList();
    await box.deleteAll(staleKeys);

    state = nextState;
  }

  Future<void> _ensureLoaded() async {
    final box = await _ensureBoxOpen();
    if (state.isEmpty && box.keys.isNotEmpty) {
      state = _readFromBox(box);
    }
  }

  Future<Box<int>> _ensureBoxOpen() async {
    final box = _openBoxOrNull;
    if (box != null) return box;
    return Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  }

  Map<String, int> _readFromBox(Box<int> box) {
    final result = <String, int>{};
    for (final key in box.keys) {
      if (key is! String) continue;
      final value = box.get(key);
      if (value == null) continue;
      result[key] = value;
    }
    return result;
  }
}
