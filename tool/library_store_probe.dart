import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

const _usesMemory = bool.fromEnvironment('ICARUS_PROBE_MEMORY_ENGINE');

final _memory = MemoryStorage();

StorageEngine _engine(String path) =>
    _usesMemory ? MemoryEngine(_memory) : SqliteEngine(path);

Future<void> _close(StorageEngine engine) => switch (engine) {
      final SqliteEngine sqlite => sqlite.close(),
      final MemoryEngine memory => memory.close(),
      _ => throw StateError('unknown engine $engine'),
    };

bool _readsAll(ElementPayload payload) => true;

ElementPayload _agent(double x) => ElementPayload(
      kind: ElementKind.agent,
      payloadVersion: 1,
      data: {
        'id': 'probe-jett',
        'elementType': 'agent',
        'type': 'jett',
        'position': {'dx': x, 'dy': 20.0},
        'isAlly': true,
      },
    );

StrategyRowSet _strategy() => StrategyRowSet(
      strategy: ReadableStrategy(
        publicId: 'probe',
        name: 'Store probe',
        mapData: 'ascent',
        revision: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
      pages: [
        LivePage(
          publicId: 'probe-page',
          strategyPublicId: 'probe',
          name: 'Page 1',
          sortIndex: 0,
          isAttack: true,
          revision: 1,
        ),
      ],
      elements: [
        LiveElement(
          publicId: 'probe-jett',
          pagePublicId: 'probe-page',
          payload: _agent(10),
          sortIndex: 0,
          revision: 1,
        ),
      ],
    );

Future<LibraryStore> _open(StorageEngine engine) async =>
    switch (await LibraryStore.open(engine, canRead: _readsAll)) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };

LibraryList _list(LibraryStore store) => switch (store.library) {
      LibraryOpen(:final list) => list,
      LibraryShut(:final failure) =>
        throw StateError('the library is shut: $failure'),
    };

Future<String> _probe(String path) async {
  final first = _engine(path);
  final store = await _open(first);
  if (_list(store).strategies.isEmpty) {
    if (await store.editLibrary([AddStrategy(_strategy())]) is! Saved) {
      throw StateError('the strategy was not saved');
    }
  }
  final page = switch (await store.readPage('probe', 'probe-page')) {
    Found(:final value) => value,
    final other => throw StateError('$other'),
  };
  final jett = page.elements.whereType<LiveElement>().single;
  final moved = await store.commit(
    'probe',
    ElementPatchOp(
      opId: 'probe-move-${DateTime.now().microsecondsSinceEpoch}',
      elementPublicId: 'probe-jett',
      expectedElementRevision: jett.revision,
      payload: _agent(jett.revision * 10.0 + 10),
    ),
  );
  if (moved is! Saved) throw StateError('the move was not saved: $moved');
  await store.close();
  await _close(first);

  final second = _engine(path);
  final reopened = await _open(second);
  final read = switch (await reopened.readPage('probe', 'probe-page')) {
    Found(:final value) => value.elements.whereType<LiveElement>().single,
    final other => throw StateError('$other'),
  };
  final listed = _list(reopened).strategies.length;
  await reopened.close();
  await _close(second);
  final position = read.payload.data['position'];
  return 'store opened on ${_usesMemory ? 'memory' : 'SQLite'} at $path: '
      '$listed strategy, '
      'revision ${read.revision}, position $position';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final folder = Platform.environment['ICARUS_STORE_PROBE_DIR'] ??
      Directory.systemTemp.createTempSync('icarus-store-probe-').path;
  final report = File('$folder/probe.txt');
  final String outcome;
  try {
    outcome = await _probe('$folder/library.sqlite');
  } on StateError catch (error) {
    report.writeAsStringSync('failed: ${error.message}\n');
    exit(1);
  }
  report.writeAsStringSync('$outcome\n');
  stdout.writeln(outcome);
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF101014),
        child: Center(
          child: Text(
            outcome,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 20),
          ),
        ),
      ),
    ),
  );
  if (Platform.environment['ICARUS_STORE_PROBE_STAY'] == null) {
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(0);
  }
}
