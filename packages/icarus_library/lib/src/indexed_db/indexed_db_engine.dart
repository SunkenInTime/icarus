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

StorageFailure _failure(DOMException? error, String what) =>
    DeviceFailure(switch (error) {
      null => '$what was aborted',
      _ => '$what failed: ${error.name}: ${error.message}',
    });

JSArray<JSAny> _key(String area, String key) => [area.toJS, key.toJS].toJS;

String? _afterUnits(String prefix) {
  final units = prefix.codeUnits.toList();
  while (units.isNotEmpty) {
    final last = units.removeLast();
    if (last < 0xFFFF) return String.fromCharCodes([...units, last + 1]);
  }
  return null;
}

Future<Stored<JSAny?>> _result(IDBRequest request, String what) {
  final result = Completer<Stored<JSAny?>>();
  request
    ..onsuccess = ((Event _) => result.complete(Done(request.result))).toJS
    ..onerror = ((Event event) {
      event.preventDefault();
      result.complete(StorageFailed(_failure(request.error, what)));
    }).toJS;
  return result.future;
}

sealed class _Opened {
  const _Opened();
}

final class _Database extends _Opened {
  const _Database(this.db);

  final IDBDatabase db;
}

final class _Refused extends _Opened {
  const _Refused(this.failure);

  final StorageFailure failure;
}

_Refused _cannotOpen(String why) =>
    _Refused(DeviceFailure('the library cannot be opened: $why'));

Future<_Opened> _openDatabase(String name) {
  final opened = Completer<_Opened>();
  final IDBOpenDBRequest request;
  try {
    request = window.indexedDB.open(name);
    // ignore: invalid_runtime_check_with_js_interop_types
  } on DOMException catch (error) {
    return Future.value(_Refused(_failure(error, 'opening')));
  }
  request
    ..onupgradeneeded = ((IDBVersionChangeEvent _) {
      (request.result as IDBDatabase).createObjectStore(_rows);
    }).toJS
    ..onsuccess = ((Event _) {
      final db = request.result as IDBDatabase;
      if (db.version != indexedDbVersion) {
        db.close();
        opened.complete(
          _cannotOpen('written by a newer build (version ${db.version})'),
        );
      } else if (!db.objectStoreNames.contains(_rows)) {
        db.close();
        opened.complete(_cannotOpen('not an Icarus library (no rows store)'));
      } else {
        opened.complete(_Database(db));
      }
    }).toJS
    ..onerror = ((Event event) {
      event.preventDefault();
      opened.complete(_Refused(_failure(request.error, 'opening')));
    }).toJS;
  return opened.future;
}

final class IndexedDbEngine implements StorageEngine {
  IndexedDbEngine(this.name);

  final String name;
  final _granted = <IndexedDbLease>[];
  var _closed = false;

  @override
  Future<Leasing> lease() async {
    if (_closed) return const LeaseFailed(EngineClosed());
    final navigator = window.navigator;
    if (!navigator.has('locks')) {
      return const LeaseFailed(
        DeviceFailure('this page cannot hold the library: no Web Locks'),
      );
    }
    final granted = Completer<bool>();
    final release = Completer<void>();
    final released = navigator.locks
        .request(
          name,
          LockOptions(ifAvailable: true),
          ((Lock? lock) {
            if (lock == null) {
              granted.complete(false);
              return null;
            }
            granted.complete(true);
            return release.future.toJS;
          }).toJS,
        )
        .toDart;
    if (!await granted.future) {
      await released;
      return const HeldByAnotherWriter();
    }
    switch (await _openDatabase(name)) {
      case _Refused(:final failure):
        release.complete();
        await released;
        return LeaseFailed(failure);
      case _Database(:final db):
        final lease = IndexedDbLease._(db, release, released);
        _granted.add(lease);
        return Leased(lease);
    }
  }

  PendingWrite holdNextCommit() => _granted.last._held = _HeldCommit();

  Future<void> close() async {
    _closed = true;
    for (final lease in _granted) {
      await lease.release();
    }
    _granted.clear();
  }
}

final class IndexedDbLease implements StorageLease {
  IndexedDbLease._(this._db, this._release, this._released);

  final IDBDatabase _db;
  final Completer<void> _release;
  final Future<JSAny?> _released;
  final _writing = <Future<Committing>>{};
  _HeldCommit? _held;
  var _ended = false;

  @override
  int get maxKeyLength => indexedDbMaxKeyLength;

  @override
  LeaseStatus get status => _ended ? const Ended() : const Holding();

  static const _notText = DeviceFailure(
    'the library holds a value that is not text',
  );

  Stored<IDBTransaction> _transaction(IDBTransactionMode mode) {
    if (_ended) return const StorageFailed(LeaseEnded());
    try {
      return Done(
        _db.transaction(
          _rows.toJS,
          mode,
          IDBTransactionOptions(durability: 'strict'),
        ),
      );
      // ignore: invalid_runtime_check_with_js_interop_types
    } on DOMException catch (error) {
      return StorageFailed(_failure(error, 'starting a transaction'));
    }
  }

  @override
  Future<KeyRead> read(String area, String key) async {
    if (_ended) return const KeyNotRead(LeaseEnded());
    if (pastLimit(area, key, indexedDbMaxKeyLength)) return const KeyMissing();
    switch (_transaction('readonly')) {
      case StorageFailed(:final failure):
        return KeyNotRead(failure);
      case Done(value: final transaction):
        final request = transaction.objectStore(_rows).get(_key(area, key));
        return switch (await _result(request, 'reading')) {
          StorageFailed(:final failure) => KeyNotRead(failure),
          Done(value: null) => const KeyMissing(),
          Done(:final value?) when value.isA<JSString>() => KeyHeld(
            (value as JSString).toDart,
          ),
          Done() => const KeyNotRead(_notText),
        };
    }
  }

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async {
    switch (_transaction('readonly')) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(value: final transaction):
        final request = transaction
            .objectStore(_rows)
            .getAllKeys(_under(area, prefix));
        return switch (await _result(request, 'listing')) {
          StorageFailed(:final failure) => StorageFailed(failure),
          Done(:final value) => Done(_keysOf(value)),
        };
    }
  }

  static IDBKeyRange _under(String area, String prefix) => IDBKeyRange.bound(
    _key(area, prefix),
    switch (_afterUnits(prefix)) {
      null => [area.toJS, JSArray<JSAny>()].toJS,
      final after => _key(area, after),
    },
    false,
    true,
  );

  static List<String> _keysOf(JSAny? keys) => [
    for (final key in (keys as JSArray<JSArray<JSString>>).toDart)
      key.toDart[1].toDart,
  ];

  @override
  Future<Stored<List<String>>> areas(String prefix) async {
    switch (_transaction('readonly')) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(value: final transaction):
        final lower = [prefix.toJS].toJS;
        final range = switch (_afterUnits(prefix)) {
          null => IDBKeyRange.lowerBound(lower),
          final after => IDBKeyRange.bound(
            lower,
            [after.toJS].toJS,
            false,
            true,
          ),
        };
        final found = <String>[];
        final listed = Completer<Stored<List<String>>>();
        final request = transaction.objectStore(_rows).openKeyCursor(range);
        request
          ..onsuccess = ((Event _) {
            final cursor = request.result as IDBCursor?;
            if (cursor == null) {
              listed.complete(Done(found));
              return;
            }
            final key = (cursor.key! as JSArray<JSString>).toDart;
            final area = key[0].toDart;
            found.add(area);
            cursor.continue_([area.toJS, JSArray<JSAny>()].toJS);
          }).toJS
          ..onerror = ((Event event) {
            event.preventDefault();
            listed.complete(
              StorageFailed(_failure(request.error, 'listing areas')),
            );
          }).toJS;
        return listed.future;
    }
  }

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async {
    switch (_transaction('readonly')) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(value: final transaction):
        final rows = transaction.objectStore(_rows);
        final range = _under(area, prefix);
        final keys = _result(rows.getAllKeys(range), 'listing');
        final values = _result(rows.getAll(range), 'reading');
        switch ((await keys, await values)) {
          case (StorageFailed(:final failure), _) ||
              (_, StorageFailed(:final failure)):
            return StorageFailed(failure);
          case (Done(value: final listed), Done(value: final read)):
            final texts = (read as JSArray<JSAny?>).toDart;
            final names = _keysOf(listed);
            final found = <StoredEntry>[];
            for (var i = 0; i < names.length; i++) {
              final text = texts[i];
              if (text == null || !text.isA<JSString>()) {
                return const StorageFailed(_notText);
              }
              found.add((key: names[i], value: (text as JSString).toDart));
            }
            return Done(found);
        }
    }
  }

  @override
  Future<Committing> commit(List<Change> changes) {
    if (_ended) return Future.value(const CommitRefused(LeaseEnded()));
    if (refusedName(changes, indexedDbMaxKeyLength) case final failure?) {
      return Future.value(CommitRefused(failure));
    }
    final committing = _committed(changes);
    _writing.add(committing);
    return committing.whenComplete(() => _writing.remove(committing));
  }

  Future<Committing> _committed(List<Change> changes) async {
    if (_held case final held?) {
      _held = null;
      held._reached.complete();
      await held._letGo.future;
    }
    switch (_transaction('readwrite')) {
      case StorageFailed(:final failure):
        return CommitRefused(failure);
      case Done(value: final transaction):
        final finished = Completer<Committing>();
        transaction
          ..oncomplete = ((Event _) => finished.complete(
            const CommitApplied(),
          )).toJS
          ..onabort = ((Event _) => finished.complete(
            CommitRefused(_failure(transaction.error, 'committing')),
          )).toJS;
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
        return finished.future;
    }
  }

  @override
  Future<Releasing> release() async {
    if (_ended) return const Released();
    _ended = true;
    await Future.wait(_writing);
    _db.close();
    _release.complete();
    await _released;
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
