import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart';

import '../engines/names.dart';
import '../store/engine.dart';
import '../store/engine_contract.dart';

const _rows = 'rows';

const indexedDbMaxKeyLength = 1024;

const indexedDbFormat = 1;

const roomMargin = 1024 * 1024;

const _bytesPerPut = 1024;

const _refreshRoomEvery = Duration(seconds: 10);

StorageFailure _named(DOMException? error, String what) => switch (error) {
  null => DeviceFailure('$what was aborted'),
  _ when error.name == 'QuotaExceededError' => OutOfRoom(
    '$what failed: ${error.message}',
  ),
  _ => DeviceFailure('$what failed: ${error.name}: ${error.message}'),
};

StorageFailure _thrown(Object error, String what) => switch (error) {
  TimeoutException(:final duration?) => NoAnswer(what, duration),
  final JSAny thrown when thrown.isA<DOMException>() => _named(
    thrown as DOMException,
    what,
  ),
  _ => DeviceFailure('$what threw: $error'),
};

Future<StorageFailure?> _settles(
  Future<void> Function() call,
  String what,
  Duration patience,
) => Future.sync(call)
    .timeout(patience)
    .then<StorageFailure?>(
      (_) => null,
      onError: (Object error) => _thrown(error, what),
    );

StorageFailure? _done(void Function() call, String what) {
  try {
    call();
    return null;
  } on Object catch (error) {
    return _thrown(error, what);
  }
}

StorageFailure? _closeDatabase(IDBDatabase db) =>
    _done(() => db.close(), 'closing the database');

void _into<T>(Completer<T> answer, T Function() compute) {
  if (answer.isCompleted) return;
  final T value;
  try {
    value = compute();
  } on Object catch (error, stack) {
    answer.completeError(error, stack);
    return;
  }
  answer.complete(value);
}

void _step<T extends Object>(Completer<T> answer, T? Function() step) {
  if (answer.isCompleted) return;
  final T? finished;
  try {
    finished = step();
  } on Object catch (error, stack) {
    answer.completeError(error, stack);
    return;
  }
  if (finished != null) answer.complete(finished);
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

const _notText = DamagedLibrary('the library holds a value that is not text');

const _notAName = DamagedLibrary('the library holds a key that is not a name');

String? _text(JSAny? value) =>
    value.isA<JSString>() ? (value as JSString).toDart : null;

List<JSAny?>? _list(JSAny? value) =>
    value.isA<JSArray>() ? (value as JSArray<JSAny?>).toDart : null;

sealed class _Answer {
  const _Answer();
}

final class _Value extends _Answer {
  const _Value(this.value);

  final JSAny? value;
}

final class _Failed extends _Answer {
  const _Failed(this.failure);

  final StorageFailure failure;
}

Future<_Answer> _answer(IDBRequest request, String what, Duration patience) {
  final answered = Completer<_Answer>();
  request
    ..onsuccess = ((Event _) => _into(
      answered,
      () => _Value(request.result),
    )).toJS
    ..onerror = ((Event event) {
      event.preventDefault();
      _into(answered, () => _Failed(_named(request.error, what)));
    }).toJS;
  return answered.future.timeout(
    patience,
    onTimeout: () => _Failed(NoAnswer(what, patience)),
  );
}

List<String>? _namesIn(JSAny? keys, int part) {
  final listed = _list(keys);
  if (listed == null) return null;
  final names = <String>[];
  for (final key in listed) {
    final parts = _list(key);
    final name = parts != null && parts.length == 2 ? _text(parts[part]) : null;
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

final class _NewerThanOpened extends _Opened {
  const _NewerThanOpened();
}

Future<_Opened> _openDatabase(String name, Duration patience) {
  final opened = Completer<_Opened>();
  var created = false;
  final request = window.indexedDB.open(name, indexedDbFormat);
  request
    ..onupgradeneeded = ((IDBVersionChangeEvent _) {
      created = true;
      final made = _done(
        () => (request.result! as IDBDatabase).createObjectStore(_rows),
        'creating the rows store',
      );
      if (made case final failure?) {
        _into(opened, () => _Refused(failure));
        _done(() => request.transaction?.abort(), 'aborting the upgrade');
      }
    }).toJS
    ..onsuccess = ((Event _) {
      if (opened.isCompleted) {
        _done(
          () => (request.result! as IDBDatabase).close(),
          'closing an open that came too late',
        );
        return;
      }
      _into(
        opened,
        () => _Database(request.result! as IDBDatabase, created: created),
      );
    }).toJS
    ..onerror = ((Event event) {
      event.preventDefault();
      _into(
        opened,
        () => request.error?.name == 'VersionError'
            ? const _NewerThanOpened()
            : _Refused(_named(request.error, 'opening')),
      );
    }).toJS;
  final waiting = Timer(
    patience,
    () => _into(
      opened,
      () => _Refused(NoAnswer('opening the database', patience)),
    ),
  );
  return opened.future.whenComplete(waiting.cancel);
}

Future<StorageFailure?> _deleteDatabase(String name, Duration patience) {
  const what = 'deleting the database the lease created';
  final deleted = Completer<StorageFailure?>();
  final IDBOpenDBRequest request;
  try {
    request = window.indexedDB.deleteDatabase(name);
  } on Object catch (error) {
    return Future.value(_thrown(error, what));
  }
  request
    ..onsuccess = ((Event _) => _into(deleted, () => null)).toJS
    ..onerror = ((Event event) {
      event.preventDefault();
      _into(deleted, () => _named(request.error, what));
    }).toJS;
  return deleted.future.timeout(
    patience,
    onTimeout: () => NoAnswer(what, patience),
  );
}

Future<Stored<int>> _versionOf(String name, Duration patience) {
  const what = 'reading the version of a newer database';
  final read = Completer<Stored<int>>();
  final request = window.indexedDB.open(name);
  request
    ..onsuccess = ((Event _) => _into(read, () {
      final db = request.result! as IDBDatabase;
      final version = db.version;
      db.close();
      return Done(version);
    })).toJS
    ..onerror = ((Event event) {
      event.preventDefault();
      _into(read, () => StorageFailed<int>(_named(request.error, what)));
    }).toJS;
  return read.future.timeout(
    patience,
    onTimeout: () => StorageFailed(NoAnswer(what, patience)),
  );
}

StorageFailure? _problemWith(IDBDatabase db) {
  if (!db.objectStoreNames.contains(_rows)) {
    return const DamagedLibrary('not an Icarus library (no rows store)');
  }
  return null;
}

Future<bool> _keepsWritesStrict(IDBDatabase db, Duration patience) {
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
  return ended.future.timeout(patience).then((_) => durability == 'strict');
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

  Future<StorageFailure?> letGo(Duration patience) async {
    if (!_letGo.isCompleted) _letGo.complete();
    if (!_granted.isCompleted || !await _granted.future) return null;
    return _settles(() => _ended, 'letting go of the lock', patience);
  }
}

sealed class RoomCheck {
  const RoomCheck();
}

final class RoomChecked extends RoomCheck {
  const RoomChecked();
}

final class RoomNotChecked extends RoomCheck {
  const RoomNotChecked(this.why);

  final String why;
}

sealed class _Estimate {
  const _Estimate();
}

final class _Estimated extends _Estimate {
  const _Estimated(this.left);

  final int left;
}

final class _NoEstimate extends _Estimate {
  const _NoEstimate(this.why);

  final String why;
}

final class _Room {
  _Room(this._patience);

  final Duration _patience;
  int? _left;
  String _unchecked = 'the browser has not said how much room there is';
  var _reserved = 0;
  final _sinceAsked = Stopwatch();
  Future<void>? _asking;

  RoomCheck get check =>
      _left == null ? RoomNotChecked(_unchecked) : const RoomChecked();

  static int charge(List<Change> changes) => changes.fold(
    0,
    (total, change) =>
        total +
        switch (change) {
          Put(:final area, :final key, :final value) =>
            _bytesPerPut + 2 * (area.length + key.length + value.length),
          Delete() || ClearArea() => 0,
        },
  );

  Future<_Estimate> _estimate() {
    if (!window.navigator.has('storage')) {
      return Future.value(
        const _NoEstimate('this browser cannot estimate its storage'),
      );
    }
    return Future.sync(() => window.navigator.storage.estimate().toDart)
        .timeout(_patience)
        .then<_Estimate>(
          (estimate) => _Estimated(estimate.quota - estimate.usage),
          onError: (Object error) =>
              _NoEstimate('${_thrown(error, 'estimating storage')}'),
        );
  }

  Future<void> ask() => _asking ??= () {
    _sinceAsked
      ..reset()
      ..start();
    return _estimate().then((estimate) {
      switch (estimate) {
        case _Estimated(:final left):
          _left = left;
        case _NoEstimate(:final why):
          _unchecked = why;
      }
      _asking = null;
    });
  }();

  bool _fits(int charge) => switch (_left) {
    null => true,
    final left => charge + _reserved + roomMargin <= left,
  };

  Future<StorageFailure?> admit(int charge) async {
    if (charge == 0) return null;
    if (_sinceAsked.elapsed > _refreshRoomEvery) unawaited(ask());
    if (!_fits(charge)) await ask();
    if (!_fits(charge)) {
      return NoRoomForCommit(
        needed: charge + _reserved + roomMargin,
        left: _left ?? 0,
      );
    }
    _reserved += charge;
    return null;
  }

  void settle(int charge, Committing outcome) {
    _reserved -= charge;
    if (_left case final left? when outcome is! CommitRefused) {
      _left = left - charge;
    }
  }
}

final class _Acquiring {
  _Lock? lock;
  IDBDatabase? db;
  bool created = false;
  IndexedDbLease? lease;

  Future<StorageFailure?> giveBack(String name, Duration patience) async {
    final failures = [
      if (db case final db?) _closeDatabase(db),
      if (created) await _deleteDatabase(name, patience),
      if (lock case final lock?) await lock.letGo(patience),
    ].nonNulls;
    return failures.isEmpty ? null : failures.first;
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
      return const LeaseFailed(BrowserLacks(BrowserFeature.webLocks));
    }
    final acquiring = _Acquiring();
    final Leasing leasing;
    try {
      leasing = await _acquire(acquiring);
    } on Object catch (error) {
      return _givenBack(
        acquiring,
        LeaseFailed(_thrown(error, 'leasing the library')),
      );
    }
    return acquiring.lease == null ? _givenBack(acquiring, leasing) : leasing;
  }

  Future<Leasing> _givenBack(_Acquiring acquiring, Leasing leasing) async =>
      switch ((leasing, await acquiring.giveBack(name, patience))) {
        (LeaseFailed(), _) => leasing,
        (_, final StorageFailure left?) => LeaseFailed(left),
        _ => leasing,
      };

  Future<Leasing> _acquire(_Acquiring acquiring) async {
    final lock = acquiring.lock = _Lock(name);
    if (!await lock.held.timeout(patience)) return const HeldByAnotherWriter();
    final IDBDatabase db;
    switch (await _openDatabase(name, patience)) {
      case _Refused(:final failure):
        return LeaseFailed(failure);
      case _NewerThanOpened():
        return LeaseFailed(switch (await _versionOf(name, patience)) {
          Done(value: final found) => NewerFormat(
            FormatLayer.engine,
            found: found,
            known: indexedDbFormat,
          ),
          StorageFailed(:final failure) => failure,
        });
      case _Database(db: final opened, :final created):
        db = acquiring.db = opened;
        acquiring.created = created;
    }
    if (_problemWith(db) case final problem?) return LeaseFailed(problem);
    if (!await _keepsWritesStrict(db, patience)) {
      return const LeaseFailed(BrowserLacks(BrowserFeature.strictDurability));
    }
    final room = _Room(patience);
    await room.ask();
    final lease = acquiring.lease = IndexedDbLease._(db, lock, room, patience);
    _granted.add(lease);
    return _closed ? const LeaseFailed(EngineClosed()) : Leased(lease);
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
  IndexedDbLease._(this._db, this._lock, this._room, this._patience) {
    _db
      ..onversionchange = ((Event _) => unawaited(release())).toJS
      ..onclose = ((Event _) => unawaited(release())).toJS;
  }

  final IDBDatabase _db;
  final _Lock _lock;
  final _Room _room;
  final Duration _patience;
  final _writing = <Future<Committing>>{};
  Future<void> _turn = Future.value();
  _HeldCommit? _held;
  _LeaseState _state = const _Open();

  RoomCheck get roomCheck => _room.check;

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
      (rows) async => Done(
        await _answer(rows.getAll(_key(area, key)), 'reading', _patience),
      ),
    );
    return switch (read) {
      StorageFailed(:final failure) => KeyNotRead(failure),
      Done(value: _Failed(:final failure)) => KeyNotRead(failure),
      Done(value: _Value(:final value)) => switch (_list(value)) {
        [] => const KeyMissing(),
        [final stored] => switch (_text(stored)) {
          final text? => KeyHeld(text),
          null => const KeyNotRead(_notText),
        },
        _ => const KeyNotRead(_notText),
      },
    };
  }

  static Stored<List<String>> _listed(_Answer answer, int part) =>
      switch (answer) {
        _Failed(:final failure) => StorageFailed(failure),
        _Value(:final value) => switch (_namesIn(value, part)) {
          final names? => Done(names),
          null => const StorageFailed(_notAName),
        },
      };

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) => _reading(
    'listing',
    (rows) async => _listed(
      await _answer(
        rows.getAllKeys(_under(area, prefix)),
        'listing',
        _patience,
      ),
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
          _step<Stored<List<String>>>(listed, () {
            final cursor = request.result as IDBCursor?;
            if (cursor == null) return Done(found);
            switch (_namesIn([cursor.key].toJS, 0)) {
              case [final area]:
                found.add(area);
                cursor.continue_([area.toJS, JSArray<JSAny>()].toJS);
                return null;
              case _:
                return const StorageFailed<List<String>>(_notAName);
            }
          });
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
      return listed.future.timeout(
        _patience,
        onTimeout: () => StorageFailed(NoAnswer('listing areas', _patience)),
      );
    },
  );

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _reading('reading', (rows) async {
        final range = _under(area, prefix);
        final keys = _answer(rows.getAllKeys(range), 'listing', _patience);
        final values = _answer(rows.getAll(range), 'reading', _patience);
        switch ((_listed(await keys, 1), await values)) {
          case (StorageFailed(:final failure), _) ||
              (_, _Failed(:final failure)):
            return StorageFailed(failure);
          case (Done(value: final names), _Value(:final value)):
            final texts = _list(value);
            if (texts == null || texts.length != names.length) {
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
    final charge = _Room.charge(changes);
    var admitted = false;
    Committing outcome;
    try {
      outcome = await _inTurn(changes, charge, () => admitted = true);
    } on Object catch (error) {
      outcome = CommitUnknown(_thrown(error, 'committing'));
    }
    if (admitted) _room.settle(charge, outcome);
    return outcome;
  }

  Future<Committing> _inTurn(
    List<Change> changes,
    int charge,
    void Function() admitted,
  ) async {
    final previous = _turn;
    final turn = Completer<void>();
    _turn = turn.future;
    final ({Future<Committing> landing}) begun;
    try {
      await previous;
      begun = await _begin(changes, charge, admitted);
    } finally {
      turn.complete();
    }
    return begun.landing;
  }

  Future<({Future<Committing> landing})> _begin(
    List<Change> changes,
    int charge,
    void Function() admitted,
  ) async {
    if (_held case final held?) {
      _held = null;
      held._reached.complete();
      await held._letGo.future;
    }
    if (await _room.admit(charge) case final failure?) {
      return (landing: Future.value(CommitRefused(failure)));
    }
    admitted();
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
      ..oncomplete = ((Event _) => _into(
        landed,
        () => switch (notQueued) {
          final failure? => CommitUnknown(failure),
          null => const CommitApplied(),
        },
      )).toJS
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
      if (_done(() => transaction.abort(), 'aborting')
          case final unconfirmed?) {
        _into(
          landed,
          () => CommitUnknown(
            DeviceFailure('$failure, and the abort failed: $unconfirmed'),
          ),
        );
      }
    }
    return landed.future.timeout(
      _patience,
      onTimeout: () => CommitUnknown(NoAnswer('committing', _patience)),
    );
  }

  @override
  Future<Releasing> release() => switch (_state) {
    _Ending(:final releasing) => releasing,
    _Open() => (_state = _Ending(_release())).releasing,
  };

  Future<Releasing> _release() async {
    await Future.wait([..._writing]);
    final failures = [
      _closeDatabase(_db),
      await _lock.letGo(_patience),
    ].nonNulls;
    return failures.isEmpty ? const Released() : ReleaseFailed(failures.first);
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
