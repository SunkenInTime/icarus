import 'dart:async';
import 'dart:js_interop';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/indexed_db_storage.dart';
import 'package:web/web.dart';

import 'engine_costs/costs.dart';

void _say(String line) => console.log(line.toJS);

Future<void> _deleteDatabase(String name) {
  final deleted = Completer<void>();
  window.indexedDB.deleteDatabase(name)
    ..onsuccess = ((Event _) => deleted.complete()).toJS
    ..onerror = ((Event _) => deleted.complete()).toJS;
  return deleted.future;
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
  await _deleteDatabase(name);
  _say('done');
}
