import 'dart:async';
import 'dart:js_interop';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/indexed_db_storage.dart';
import 'package:web/web.dart';

import 'engine_costs/costs.dart';

void _say(String line) => console.log('icarus: $line'.toJS);

Future<void> _deleteDatabase(String name) {
  final deleted = Completer<void>();
  window.indexedDB.deleteDatabase(name)
    ..onsuccess = ((Event _) => deleted.complete()).toJS
    ..onerror = ((Event _) => deleted.complete()).toJS;
  return deleted.future;
}

Future<String> _lastCommitRecord(String name) {
  final read = Completer<String>();
  final opening = window.indexedDB.open(name);
  opening.onsuccess = ((Event _) {
    final db = opening.result! as IDBDatabase;
    if (!db.objectStoreNames.contains('last')) {
      db.close();
      read.complete(
        'no record of the last commit (one transaction per commit)',
      );
      return;
    }
    final request = db
        .transaction('last'.toJS)
        .objectStore('last')
        .get('commit'.toJS);
    request.onsuccess = ((Event _) {
      final record = request.result as JSString?;
      db.close();
      read.complete(
        'record of the last commit, after saving the one-page strategy: '
        '${record?.toDart.length ?? 0} characters',
      );
    }).toJS;
  }).toJS;
  return read.future;
}

Future<String> _leasing(String name, String last) async {
  final times = Times('take the lease, the last commit $last');
  for (var run = 0; run < 15; run++) {
    final engine = IndexedDbEngine(name);
    final leasing = await times.time(engine.lease);
    if (leasing is! Leased) throw StateError('$leasing');
    await engine.close();
  }
  return times.summary;
}

Future<void> main() async {
  final storage = MemoryStorage();
  _say('memory engine');
  for (final line in await measure(
    () => MemoryEngine(storage),
    (engine) => (engine as MemoryEngine).close(),
  )) {
    _say('  $line');
  }
  const name = 'icarus-engine-costs';
  await _deleteDatabase(name);
  _say('IndexedDB engine, ${window.navigator.userAgent}');
  for (final line in await measure(
    () => IndexedDbEngine(name),
    (engine) => (engine as IndexedDbEngine).close(),
  )) {
    _say('  $line');
  }
  final engine = IndexedDbEngine(name);
  await saveOnePageStrategy(engine);
  await engine.close();
  _say('  ${await _lastCommitRecord(name)}');
  _say('  ${await _leasing(name, 'the one-page strategy of 300 items')}');
  final small = IndexedDbEngine(name);
  switch (await small.lease()) {
    case Leased(:final lease):
      await lease.commit(const [Put('library', 'note', 'one row')]);
    case final other:
      throw StateError('$other');
  }
  await small.close();
  _say('  ${await _leasing(name, 'one row')}');
  await _deleteDatabase(name);
  _say('done');
}
