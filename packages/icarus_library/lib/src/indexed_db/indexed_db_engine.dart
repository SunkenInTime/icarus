import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart';

import '../store/engine.dart';

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

  @override
  Future<Leasing> lease() async {
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

  Future<void> close() async {
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
  final _writing = <Future<Stored<void>>>{};
  var _ended = false;

  @override
  int get maxKeyLength => indexedDbMaxKeyLength;

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
  Future<Stored<String?>> read(String area, String key) async {
    switch (_transaction('readonly')) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(value: final transaction):
        final request = transaction.objectStore(_rows).get(_key(area, key));
        return switch (await _result(request, 'reading')) {
          StorageFailed(:final failure) => StorageFailed(failure),
          Done(value: null) => const Done(null),
          Done(:final value?) when value.isA<JSString>() => Done(
            (value as JSString).toDart,
          ),
          Done() => const StorageFailed(
            DeviceFailure('the library holds a value that is not text'),
          ),
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

  Future<Stored<Map<String, String>>> entries(
    String area,
    String prefix,
  ) async {
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
            final found = <String, String>{};
            for (var i = 0; i < names.length; i++) {
              final text = texts[i];
              if (text == null || !text.isA<JSString>()) {
                return const StorageFailed(
                  DeviceFailure('the library holds a value that is not text'),
                );
              }
              found[names[i]] = (text as JSString).toDart;
            }
            return Done(found);
        }
    }
  }

  Future<Stored<void>> _change(
    String what,
    void Function(IDBObjectStore rows) changes,
  ) async {
    switch (_transaction('readwrite')) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(value: final transaction):
        final finished = Completer<Stored<void>>();
        transaction
          ..oncomplete = ((Event _) => finished.complete(done)).toJS
          ..onabort = ((Event _) => finished.complete(
            StorageFailed(_failure(transaction.error, what)),
          )).toJS;
        changes(transaction.objectStore(_rows));
        final writing = finished.future;
        _writing.add(writing);
        final result = await writing;
        _writing.remove(writing);
        return result;
    }
  }

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) =>
      _change('writing', (rows) {
        for (final MapEntry(:key, :value) in values.entries) {
          rows.put(value.toJS, _key(area, key));
        }
      });

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) =>
      _change('deleting', (rows) {
        for (final key in keys) {
          rows.delete(_key(area, key));
        }
      });

  @override
  Future<void> release() async {
    if (_ended) return;
    _ended = true;
    await Future.wait(_writing);
    _db.close();
    _release.complete();
    await _released;
  }
}
