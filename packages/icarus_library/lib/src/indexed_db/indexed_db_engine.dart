import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart';

import '../engines/names.dart';
import '../store/engine.dart';
import '../store/engine_contract.dart';

const _rows = 'rows';

const indexedDbMaxKeyLength = 1024;

const indexedDbVersion = 1;

const roomMargin = 1024 * 1024;

const _bytesPerChange = 1024;

const _refreshRoomEvery = Duration(seconds: 10);

StorageFailure _named(DOMException? error, String what) =>
    DeviceFailure(switch (error) {
      null => '$what was aborted',
      _ => '$what failed: ${error.name}: ${error.message}',
    });

StorageFailure _thrown(Object error, String what) => switch (error) {
  final JSAny thrown when thrown.isA<DOMException>() => _named(
    thrown as DOMException,
    what,
  ),
  _ => DeviceFailure('$what threw: $error'),
};

void _into<T>(Completer<T> answer, T Function() compute) {
  if (!answer.isCompleted) answer.complete(Future.sync(compute));
}

JSArray<JSAny> _key(String area, String key) => [area.toJS, key.toJS].toJS;

String? _afterUnits(String prefix) {
  final units = prefix.codeUnits.toList();
  while (units.isNotEmpty) {
    final last = units.removeLast();
    if (last < 0xFFFF) return String.fromCharCodes([...units, last + 1]);
  }
  return null;
}

const _notText = DeviceFailure('the library holds a value that is not text');

const _notAName = DeviceFailure('the library holds a key that is not a name');

String? _text(JSAny? value) =>
    value.isA<JSString>() ? (value as JSString).toDart : null;

sealed class _Answer {
  const _Answer();
}

final class _Value extends _Answer {
  const _Value(this.value);

  final JSAny? value;
}

final class _Nothing extends _Answer {
  const _Nothing();
}

final class _Failed extends _Answer {
  const _Failed(this.failure);

  final StorageFailure failure;
}

Future<_Answer> _answer(IDBRequest request, String what) {
  final answered = Completer<_Answer>();
  request
    ..onsuccess = ((Event _) => _into(
      answered,
      () => request.result.isUndefined
          ? const _Nothing()
          : _Value(request.result),
    )).toJS
    ..onerror = ((Event event) {
      event.preventDefault();
      _into(answered, () => _Failed(_named(request.error, what)));
    }).toJS;
  return answered.future;
}

List<String>? _namesIn(JSAny? keys, int part) {
  if (!keys.isA<JSArray>()) return null;
  final names = <String>[];
  for (final key in (keys as JSArray<JSAny?>).toDart) {
    if (!key.isA<JSArray>()) return null;
    final parts = (key as JSArray<JSAny?>).toDart;
    final name = parts.length == 2 ? _text(parts[part]) : null;
    if (name == null) return null;
    names.add(name);
  }
  return names;
}

sealed class _Opened {
  const _Opened();
}

final class _Database extends _Opened {
  const _Database(this.db, {required this.created});

  final IDBDatabase db;
  final bool created;
}

final class _Refused extends _Opened {
  const _Refused(this.failure);

  final StorageFailure failure;
}

StorageFailure _cannotOpen(String why) =>
    DeviceFailure('the library cannot be opened: $why');

Future<_Opened> _openDatabase(String name, Duration patience) {
  final opened = Completer<_Opened>();
  var created = false;
  final request = window.indexedDB.open(name);
  request
    ..onupgradeneeded = ((IDBVersionChangeEvent _) {
      created = true;
      (request.result! as IDBDatabase).createObjectStore(_rows);
    }).toJS
    ..onsuccess = ((Event _) {
      final db = request.result! as IDBDatabase;
      if (opened.isCompleted) {
        db.close();
        return;
      }
      _into(opened, () => _Database(db, created: created));
    }).toJS
    ..onerror = ((Event event) {
      event.preventDefault();
      _into(opened, () => _Refused(_named(request.error, 'opening')));
    }).toJS;
  final waiting = Timer(
    patience,
    () => _into(
      opened,
      () => _Refused(
        _cannotOpen(
          'the browser did not open it within ${patience.inSeconds} s; '
          'another tab may be upgrading or deleting it',
        ),
      ),
    ),
  );
  return opened.future.whenComplete(waiting.cancel);
}

Future<void> _deleteDatabase(String name, Duration patience) {
  final deleted = Completer<void>();
  window.indexedDB.deleteDatabase(name)
    ..onsuccess = ((Event _) => _into(deleted, () {})).toJS
    ..onerror = ((Event event) {
      event.preventDefault();
      _into(deleted, () {});
    }).toJS;
  final waiting = Timer(patience, () => _into(deleted, () {}));
  return deleted.future.whenComplete(waiting.cancel);
}

StorageFailure? _problemWith(IDBDatabase db) {
  if (db.version != indexedDbVersion) {
    return _cannotOpen('written by a newer build (version ${db.version})');
  }
  if (!db.objectStoreNames.contains(_rows)) {
    return _cannotOpen('not an Icarus library (no rows store)');
  }
  return null;
}

Future<bool> _keepsWritesStrict(IDBDatabase db) {
  final probe = db.transaction(
    _rows.toJS,
    'readwrite',
    IDBTransactionOptions(durability: 'strict'),
  );
  final ended = Completer<void>();
  probe
    ..onabort = ((Event _) => _into(ended, () {})).toJS
    ..oncomplete = ((Event _) => _into(ended, () {})).toJS;
  final durability = _text(probe.getProperty<JSAny?>('durability'.toJS));
  probe.abort();
  return ended.future.then((_) => durability == 'strict');
}

final class _Lock {
  _Lock(String name) {
    _ended = window.navigator.locks
        .request(
          name,
          LockOptions(ifAvailable: true),
          ((Lock? lock) {
            _granted.complete(lock != null);
            return lock == null ? null : _letGo.future.toJS;
          }).toJS,
        )
        .toDart;
  }

  final _granted = Completer<bool>();
  final _letGo = Completer<void>();
  late final Future<JSAny?> _ended;

  Future<bool> get held =>
      Future.any([_granted.future, _ended.then((_) => _granted.future)]);

  Future<void> letGo() async {
    if (!_letGo.isCompleted) _letGo.complete();
    if (_granted.isCompleted && await _granted.future) await _ended;
  }
}

final class _Room {
  int? _left;
  final _sinceAsked = Stopwatch();
  Future<void>? _asking;
  var _spentWhileAsking = 0;

  static int _needed(List<Change> changes) => changes.fold(
    0,
    (total, change) =>
        total +
        _bytesPerChange +
        switch (change) {
          Put(:final area, :final key, :final value) =>
            2 * (area.length + key.length + value.length),
          Delete() || ClearArea() => 0,
        },
  );

  Future<void> ask() => _asking ??= () {
    _spentWhileAsking = 0;
    _sinceAsked
      ..reset()
      ..start();
    return window.navigator.storage.estimate().toDart.then(
      (estimate) {
        _left = estimate.quota - estimate.usage - _spentWhileAsking;
        _asking = null;
      },
      onError: (Object _) {
        _left = null;
        _asking = null;
      },
    );
  }();

  bool _fits(int needed) => switch (_left) {
    null => true,
    final left => needed + roomMargin <= left,
  };

  Future<StorageFailure?> refuses(List<Change> changes) async {
    final needed = _needed(changes);
    if (_sinceAsked.elapsed > _refreshRoomEvery) unawaited(ask());
    if (_fits(needed)) return null;
    await ask();
    return switch (_left) {
      final left? when !_fits(needed) => NoRoomForCommit(
        needed: needed + roomMargin,
        left: left,
      ),
      _ => null,
    };
  }

  void spent(List<Change> changes) {
    final needed = _needed(changes);
    if (_left case final left?) _left = left - needed;
    _spentWhileAsking += needed;
  }
}

final class IndexedDbEngine implements StorageEngine {
  IndexedDbEngine(this.name, {this.patience = const Duration(seconds: 10)}) {
    if (name.startsWith('-')) {
      throw ArgumentError.value(name, 'name', 'Web Locks keep names with -');
    }
  }

  final String name;
  final Duration patience;
  final _granted = <IndexedDbLease>[];
  final _opening = <Future<Leasing>>{};
  var _closed = false;
  Future<Releasing>? _closing;

  @override
  Future<Leasing> lease() {
    if (_closed) return Future.value(const LeaseFailed(EngineClosed()));
    final leasing = _lease();
    _opening.add(leasing);
    return leasing.whenComplete(() => _opening.remove(leasing));
  }

  Future<Leasing> _lease() async {
    if (!window.navigator.has('locks')) {
      return const LeaseFailed(
        DeviceFailure('this page cannot hold the library: no Web Locks'),
      );
    }
    _Lock? lock;
    IDBDatabase? db;
    var created = false;
    IndexedDbLease? granted;
    try {
      final asked = lock = _Lock(name);
      if (!await asked.held) return const HeldByAnotherWriter();
      final IDBDatabase opened;
      switch (await _openDatabase(name, patience)) {
        case _Refused(:final failure):
          return LeaseFailed(failure);
        case _Database(db: final database, created: final made):
          opened = db = database;
          created = made;
      }
      if (_problemWith(opened) case final problem?) return LeaseFailed(problem);
      if (!await _keepsWritesStrict(opened)) {
        return LeaseFailed(
          _cannotOpen(
            'this browser does not keep writes with strict durability',
          ),
        );
      }
      final room = _Room();
      await room.ask();
      final lease = granted = IndexedDbLease._(opened, asked, room);
      _granted.add(lease);
      return _closed ? const LeaseFailed(EngineClosed()) : Leased(lease);
    } on Object catch (error) {
      return LeaseFailed(_thrown(error, 'leasing the library'));
    } finally {
      if (granted == null) {
        db?.close();
        if (created) await _deleteDatabase(name, patience);
        await lock?.letGo();
      }
    }
  }

  PendingWrite holdNextCommit() => _granted.last._held = _HeldCommit();

  Future<Releasing> close() => _closing ??= _close();

  Future<Releasing> _close() async {
    _closed = true;
    await Future.wait([..._opening]);
    Releasing releasing = const Released();
    for (final lease in _granted) {
      if (await lease.release() case final ReleaseFailed failed) {
        releasing = failed;
      }
    }
    _granted.clear();
    return releasing;
  }
}

sealed class _LeaseState {
  const _LeaseState();
}

final class _Open extends _LeaseState {
  const _Open();
}

final class _Ending extends _LeaseState {
  const _Ending(this.releasing);

  final Future<Releasing> releasing;
}

final class IndexedDbLease implements StorageLease {
  IndexedDbLease._(this._db, this._lock, this._room) {
    _db
      ..onversionchange = ((Event _) => unawaited(release())).toJS
      ..onclose = ((Event _) => unawaited(release())).toJS;
  }

  final IDBDatabase _db;
  final _Lock _lock;
  final _Room _room;
  final _writing = <Future<Committing>>{};
  Future<void> _turn = Future.value();
  _HeldCommit? _held;
  _LeaseState _state = const _Open();

  @override
  int get maxKeyLength => indexedDbMaxKeyLength;

  @override
  LeaseStatus get status => switch (_state) {
    _Open() => const Holding(),
    _Ending() => const Ended(),
  };

  Stored<IDBTransaction> _transaction(IDBTransactionMode mode) {
    try {
      return Done(
        _db.transaction(
          _rows.toJS,
          mode,
          IDBTransactionOptions(durability: 'strict'),
        ),
      );
    } on Object catch (error) {
      return StorageFailed(_thrown(error, 'starting a transaction'));
    }
  }

  Future<Stored<T>> _reading<T>(
    String what,
    Future<Stored<T>> Function(IDBObjectStore rows) read,
  ) async {
    if (_state is! _Open) return const StorageFailed(LeaseEnded());
    switch (_transaction('readonly')) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(value: final transaction):
        try {
          return await read(transaction.objectStore(_rows));
        } on Object catch (error) {
          return StorageFailed(_thrown(error, what));
        }
    }
  }

  @override
  Future<KeyRead> read(String area, String key) async {
    if (_state is! _Open) return const KeyNotRead(LeaseEnded());
    if (pastLimit(area, key, indexedDbMaxKeyLength)) return const KeyMissing();
    final read = await _reading(
      'reading',
      (rows) async => Done(await _answer(rows.get(_key(area, key)), 'reading')),
    );
    return switch (read) {
      StorageFailed(:final failure) => KeyNotRead(failure),
      Done(value: _Failed(:final failure)) => KeyNotRead(failure),
      Done(value: _Nothing()) => const KeyMissing(),
      Done(value: _Value(:final value)) => switch (_text(value)) {
        final text? => KeyHeld(text),
        null => const KeyNotRead(_notText),
      },
    };
  }

  static Stored<List<String>> _listed(_Answer answer, int part) =>
      switch (answer) {
        _Failed(:final failure) => StorageFailed(failure),
        _Nothing() => const Done([]),
        _Value(:final value) => switch (_namesIn(value, part)) {
          final names? => Done(names),
          null => const StorageFailed(_notAName),
        },
      };

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) => _reading(
    'listing',
    (rows) async => _listed(
      await _answer(rows.getAllKeys(_under(area, prefix)), 'listing'),
      1,
    ),
  );

  static IDBKeyRange _under(String area, String prefix) => IDBKeyRange.bound(
    _key(area, prefix),
    switch (_afterUnits(prefix)) {
      null => [area.toJS, JSArray<JSAny>()].toJS,
      final after => _key(area, after),
    },
    false,
    true,
  );

  @override
  Future<Stored<List<String>>> areas(String prefix) => _reading(
    'listing areas',
    (rows) {
      final lower = [prefix.toJS].toJS;
      final range = switch (_afterUnits(prefix)) {
        null => IDBKeyRange.lowerBound(lower),
        final after => IDBKeyRange.bound(lower, [after.toJS].toJS, false, true),
      };
      final found = <String>[];
      final listed = Completer<Stored<List<String>>>();
      final request = rows.openKeyCursor(range);
      request
        ..onsuccess = ((Event _) {
          if (listed.isCompleted) return;
          unawaited(
            Future<Stored<List<String>>?>.sync(() {
              final cursor = request.result as IDBCursor?;
              if (cursor == null) return Done(found);
              switch (_namesIn([cursor.key].toJS, 0)) {
                case [final area]:
                  found.add(area);
                  cursor.continue_([area.toJS, JSArray<JSAny>()].toJS);
                  return null;
                case _:
                  return const StorageFailed(_notAName);
              }
            }).then((finished) {
              if (finished != null) _into(listed, () => finished);
            }, onError: listed.completeError),
          );
        }).toJS
        ..onerror = ((Event event) {
          event.preventDefault();
          _into(
            listed,
            () => StorageFailed<List<String>>(
              _named(request.error, 'listing areas'),
            ),
          );
        }).toJS;
      return listed.future;
    },
  );

  @override
  Future<Stored<List<StoredEntry>>> entries(
    String area,
    String prefix,
  ) => _reading('reading', (rows) async {
    final range = _under(area, prefix);
    final keys = _answer(rows.getAllKeys(range), 'listing');
    final values = _answer(rows.getAll(range), 'reading');
    switch ((_listed(await keys, 1), await values)) {
      case (StorageFailed(:final failure), _) || (_, _Failed(:final failure)):
        return StorageFailed(failure);
      case (Done(value: final names), _Nothing()):
        return names.isEmpty ? const Done([]) : const StorageFailed(_notText);
      case (Done(value: final names), _Value(:final value)):
        if (!value.isA<JSArray>()) return const StorageFailed(_notText);
        final texts = (value as JSArray<JSAny?>).toDart;
        if (texts.length != names.length) {
          return const StorageFailed(_notText);
        }
        final found = <StoredEntry>[];
        for (var i = 0; i < names.length; i++) {
          final text = _text(texts[i]);
          if (text == null) return const StorageFailed(_notText);
          found.add((key: names[i], value: text));
        }
        return Done(found);
    }
  });

  @override
  Future<Committing> commit(List<Change> changes) {
    if (_state is! _Open) {
      return Future.value(const CommitRefused(LeaseEnded()));
    }
    final copied = List<Change>.of(changes);
    if (refusedName(copied, indexedDbMaxKeyLength) case final failure?) {
      return Future.value(CommitRefused(failure));
    }
    final committing = _committed(copied);
    _writing.add(committing);
    return committing.whenComplete(() => _writing.remove(committing));
  }

  Future<Committing> _committed(List<Change> changes) async {
    final previous = _turn;
    final turn = Completer<void>();
    _turn = turn.future;
    await previous;
    final ({Future<Committing> landing}) begun;
    try {
      begun = await _begin(changes);
    } finally {
      turn.complete();
    }
    return begun.landing;
  }

  Future<({Future<Committing> landing})> _begin(List<Change> changes) async {
    if (_held case final held?) {
      _held = null;
      held._reached.complete();
      await held._letGo.future;
    }
    if (await _room.refuses(changes) case final failure?) {
      return (landing: Future.value(CommitRefused(failure)));
    }
    return switch (_transaction('readwrite')) {
      StorageFailed(:final failure) => (
        landing: Future.value(CommitRefused(failure)),
      ),
      Done(value: final transaction) => (landing: _queue(transaction, changes)),
    };
  }

  Future<Committing> _queue(IDBTransaction transaction, List<Change> changes) {
    final landed = Completer<Committing>();
    StorageFailure? notQueued;
    transaction
      ..oncomplete = ((Event _) => _into(landed, () {
        if (notQueued case final failure?) return CommitUnknown(failure);
        _room.spent(changes);
        return const CommitApplied();
      })).toJS
      ..onabort = ((Event _) => _into(
        landed,
        () => switch ((notQueued, transaction.error)) {
          (final StorageFailure failure?, _) => CommitRefused(failure),
          (null, final error?) when error.name == 'QuotaExceededError' =>
            CommitUnknown(AbortedForQuota(error.message)),
          (null, final error) => CommitRefused(_named(error, 'committing')),
        },
      )).toJS;
    try {
      final rows = transaction.objectStore(_rows);
      for (final change in changes) {
        switch (change) {
          case Put(:final area, :final key, :final value):
            rows.put(value.toJS, _key(area, key));
          case Delete(:final area, :final key):
            rows.delete(_key(area, key));
          case ClearArea(:final area):
            rows.delete(_under(area, ''));
        }
      }
    } on Object catch (error) {
      final failure = notQueued = _thrown(error, 'queuing a change');
      if (_abort(transaction) case final unconfirmed?) {
        _into(
          landed,
          () => CommitUnknown(
            DeviceFailure('$failure, and the abort failed: $unconfirmed'),
          ),
        );
      }
    }
    return landed.future;
  }

  static StorageFailure? _abort(IDBTransaction transaction) {
    try {
      transaction.abort();
      return null;
    } on Object catch (error) {
      return _thrown(error, 'aborting');
    }
  }

  @override
  Future<Releasing> release() => switch (_state) {
    _Ending(:final releasing) => releasing,
    _Open() => (_state = _Ending(_release())).releasing,
  };

  Future<Releasing> _release() async {
    await Future.wait([..._writing]);
    _db.close();
    await _lock.letGo();
    return const Released();
  }
}

final class _HeldCommit implements PendingWrite {
  final _reached = Completer<void>();
  final _letGo = Completer<void>();

  @override
  Future<void> get reached => _reached.future;

  @override
  void letGo() => _letGo.complete();
}
