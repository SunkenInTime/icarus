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
  const faults = { abortNext: false, quotaNext: false };
  globalThis.icarusFaults = faults;
  const wrap = (name) => {
    const original = IDBObjectStore.prototype[name];
    IDBObjectStore.prototype[name] = function (...args) {
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
      if (await lease.write(area, values) case StorageFailed(:final failure)) {
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
  Future<Stored<String?>> read(String area, String key) async =>
      _harness._crashed ? _stopped : await inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      _harness._crashed ? _stopped : await inner.keys(area, prefix);

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) async {
    if (_harness._crashed) return _stopped;
    final crashing = !_harness._step() || _harness._crashed;
    final result = await inner.write(area, values);
    return crashing ? _expectAborted(result) : result;
  }

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) async {
    if (_harness._crashed) return _stopped;
    final crashing = !_harness._step() || _harness._crashed;
    final result = await inner.delete(area, keys);
    return crashing ? _expectAborted(result) : result;
  }

  Stored<void> _expectAborted(Stored<void> result) => switch (result) {
    StorageFailed() => result,
    Done() => throw StateError('the transaction was not aborted'),
  };
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
}
