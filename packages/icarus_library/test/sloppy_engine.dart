import 'dart:async';
import 'dart:collection';

import 'package:icarus_library/engine_contract.dart';
import 'package:icarus_library/icarus_library.dart';

enum Flaw {
  none,
  racyLease,
  writesAfterClose,
  appliesFirstBeforeHold,
  writesAfterRelease,
  restoresOldAfterEnd,
  reservesOneMicrotask,
  areasInInsertionOrder,
}

final class SloppyHold implements PendingWrite {
  final _reached = Completer<void>();
  final _letGo = Completer<void>();

  @override
  Future<void> get reached => _reached.future;

  @override
  void letGo() => _letGo.complete();
}

final class SloppyStorage {
  final areas = <String, SplayTreeMap<String, String>>{};
  SloppyLease? holder;
  SloppyHold? hold;
  bool reserved = false;
}

final class SloppyEngine implements StorageEngine {
  SloppyEngine(this.storage, this.flaw);

  final SloppyStorage storage;
  final Flaw flaw;
  final _granted = <SloppyLease>[];
  var _closed = false;

  @override
  Future<Leasing> lease() async {
    if (_closed) return const LeaseFailed(EngineClosed());
    if (storage.holder?.status is Holding || storage.reserved) {
      return const HeldByAnotherWriter();
    }
    if (flaw == Flaw.racyLease) await Future<void>.delayed(Duration.zero);
    if (flaw == Flaw.reservesOneMicrotask) {
      storage.reserved = true;
      scheduleMicrotask(() => storage.reserved = false);
      await Future<void>.delayed(Duration.zero);
    }
    final lease = SloppyLease(storage, flaw);
    storage.holder = lease;
    _granted.add(lease);
    return Leased(lease);
  }

  Future<void> close() async {
    _closed = true;
    for (final lease in [..._granted]) {
      lease.end(byClose: true);
    }
  }
}

final class SloppyLease implements StorageLease {
  SloppyLease(this._storage, this._flaw);

  final SloppyStorage _storage;
  final Flaw _flaw;
  LeaseStatus _status = const Holding();
  var _endedByClose = false;

  @override
  int get maxKeyLength => 1024;

  @override
  LeaseStatus get status => _status;

  void end({required bool byClose}) {
    if (_status is Ended) return;
    _status = const Ended();
    _endedByClose = byClose;
    if (identical(_storage.holder, this)) _storage.holder = null;
  }

  Iterable<MapEntry<String, String>> _under(String area, String prefix) =>
      (_storage.areas[area] ?? const <String, String>{}).entries.where(
        (entry) => entry.key.startsWith(prefix),
      );

  Stored<T> _held<T>(T Function() task) => switch (_status) {
    Holding() => Done(task()),
    Ended() => const StorageFailed(LeaseEnded()),
  };

  @override
  Future<KeyRead> read(String area, String key) async => switch (_status) {
    Ended() => const KeyNotRead(LeaseEnded()),
    Holding() => switch (_storage.areas[area]?[key]) {
      final String value => KeyHeld(value),
      null => const KeyMissing(),
    },
  };

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
  Future<Stored<List<String>>> areas(String prefix) async => _held(
    () =>
        [
          for (final MapEntry(:key, :value) in _storage.areas.entries)
            if (value.isNotEmpty && key.startsWith(prefix)) key,
        ]..sort(
          _flaw == Flaw.areasInInsertionOrder ? (a, b) => 0 : compareCodeUnits,
        ),
  );

  void _apply(Change change) {
    switch (change) {
      case Put(:final area, :final key, :final value):
        _storage.areas.putIfAbsent(area, SplayTreeMap.new)[key] = value;
      case Delete(:final area, :final key):
        _storage.areas[area]?.remove(key);
      case ClearArea(:final area):
        _storage.areas.remove(area);
    }
  }

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
    final hold = _storage.hold;
    if (hold == null) {
      changes.forEach(_apply);
      return const CommitApplied();
    }
    _storage.hold = null;
    final early = _flaw == Flaw.appliesFirstBeforeHold && changes.isNotEmpty;
    if (early) _apply(changes.first);
    final first = changes.whereType<Put>().firstOrNull;
    final old = first == null ? null : _storage.areas[first.area]?[first.key];
    hold._reached.complete();
    await hold._letGo.future;
    if (_flaw == Flaw.restoresOldAfterEnd &&
        _status is Ended &&
        first != null) {
      final area = _storage.areas.putIfAbsent(first.area, SplayTreeMap.new);
      if (old == null) {
        area.remove(first.key);
      } else {
        area[first.key] = old;
      }
      return const CommitRefused(LeaseEnded());
    }
    final lands = switch (_flaw) {
      Flaw.writesAfterClose => _status is Holding || _endedByClose,
      Flaw.writesAfterRelease => _status is Holding || !_endedByClose,
      _ => _status is Holding,
    };
    if (!lands) return const CommitRefused(LeaseEnded());
    changes.skip(early ? 1 : 0).forEach(_apply);
    return const CommitApplied();
  }

  @override
  Future<Releasing> release() async {
    end(byClose: false);
    return const Released();
  }
}

final class SloppyHarness implements EngineHarness {
  SloppyHarness(this.flaw);

  final Flaw flaw;
  final storage = SloppyStorage();

  @override
  Future<StorageEngine> open() async => SloppyEngine(storage, flaw);

  @override
  Future<void> close(StorageEngine engine) => (engine as SloppyEngine).close();

  @override
  Future<void> crash(StorageEngine engine) => (engine as SloppyEngine).close();

  @override
  PendingWrite holdNextWrite(StorageEngine engine) =>
      storage.hold = SloppyHold();
}
