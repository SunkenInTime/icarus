import 'dart:collection';

import 'engine.dart';

final class MemoryStorage {
  MemoryStorage([Map<String, Map<String, String>> contents = const {}]) {
    for (final MapEntry(key: area, value: values) in contents.entries) {
      _area(area).addAll(values);
    }
  }

  final _areas = <String, SplayTreeMap<String, String>>{};
  _MemoryLease? _holder;

  Map<String, Map<String, String>> get contents => {
    for (final MapEntry(:key, :value) in _areas.entries)
      if (value.isNotEmpty) key: Map.unmodifiable(value),
  };

  SplayTreeMap<String, String> _area(String area) =>
      _areas.putIfAbsent(area, SplayTreeMap.new);
}

final class MemoryEngine implements StorageEngine {
  MemoryEngine(this.storage);

  final MemoryStorage storage;
  final _granted = <_MemoryLease>[];

  @override
  Future<Leasing> lease() async {
    if (storage._holder case final holder? when !holder._ended) {
      return const HeldByAnotherWriter();
    }
    final lease = _MemoryLease(storage);
    storage._holder = lease;
    _granted.add(lease);
    return Leased(lease);
  }

  Future<void> close() async {
    for (final lease in _granted) {
      await lease.release();
    }
    _granted.clear();
  }
}

final class _MemoryLease implements StorageLease {
  _MemoryLease(this._storage);

  final MemoryStorage _storage;
  var _ended = false;

  @override
  int get maxKeyLength => 1 << 20;

  Stored<T> _held<T>(T Function() task) =>
      _ended ? const StorageFailed(LeaseEnded()) : Done(task());

  @override
  Future<Stored<String?>> read(String area, String key) async =>
      _held(() => _storage._areas[area]?[key]);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async => _held(
    () => [
      for (final key in _storage._areas[area]?.keys ?? const <String>[])
        if (key.startsWith(prefix)) key,
    ],
  );

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) async =>
      _held(() => _storage._area(area).addAll(values));

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) async =>
      _held(() => keys.toList().forEach(_storage._area(area).remove));

  @override
  Future<void> release() async {
    _ended = true;
    if (identical(_storage._holder, this)) _storage._holder = null;
  }
}
