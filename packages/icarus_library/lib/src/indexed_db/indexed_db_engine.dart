import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart';

import '../engines/names.dart';
import '../store/engine.dart';
import '../store/engine_contract.dart';

const _rows = 'rows';

const _last = 'last';

const _lastCommitKey = 'commit';

const indexedDbMaxKeyLength = 1024;

const indexedDbFormat = 2;

const roomMargin = 1024 * 1024;

const _bytesPerPut = 1024;

const _bytesPerRecord = 1024;

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

StorageFailure? _abortOf(IDBTransaction transaction) =>
    _done(() => transaction.abort(), 'aborting');

void _handled(Event event) =>
    _done(() => event.preventDefault(), 'handling an error event');

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
      _handled(event);
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
    ..onupgradeneeded = ((IDBVersionChangeEvent event) {
      if (opened.isCompleted) {
        _done(() => request.transaction?.abort(), 'aborting a late upgrade');
        return;
      }
      final made = _done(() {
        final from = event.oldVersion;
        created = from == 0;
        final db = request.result! as IDBDatabase;
        if (from < 1) db.createObjectStore(_rows);
        if (from < 2) db.createObjectStore(_last);
      }, 'creating the library\'s stores');
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
      _handled(event);
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
      _handled(event);
      _into(deleted, () => _named(request.error, what));
    }).toJS;
  return deleted.future.timeout(
    patience,
    onTimeout: () => NoAnswer(what, patience),
  );
}

Future<Stored<int>> _versionOf(String name, Duration patience) {
  const what = 'reading the version of a newer database';
  return Future.sync(() => window.indexedDB.databases().toDart)
      .timeout(patience)
      .then<Stored<int>>(
        (listed) => switch ([
          for (final info in listed.toDart)
            if (info.name == name) info.version,
        ]) {
          [final version, ...] => Done(version),
          [] => const StorageFailed(
            DeviceFailure('the library was removed while it was being opened'),
          ),
        },
      )
      .then<Stored<int>>(
        (version) => version,
        onError: (Object error) => StorageFailed<int>(_thrown(error, what)),
      );
}

StorageFailure? _problemWith(IDBDatabase db) {
  if (!db.objectStoreNames.contains(_rows)) {
    return const DamagedLibrary('not an Icarus library (no rows store)');
  }
  if (!db.objectStoreNames.contains(_last)) {
    return const DamagedLibrary('not an Icarus library (no last-commit store)');
  }
  return null;
}

String _recordOf(List<Change> changes) => jsonEncode({
  'format': indexedDbFormat,
  'changes': [
    for (final change in changes)
      switch (change) {
        Put(:final area, :final key, :final value) => ['put', area, key, value],
        Delete(:final area, :final key) => ['delete', area, key],
        ClearArea(:final area) => ['clear', area],
      },
  ],
});

sealed class _LastCommit {
  const _LastCommit();
}

final class _NoLastCommit extends _LastCommit {
  const _NoLastCommit();
}

final class _Recorded extends _LastCommit {
  const _Recorded(this.changes);

  final List<Change> changes;
}

final class _Unreadable extends _LastCommit {
  const _Unreadable(this.failure);

  final StorageFailure failure;
}

const _damagedRecord = DamagedLibrary(
  'the record of the last commit cannot be read',
);

_LastCommit _parsedRecord(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const _Unreadable(_damagedRecord);
  }
  switch (decoded) {
    case {'format': final int format} when format > indexedDbFormat:
      return _Unreadable(
        NewerFormat(FormatLayer.engine, found: format, known: indexedDbFormat),
      );
    case {'format': indexedDbFormat, 'changes': final List<Object?> listed}:
      final changes = <Change>[];
      for (final entry in listed) {
        switch (entry) {
          case ['put', final String area, final String key, final String value]
              when isArea(area) && isName(key):
            changes.add(Put(area, key, value));
          case ['delete', final String area, final String key]
              when isArea(area) && isName(key):
            changes.add(Delete(area, key));
          case ['clear', final String area] when isArea(area):
            changes.add(ClearArea(area));
          case _:
            return const _Unreadable(_damagedRecord);
        }
      }
      if (refusedName(changes, indexedDbMaxKeyLength) != null) {
        return const _Unreadable(_damagedRecord);
      }
      return _Recorded(changes);
    case _:
      return const _Unreadable(_damagedRecord);
  }
}

void _queueChanges(IDBObjectStore rows, List<Change> changes) {
  for (final change in changes) {
    switch (change) {
      case Put(:final area, :final key, :final value):
        rows.put(value.toJS, _key(area, key));
      case Delete(:final area, :final key):
        rows.delete(_key(area, key));
      case ClearArea(:final area):
        rows.delete(_rangeOf(area, ''));
    }
  }
}

IDBKeyRange _rangeOf(String area, String prefix) => IDBKeyRange.bound(
  _key(area, prefix),
  switch (_afterUnits(prefix)) {
    null => [area.toJS, JSArray<JSAny>()].toJS,
    final after => _key(area, after),
  },
  false,
  true,
);

IDBTransaction _writeTransaction(IDBDatabase db) => db.transaction(
  [_rows.toJS, _last.toJS].toJS,
  'readwrite',
  IDBTransactionOptions(durability: 'strict'),
);

Future<_LastCommit> _lastCommit(IDBDatabase db, Duration patience) async {
  final transaction = db.transaction(_last.toJS, 'readonly');
  final answer = await _answer(
    transaction.objectStore(_last).getAll(_lastCommitKey.toJS),
    'reading the record of the last commit',
    patience,
  );
  return switch (answer) {
    _Failed(:final failure) => _Unreadable(failure),
    _Value(:final value) => switch (_list(value)) {
      [] => const _NoLastCommit(),
      [final stored] => switch (_text(stored)) {
        final text? => _parsedRecord(text),
        null => const _Unreadable(_damagedRecord),
      },
      _ => const _Unreadable(_damagedRecord),
    },
  };
}

Future<Stored<bool>> _landedWhole(
  IDBDatabase db,
  List<Change> changes,
  Duration patience,
) async {
  final cleared = <String>{};
  final expected = <String, Map<String, String?>>{};
  for (final change in changes) {
    switch (change) {
      case Put(:final area, :final key, :final value):
        (expected[area] ??= {})[key] = value;
      case Delete(:final area, :final key):
        (expected[area] ??= {})[key] = null;
      case ClearArea(:final area):
        cleared.add(area);
        expected[area] = {};
    }
  }
  const what = 'checking the last commit';
  final rows = db.transaction(_rows.toJS, 'readonly').objectStore(_rows);
  final areaKeys = {
    for (final area in cleared)
      area: _answer(rows.getAllKeys(_rangeOf(area, '')), what, patience),
  };
  final spans = {
    for (final MapEntry(key: area, value: keys) in expected.entries)
      if (keys.isNotEmpty)
        area: () {
          final sorted = keys.keys.toList()..sort(compareCodeUnits);
          final span = IDBKeyRange.bound(
            _key(area, sorted.first),
            _key(area, sorted.last),
          );
          return (
            keys: _answer(rows.getAllKeys(span), what, patience),
            values: _answer(rows.getAll(span), what, patience),
          );
        }(),
  };
  await Future.wait([
    ...areaKeys.values,
    for (final span in spans.values) ...[span.keys, span.values],
  ]);
  for (final MapEntry(key: area, value: listing) in areaKeys.entries) {
    switch (await listing) {
      case _Failed(:final failure):
        return StorageFailed(failure);
      case _Value(:final value):
        final present = _namesIn(value, 1);
        if (present == null) return const StorageFailed(_notAName);
        final wanted = {
          for (final MapEntry(:key, :value) in expected[area]!.entries)
            if (value != null) key,
        };
        if (present.length != wanted.length || !wanted.containsAll(present)) {
          return const Done(false);
        }
    }
  }
  for (final MapEntry(key: area, value: span) in spans.entries) {
    switch ((await span.keys, await span.values)) {
      case (_Failed(:final failure), _) || (_, _Failed(:final failure)):
        return StorageFailed(failure);
      case (_Value(value: final keys), _Value(value: final values)):
        final names = _namesIn(keys, 1);
        final texts = _list(values);
        if (names == null) return const StorageFailed(_notAName);
        if (texts == null || texts.length != names.length) {
          return const StorageFailed(_notText);
        }
        final stored = <String, String>{};
        for (var i = 0; i < names.length; i++) {
          final text = _text(texts[i]);
          if (text == null) return const StorageFailed(_notText);
          stored[names[i]] = text;
        }
        for (final MapEntry(:key, :value) in expected[area]!.entries) {
          if (stored[key] != value) return const Done(false);
        }
    }
  }
  return const Done(true);
}

Future<StorageFailure?> _replay(
  IDBDatabase db,
  List<Change> changes,
  Duration patience,
) {
  const what = 'completing the last commit';
  final finished = Completer<StorageFailure?>();
  final transaction = _writeTransaction(db);
  transaction
    ..oncomplete = ((Event _) => _into(finished, () => null)).toJS
    ..onabort = ((Event _) => _into(
      finished,
      () => switch (transaction.error) {
        final error? when error.name == 'QuotaExceededError' => OutOfRoom(
          '$what: ${error.message}',
        ),
        final error => _named(error, what),
      },
    )).toJS;
  try {
    _queueChanges(transaction.objectStore(_rows), changes);
  } on Object catch (error) {
    final failure = _thrown(error, what);
    _into(finished, () => _abortOf(transaction) ?? failure);
  }
  return finished.future.timeout(
    patience,
    onTimeout: () => NoAnswer(what, patience),
  );
}

Future<StorageFailure?> _finishLastCommit(
  IDBDatabase db,
  Duration patience,
) async {
  switch (await _lastCommit(db, patience)) {
    case _NoLastCommit():
      return null;
    case _Unreadable(:final failure):
      return failure;
    case _Recorded(:final changes):
      return switch (await _landedWhole(db, changes, patience)) {
        StorageFailed(:final failure) => failure,
        Done(value: true) => null,
        Done(value: false) => await _replay(db, changes, patience),
      };
  }
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
    _bytesPerRecord,
    (total, change) =>
        total +
        switch (change) {
          Put(:final area, :final key, :final value) =>
            2 * _bytesPerPut + 4 * (area.length + key.length + value.length),
          Delete(:final area, :final key) =>
            _bytesPerPut + 2 * (area.length + key.length),
          ClearArea(:final area) => _bytesPerPut + 2 * area.length,
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
        )
        .then<_Estimate>(
          (estimate) => estimate,
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
          _left = null;
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
    if (await _finishLastCommit(db, patience) case final failure?) {
      return LeaseFailed(failure);
    }
    final room = _Room(patience);
    await room.ask();
    final lease = acquiring.lease = IndexedDbLease._(db, lock, room, patience);
    _granted.add(lease);
    return _closed ? const LeaseFailed(EngineClosed()) : Leased(lease);
  }

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

final class _InDoubt extends _LeaseState {
  const _InDoubt(this.releasing);

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
    _Ending() || _InDoubt() => const Ended(),
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

  static IDBKeyRange _under(String area, String prefix) =>
      _rangeOf(area, prefix);

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
          _handled(event);
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
    try {
      await previous;
      Committing outcome;
      try {
        outcome = await (await _begin(changes, charge, admitted)).landing;
      } on Object catch (error) {
        outcome = CommitUnknown(_thrown(error, 'committing'));
      }
      if (outcome is CommitUnknown) _doubted();
      return outcome;
    } finally {
      turn.complete();
    }
  }

  Future<({Future<Committing> landing})> _begin(
    List<Change> changes,
    int charge,
    void Function() admitted,
  ) async {
    if (_state case _InDoubt()) {
      return (landing: Future.value(const CommitRefused(LeaseEnded())));
    }
    if (_held case final held?) {
      _held = null;
      held._reached.complete();
      await held._letGo.future;
    }
    if (_state case _InDoubt()) {
      return (landing: Future.value(const CommitRefused(LeaseEnded())));
    }
    if (await _room.admit(charge) case final failure?) {
      return (landing: Future.value(CommitRefused(failure)));
    }
    admitted();
    switch (await _record(changes)) {
      case _RecordRefused(:final failure):
        return (landing: Future.value(CommitRefused(failure)));
      case _RecordInDoubt(:final failure):
        return (landing: Future.value(CommitUnknown(failure)));
      case _RecordKept():
        break;
    }
    final IDBTransaction transaction;
    try {
      transaction = _writeTransaction(_db);
    } on Object catch (error) {
      return (
        landing: Future.value(
          CommitUnknown(_thrown(error, 'starting the changes')),
        ),
      );
    }
    return (landing: _queue(transaction, changes));
  }

  Future<_RecordOutcome> _record(List<Change> changes) {
    const what = 'recording the commit';
    final recorded = Completer<_RecordOutcome>();
    final IDBTransaction transaction;
    try {
      transaction = _writeTransaction(_db);
    } on Object catch (error) {
      return Future.value(_RecordRefused(_thrown(error, what)));
    }
    StorageFailure? notQueued;
    transaction
      ..oncomplete = ((Event _) => _into(
        recorded,
        () => switch (notQueued) {
          final failure? => _RecordInDoubt(failure),
          null => const _RecordKept(),
        },
      )).toJS
      ..onabort = ((Event _) => _into(
        recorded,
        () => switch ((notQueued, transaction.error)) {
          (final StorageFailure failure?, _) => _RecordRefused(failure),
          (null, final error?) when error.name == 'QuotaExceededError' =>
            _RecordInDoubt(AbortedForQuota(error.message)),
          (null, final error) => _RecordRefused(_named(error, what)),
        },
      )).toJS;
    try {
      transaction
          .objectStore(_last)
          .put(_recordOf(changes).toJS, _lastCommitKey.toJS);
    } on Object catch (error) {
      final failure = notQueued = _thrown(error, what);
      if (_abortOf(transaction) case final unconfirmed?) {
        _into(
          recorded,
          () => _RecordInDoubt(
            DeviceFailure('$failure, and the abort failed: $unconfirmed'),
          ),
        );
      }
    }
    return recorded.future.timeout(
      _patience,
      onTimeout: () => _RecordInDoubt(NoAnswer(what, _patience)),
    );
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
        () => CommitUnknown(switch ((notQueued, transaction.error)) {
          (final StorageFailure failure?, _) => failure,
          (null, final error?) when error.name == 'QuotaExceededError' =>
            AbortedForQuota(error.message),
          (null, final error) => _named(error, 'committing'),
        }),
      )).toJS;
    try {
      _queueChanges(transaction.objectStore(_rows), changes);
    } on Object catch (error) {
      final failure = notQueued = _thrown(error, 'queuing a change');
      if (_abortOf(transaction) case final unconfirmed?) {
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
    _Ending(:final releasing) || _InDoubt(:final releasing) => releasing,
    _Open() => (_state = _Ending(_release())).releasing,
  };

  void _doubted() {
    switch (_state) {
      case _Open():
        _state = _InDoubt(_release());
      case _Ending(:final releasing):
        _state = _InDoubt(releasing);
      case _InDoubt():
        break;
    }
  }

  Future<Releasing> _release() async {
    await Future.wait([..._writing]);
    final failures = [
      _closeDatabase(_db),
      await _lock.letGo(_patience),
    ].nonNulls;
    return failures.isEmpty ? const Released() : ReleaseFailed(failures.first);
  }
}

sealed class _RecordOutcome {
  const _RecordOutcome();
}

final class _RecordKept extends _RecordOutcome {
  const _RecordKept();
}

final class _RecordRefused extends _RecordOutcome {
  const _RecordRefused(this.failure);

  final StorageFailure failure;
}

final class _RecordInDoubt extends _RecordOutcome {
  const _RecordInDoubt(this.failure);

  final StorageFailure failure;
}

final class _HeldCommit implements PendingWrite {
  final _reached = Completer<void>();
  final _letGo = Completer<void>();

  @override
  Future<void> get reached => _reached.future;

  @override
  void letGo() => _letGo.complete();
}

extension IndexedDbEngineHold on IndexedDbEngine {
  PendingWrite holdNextCommit() => _granted.last._held = _HeldCommit();
}
