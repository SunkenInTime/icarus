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
  MemoryEngine(this.storage, {this.maxKeyLength = 1024});

  final MemoryStorage storage;
  final int maxKeyLength;
  final _granted = <_MemoryLease>[];

  @override
  Future<Leasing> lease() async {
    if (storage._holder case final holder? when holder.status is Holding) {
      return const HeldByAnotherWriter();
    }
    final lease = _MemoryLease(storage, maxKeyLength);
    storage._holder = lease;
    _granted.add(lease);
    return Leased(lease);
  }

  Future<void> close() async {
    final granted = [..._granted];
    _granted.clear();
    for (final lease in granted) {
      await lease.release();
    }
  }
}

final class _MemoryLease implements StorageLease {
  _MemoryLease(this._storage, this.maxKeyLength);

  final MemoryStorage _storage;
  @override
  final int maxKeyLength;
  LeaseStatus _status = const Holding();

  @override
  LeaseStatus get status => _status;

  Stored<T> _held<T>(T Function() task) => switch (_status) {
    Holding() => Done(task()),
    Ended() => const StorageFailed(LeaseEnded()),
  };

  @override
  Future<KeyRead> read(String area, String key) async => switch (_status) {
    Ended() => const KeyNotRead(LeaseEnded()),
    Holding() => switch (_storage._areas[area]?[key]) {
      final String value => KeyHeld(value),
      null => const KeyMissing(),
    },
  };

  Iterable<MapEntry<String, String>> _under(String area, String prefix) =>
      (_storage._areas[area] ?? const <String, String>{}).entries.where(
        (entry) => entry.key.startsWith(prefix),
      );

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      _held(() => [for (final entry in _under(area, prefix)) entry.key]);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async =>
      _held(
        () => [
          for (final entry in _under(area, prefix))
            (key: entry.key, value: entry.value),
        ],
      );

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) async {
    for (final key in values.keys) {
      if (key.length > maxKeyLength) {
        return StorageFailed(KeyTooLong(area, key));
      }
    }
    return _held(() => _storage._area(area).addAll(values));
  }

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) async =>
      _held(() => keys.toList().forEach(_storage._area(area).remove));

  @override
  Future<Releasing> release() async {
    _status = const Ended();
    if (identical(_storage._holder, this)) _storage._holder = null;
    return const Released();
  }
}
