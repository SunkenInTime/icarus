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

Future<IDBDatabase> _openRaw(String name) {
  final opened = Completer<IDBDatabase>();
  final request = window.indexedDB.open(name);
  request.onsuccess = ((Event _) => opened.complete(
    request.result! as IDBDatabase,
  )).toJS;
  return opened.future;
}

IDBKeyRange _all(String prefix) => IDBKeyRange.bound(
  [prefix.toJS].toJS,
  [
    String.fromCharCodes([
      ...prefix.codeUnits.take(prefix.length - 1),
      prefix.codeUnits.last + 1,
    ]).toJS,
  ].toJS,
  false,
  true,
);

Future<List<String>> _byCursor(IDBDatabase db, String prefix) {
  final found = <String>[];
  final listed = Completer<List<String>>();
  final request = db
      .transaction('rows'.toJS, 'readonly')
      .objectStore('rows')
      .openKeyCursor(_all(prefix));
  request.onsuccess = ((Event _) {
    final cursor = request.result as IDBCursor?;
    if (cursor == null) {
      listed.complete(found);
      return;
    }
    final area = (cursor.key! as JSArray<JSString>).toDart[0].toDart;
    found.add(area);
    cursor.continue_([area.toJS, JSArray<JSAny>()].toJS);
  }).toJS;
  return listed.future;
}

Future<List<String>> _byAllKeys(IDBDatabase db, String prefix) {
  final listed = Completer<List<String>>();
  final request = db
      .transaction('rows'.toJS, 'readonly')
      .objectStore('rows')
      .getAllKeys(_all(prefix));
  request.onsuccess = ((Event _) {
    final found = <String>[];
    for (final key in (request.result! as JSArray<JSArray<JSString>>).toDart) {
      final area = key.toDart[0].toDart;
      if (found.isEmpty || found.last != area) found.add(area);
    }
    listed.complete(found);
  }).toJS;
  return listed.future;
}

Future<void> _fixture(String name, List<(String, int)> areas) async {
  await _deleteDatabase(name);
  final engine = IndexedDbEngine(name);
  final lease = switch (await engine.lease()) {
    Leased(:final lease) => lease,
    final other => throw StateError('$other'),
  };
  for (final (area, rows) in areas) {
    final applied = await lease.commit([
      for (var row = 0; row < rows; row++)
        Put(area, 'content/p/e/${row.toString().padLeft(5, '0')}', 'v'),
    ]);
    if (applied is! CommitApplied) throw StateError('$applied');
  }
  await engine.close();
}

Future<void> _compare(String label, List<(String, int)> areas) async {
  final name = 'icarus-areas-cost';
  await _fixture(name, areas);
  final db = await _openRaw(name);
  final cursor = Times('$label: cursor that skips past each area');
  final allKeys = Times('$label: getAllKeys over the range, distinct in Dart');
  for (var run = 0; run < 15; run++) {
    final a = await cursor.time(() => _byCursor(db, 's/'));
    final b = await allKeys.time(() => _byAllKeys(db, 's/'));
    if (a.length != areas.length || b.length != areas.length) {
      throw StateError('counts ${a.length} ${b.length}');
    }
  }
  db.close();
  await _deleteDatabase(name);
  _say('  ${cursor.summary}');
  _say('  ${allKeys.summary}');
}

String _area(int i) => 's/${i.toString().padLeft(40, '0')}';

Future<void> main() async {
  _say('areas on IndexedDB, ${window.navigator.userAgent}');
  await _compare('700 areas, one of 6000 rows, the rest of 10', [
    (_area(0), 6000),
    for (var i = 1; i < 700; i++) (_area(i), 10),
  ]);
  await _compare('700 areas of 20 rows', [
    for (var i = 0; i < 700; i++) (_area(i), 20),
  ]);
  _say('done');
}
