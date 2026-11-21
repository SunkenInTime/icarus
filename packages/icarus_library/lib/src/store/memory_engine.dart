import 'dart:async';
import 'dart:collection';

import 'engine.dart';
import 'engine_contract.dart';

final class WriteHold implements PendingWrite {
  final _reached = Completer<void>();
  final _letGo = Completer<void>();

  @override
  Future<void> get reached => _reached.future;

  @override
  void letGo() => _letGo.complete();
}

final class MemoryStorage {
  MemoryStorage([
    Map<String, Map<String, String>> contents = const {},
    this.maxKeyLength = 1024,
  ]) {
    for (final MapEntry(key: area, value: values) in contents.entries) {
      _area(area).addAll(values);
    }
  }

  final int maxKeyLength;
  final _areas = <String, SplayTreeMap<String, String>>{};
  _MemoryLease? _holder;
  WriteHold? _hold;

  Map<String, Map<String, String>> get contents => {
    for (final MapEntry(:key, :value) in _areas.entries)
      if (value.isNotEmpty) key: Map.unmodifiable(value),
  };

  WriteHold holdNextWrite() => _hold = WriteHold();

  SplayTreeMap<String, String> _area(String area) =>
      _areas.putIfAbsent(area, SplayTreeMap.new);
}

final class MemoryEngine implements StorageEngine {
  MemoryEngine(this.storage);

  final MemoryStorage storage;
  final _granted = <_MemoryLease>[];
  var _closed = false;

  @override
  Future<Leasing> lease() async {
    if (_closed) return const LeaseFailed(EngineClosed());
    if (storage._holder case final holder? when holder.status is Holding) {
      return const HeldByAnotherWriter();
    }
    final lease = _MemoryLease(storage);
    storage._holder = lease;
    _granted.add(lease);
    return Leased(lease);
  }

  Future<void> close() async {
    _closed = true;
    final granted = [..._granted];
    _granted.clear();
    for (final lease in granted) {
      await lease.release();
    }
  }
}

final class _MemoryLease implements StorageLease {
  _MemoryLease(this._storage);

  final MemoryStorage _storage;

  @override
  int get maxKeyLength => _storage.maxKeyLength;
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
  Future<Stored<List<String>>> areas(String prefix) async => _held(
    () => [
      for (final MapEntry(:key, :value) in _storage._areas.entries)
        if (value.isNotEmpty && key.startsWith(prefix)) key,
    ]..sort(compareCodeUnits),
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

  StorageFailure? _refusal(Change change) => switch (change) {
    Change(:final area) when !isArea(area) => NameNotAllowed(area, ''),
    Put(:final area, :final key) || Delete(:final area, :final key)
        when !isName(key) =>
      NameNotAllowed(area, key),
    Put(:final area, :final key) || Delete(:final area, :final key)
        when key.length > maxKeyLength =>
      KeyTooLong(area, key),
    _ => null,
  };

  @override
  Future<Committing> commit(List<Change> changes) async {
    if (_status is Ended) return const CommitRefused(LeaseEnded());
    for (final change in changes) {
      if (_refusal(change) case final failure?) return CommitRefused(failure);
    }
    if (_storage._hold case final hold?) {
      _storage._hold = null;
      hold._reached.complete();
      await hold._letGo.future;
      if (_status is Ended) return const CommitRefused(LeaseEnded());
    }
    for (final change in changes) {
      switch (change) {
        case Put(:final area, :final key, :final value):
          _storage._area(area)[key] = value;
        case Delete(:final area, :final key):
          _storage._areas[area]?.remove(key);
        case ClearArea(:final area):
          _storage._areas.remove(area);
      }
    }
    return const CommitApplied();
  }

  @override
  Future<Releasing> release() async {
    _status = const Ended();
    if (identical(_storage._holder, this)) _storage._holder = null;
    return const Released();
  }
}
