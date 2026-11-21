import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:icarus_library/engine_contract.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/indexed_db_storage.dart';
import 'package:web/web.dart';

import '../crash_harness.dart';
import '../store_support.dart';

const _patch = '''
(() => {
  if (globalThis.icarusFaults) return;
  const faults = {
    abortNext: false,
    quotaNext: false,
    throwValue: null,
    rejectLocks: false,
    dropOptions: false,
    plainThrowValue: null,
    abortThrows: false,
    openThrows: false,
    storeNamesThrow: false,
    hideDurability: false,
    cursorKeyThrows: false,
    room: null,
    estimates: 0,
    estimateFails: null,
    closeThrows: false,
    deleteThrows: false,
    errorThrows: false,
    opened: [],
  };
  globalThis.icarusFaults = faults;
  const request = LockManager.prototype.request;
  LockManager.prototype.request = function (...args) {
    if (faults.rejectLocks) {
      return Promise.reject(new DOMException('locks are denied', 'SecurityError'));
    }
    return request.apply(this, args);
  };
  const transaction = IDBDatabase.prototype.transaction;
  IDBDatabase.prototype.transaction = function (...args) {
    return transaction.apply(this, faults.dropOptions ? args.slice(0, 2) : args);
  };
  const abort = IDBTransaction.prototype.abort;
  IDBTransaction.prototype.abort = function (...args) {
    if (faults.abortThrows) throw new TypeError('abort is broken');
    return abort.apply(this, args);
  };
  const durability = Object.getOwnPropertyDescriptor(IDBTransaction.prototype, 'durability');
  Object.defineProperty(IDBTransaction.prototype, 'durability', {
    configurable: true,
    get() { return faults.hideDurability ? undefined : durability.get.call(this); },
  });
  const storeNames = Object.getOwnPropertyDescriptor(IDBDatabase.prototype, 'objectStoreNames');
  Object.defineProperty(IDBDatabase.prototype, 'objectStoreNames', {
    configurable: true,
    get() {
      if (faults.storeNamesThrow) throw new TypeError('store names are broken');
      return storeNames.get.call(this);
    },
  });
  const cursorKey = Object.getOwnPropertyDescriptor(IDBCursor.prototype, 'key');
  Object.defineProperty(IDBCursor.prototype, 'key', {
    configurable: true,
    get() {
      if (faults.cursorKeyThrows) throw new TypeError('cursor keys are broken');
      return cursorKey.get.call(this);
    },
  });
  const estimate = StorageManager.prototype.estimate;
  StorageManager.prototype.estimate = function (...args) {
    faults.estimates++;
    if (faults.estimateFails === 'reject') return Promise.reject(new DOMException('no estimate', 'UnknownError'));
    if (faults.estimateFails === 'throw') throw new TypeError('estimate is broken');
    if (faults.estimateFails === 'hang') return new Promise(() => {});
    if (faults.room === null) return estimate.apply(this, args);
    return Promise.resolve({ quota: faults.room + 4096, usage: 4096 });
  };
  const close = IDBDatabase.prototype.close;
  IDBDatabase.prototype.close = function (...args) {
    if (faults.closeThrows) throw new TypeError('close is broken');
    return close.apply(this, args);
  };
  const deleteDatabase = IDBFactory.prototype.deleteDatabase;
  IDBFactory.prototype.deleteDatabase = function (...args) {
    if (faults.deleteThrows) throw new TypeError('delete is broken');
    return deleteDatabase.apply(this, args);
  };
  const transactionError = Object.getOwnPropertyDescriptor(IDBTransaction.prototype, 'error');
  Object.defineProperty(IDBTransaction.prototype, 'error', {
    configurable: true,
    get() {
      if (faults.errorThrows) throw new TypeError('the error is broken');
      return transactionError.get.call(this);
    },
  });
  faults.putRaw = (name, area, key, kind) => new Promise((resolve) => {
    const opening = indexedDB.open(name);
    opening.onsuccess = () => {
      const db = opening.result;
      const transaction = db.transaction('rows', 'readwrite');
      const value = { null: null, undefined: undefined, number: 5 }[kind];
      transaction.objectStore('rows').put(value, [area, key]);
      transaction.oncomplete = () => { db.close(); resolve(); };
    };
  });
  const open = IDBFactory.prototype.open;
  IDBFactory.prototype.open = function (...args) {
    if (faults.openThrows) throw new TypeError('open is broken');
    const opening = open.apply(this, args);
    opening.addEventListener('success', () => faults.opened.push(opening.result));
    return opening;
  };
  const wrap = (name) => {
    const original = IDBObjectStore.prototype[name];
    IDBObjectStore.prototype[name] = function (...args) {
      if (name === 'put' && faults.throwValue !== null && args[0] === faults.throwValue) {
        throw new DOMException('the value cannot be cloned', 'DataCloneError');
      }
      if (name === 'put' && faults.plainThrowValue !== null && args[0] === faults.plainThrowValue) {
        throw new TypeError('the value is broken');
      }
      const request = original.apply(this, args);
      if (faults.abortNext || faults.quotaNext) {
        const quota = faults.quotaNext;
        faults.abortNext = false;
        faults.quotaNext = false;
        const transaction = this.transaction;
        request.addEventListener('success', () => {
          if (quota) {
            Object.defineProperty(transaction, 'error', {
              value: new DOMException('the quota was exceeded', 'QuotaExceededError'),
            });
          }
          transaction.abort();
        });
      }
      return request;
    };
  };
  wrap('put');
  wrap('delete');
})();
''';

JSObject get _faults {
  globalContext.callMethod('eval'.toJS, _patch.toJS);
  return globalContext['icarusFaults']! as JSObject;
}

void abortNextAfterItsFirstRequest() => _faults['abortNext'] = true.toJS;

void exceedQuotaNext() => _faults['quotaNext'] = true.toJS;

void throwOnPutOf(String? value) => _faults['throwValue'] = value?.toJS;

void throwPlainlyOnPutOf(String? value) =>
    _faults['plainThrowValue'] = value?.toJS;

void abortThrows(bool throws) => _faults['abortThrows'] = throws.toJS;

void openThrows(bool throws) => _faults['openThrows'] = throws.toJS;

void storeNamesThrow(bool throws) => _faults['storeNamesThrow'] = throws.toJS;

void hideDurability(bool hide) => _faults['hideDurability'] = hide.toJS;

void cursorKeysThrow(bool throws) => _faults['cursorKeyThrows'] = throws.toJS;

void pretendRoomLeft(int? bytes) => _faults['room'] = bytes?.toJS;

int get estimatesAsked => (_faults['estimates']! as JSNumber).toDartInt;

Future<bool> databaseExists(String name) async {
  final listed = await window.indexedDB.databases().toDart;
  return listed.toDart.any((info) => info.name == name);
}

Future<bool> lockIsFree(String name) async {
  final state = await window.navigator.locks.query().toDart;
  return !state.held.toDart.any((lock) => lock.name == name);
}

Future<void> putRaw(String name, String area, String key, String kind) =>
    (_faults.callMethod<JSPromise<JSAny?>>(
      'putRaw'.toJS,
      name.toJS,
      area.toJS,
      key.toJS,
      kind.toJS,
    )).toDart;

void estimateFails(String? how) => _faults['estimateFails'] = how?.toJS;

void closeThrows(bool throws) => _faults['closeThrows'] = throws.toJS;

void deleteThrows(bool throws) => _faults['deleteThrows'] = throws.toJS;

void transactionErrorThrows(bool throws) =>
    _faults['errorThrows'] = throws.toJS;

Future<IDBDatabase> openRaw(String name) {
  final opened = Completer<IDBDatabase>();
  final opening = window.indexedDB.open(name);
  opening.onsuccess = ((Event _) => opened.complete(
    opening.result! as IDBDatabase,
  )).toJS;
  return opened.future;
}

void rejectLockRequests(bool reject) => _faults['rejectLocks'] = reject.toJS;

void dropTransactionOptions(bool drop) => _faults['dropOptions'] = drop.toJS;

void forceCloseOpenedDatabases() {
  for (final db in (_faults['opened']! as JSArray<IDBDatabase>).toDart) {
    db.dispatchEvent(Event('close'));
  }
  _faults['opened'] = JSArray<IDBDatabase>();
}

Future<bool> upgradeFinishes(String name, int version) {
  final finished = Completer<bool>();
  final opening = window.indexedDB.open(name, version);
  opening
    ..onsuccess = ((Event _) {
      (opening.result! as IDBDatabase).close();
      finished.complete(true);
    }).toJS
    ..onerror = ((Event _) => finished.complete(false)).toJS;
  return finished.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => false,
  );
}

Future<void> deleteDatabase(String name) {
  final deleted = Completer<void>();
  final request = window.indexedDB.deleteDatabase(name);
  request
    ..onsuccess = ((Event _) => deleted.complete()).toJS
    ..onerror = ((Event _) => deleted.completeError('not deleted')).toJS;
  return deleted.future;
}

Future<IndexedDbLease> openIndexedDb(String name) async =>
    switch (await IndexedDbEngine(name).lease()) {
      Leased(:final lease) => lease as IndexedDbLease,
      final other => throw StateError('$other'),
    };

const _secondContext = '''
onmessage = async ({ data: { name, area } }) => {
  let refusals = 0;
  for (;;) {
    const read = await navigator.locks.request(name, { ifAvailable: true }, async (lock) => {
      if (!lock) return null;
      const db = await new Promise((resolve, reject) => {
        const opening = indexedDB.open(name);
        opening.onsuccess = () => resolve(opening.result);
        opening.onerror = () => reject(opening.error);
      });
      const rows = db.transaction('rows', 'readonly').objectStore('rows');
      const values = await new Promise((resolve) => {
        const request = rows.getAll(IDBKeyRange.bound([area, ''], [area, []], false, true));
        request.onsuccess = () => resolve(request.result);
      });
      db.close();
      return values;
    });
    if (read) {
      postMessage({ refusals, values: read });
      return;
    }
    refusals++;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};
''';

Future<(int, List<String>)> readFromAnotherContext(String name, String area) {
  final worker = Worker(
    URL
        .createObjectURL(
          Blob(
            [_secondContext.toJS].toJS,
            BlobPropertyBag(type: 'text/javascript'),
          ),
        )
        .toJS,
  );
  final read = Completer<(int, List<String>)>();
  worker
    ..onmessage = ((MessageEvent event) {
      final data = event.data! as JSObject;
      read.complete((
        (data['refusals']! as JSNumber).toDartInt,
        [
          for (final value in (data['values']! as JSArray<JSString>).toDart)
            value.toDart,
        ],
      ));
      worker.terminate();
    }).toJS
    ..postMessage({'name': name, 'area': area}.jsify());
  return read.future;
}

var _databases = 0;

final class IndexedDbCrashHarness implements CrashHarness {
  late String _name;
  final _engines = <IndexedDbEngine>[];
  int _steps = 0;
  int? _crashAt;
  int _armedFrom = 0;
  bool _crashed = false;

  @override
  String get name =>
      'IndexedDB in this browser, aborting a transaction after its first '
      'request succeeded and stopping there';

  @override
  Future<void> start(Contents seed) async {
    await _closeOpen();
    _name = 'icarus-crash-${_databases++}';
    await deleteDatabase(_name);
    final lease = await openIndexedDb(_name);
    for (final MapEntry(key: area, value: values) in seed.entries) {
      if (await put(lease, area, values)
          case CommitRefused(:final failure) || CommitUnknown(:final failure)) {
        throw StateError('seed not written: $failure');
      }
    }
    await lease.release();
    _crashed = false;
    _crashAt = null;
  }

  Future<void> _closeOpen() async {
    for (final engine in _engines) {
      await engine.close();
    }
    _engines.clear();
  }

  @override
  Future<StorageEngine> open() async {
    final engine = IndexedDbEngine(_name);
    _engines.add(engine);
    return WrappingEngine(engine, (lease) => _AbortingLease(this, lease));
  }

  bool _step() {
    if (_crashed) return false;
    _steps++;
    if (_crashAt case final at? when _steps >= at) {
      _crashed = true;
      abortNextAfterItsFirstRequest();
    }
    return true;
  }

  @override
  void arm(int step) {
    _armedFrom = _steps;
    _crashAt = _steps + step;
  }

  @override
  void disarm() {
    _armedFrom = _steps;
    _crashAt = null;
  }

  @override
  int get stepsSinceArmed => _steps - _armedFrom;

  @override
  bool get crashed => _crashed;

  @override
  Future<void> crash() async {
    _crashed = true;
    await _closeOpen();
    _crashed = false;
    _crashAt = null;
  }

  @override
  Future<void> finish() async {
    await _closeOpen();
    await deleteDatabase(_name);
  }
}

final class _AbortingLease extends ForwardingLease {
  _AbortingLease(this._harness, super.inner);

  final IndexedDbCrashHarness _harness;

  static const _stopped = StorageFailed<Never>(
    DeviceFailure('the tab stopped'),
  );

  @override
  Future<KeyRead> read(String area, String key) async => _harness._crashed
      ? const KeyNotRead(DeviceFailure('the tab stopped'))
      : await inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      _harness._crashed ? _stopped : await inner.keys(area, prefix);

  @override
  Future<Committing> commit(List<Change> changes) async {
    if (_harness._crashed) {
      return const CommitRefused(DeviceFailure('the tab stopped'));
    }
    final crashing = !_harness._step() || _harness._crashed;
    final result = await inner.commit(changes);
    return switch (result) {
      CommitApplied() when crashing => throw StateError(
        'the transaction was not aborted',
      ),
      _ => result,
    };
  }
}

final class IndexedDbContractHarness implements EngineHarness {
  IndexedDbContractHarness(this.name);

  final String name;

  @override
  Future<StorageEngine> open() async => IndexedDbEngine(name);

  @override
  Future<void> close(StorageEngine engine) =>
      (engine as IndexedDbEngine).close();

  @override
  Future<void> crash(StorageEngine engine) =>
      (engine as IndexedDbEngine).close();

  @override
  PendingWrite holdNextWrite(StorageEngine engine) =>
      (engine as IndexedDbEngine).holdNextCommit();
}

Future<void> _writeBehindTheLease(String name, List<Change> changes) {
  final written = Completer<void>();
  final opening = window.indexedDB.open(name);
  opening.onsuccess = ((Event _) {
    final db = opening.result! as IDBDatabase;
    final transaction = db.transaction('rows'.toJS, 'readwrite');
    final rows = transaction.objectStore('rows');
    for (final change in changes) {
      if (change case Put(:final area, :final key, :final value)) {
        rows.put(value.toJS, [area.toJS, key.toJS].toJS);
      }
    }
    transaction.oncomplete = ((Event _) {
      db.close();
      written.complete();
    }).toJS;
  }).toJS;
  return written.future;
}

final class _StaleWriterLease extends ForwardingLease {
  _StaleWriterLease(this._engine, super.inner);

  final StaleWriterEngine _engine;

  @override
  Future<Committing> commit(List<Change> changes) async {
    if (_engine._hold case final hold?) {
      _engine._hold = null;
      hold._reached.complete();
      await hold._letGo.future;
      await _writeBehindTheLease(_engine.inner.name, changes);
      return const CommitApplied();
    }
    return inner.commit(changes);
  }
}

final class StaleWriterEngine implements StorageEngine {
  StaleWriterEngine(this.inner);

  final IndexedDbEngine inner;
  _HeldCommit? _hold;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
    Leased(:final lease) => Leased(_StaleWriterLease(this, lease)),
    final other => other,
  };
}

final class StaleWriterHarness extends IndexedDbContractHarness {
  StaleWriterHarness(super.name);

  @override
  Future<StorageEngine> open() async =>
      StaleWriterEngine(IndexedDbEngine(name));

  @override
  Future<void> close(StorageEngine engine) =>
      (engine as StaleWriterEngine).inner.close();

  @override
  Future<void> crash(StorageEngine engine) =>
      (engine as StaleWriterEngine).inner.close();

  @override
  PendingWrite holdNextWrite(StorageEngine engine) =>
      (engine as StaleWriterEngine)._hold = _HeldCommit();
}

final class _HeldCommit implements PendingWrite {
  final _reached = Completer<void>();
  final _letGo = Completer<void>();

  @override
  Future<void> get reached => _reached.future;

  @override
  void letGo() => _letGo.complete();
}
