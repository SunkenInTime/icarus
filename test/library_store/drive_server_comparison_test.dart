import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart' show RemotePageSnapshot;
import 'package:icarus/dev/drive/drive_cloud_store.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus_library/icarus_library.dart';

import 'server_fixtures.dart'
    show
        openStore,
        pageList,
        pageSnapshot,
        secondPage,
        serverRows,
        servedAccount;

const point = ResultPoint(client: 1, connection: 1, snapshot: 1);

Future<LibraryStore> storeHolding(StrategyRowSet rows) async {
  final store = await openStore(MemoryStorage());
  final header = switch (pageListRead(pageList(rows))) {
    RowsRead(:final value) => value,
    RowsUnreadable(:final problem) => throw StateError(problem),
  };
  final page = switch (pageRead(pageSnapshot(rows), appCanRead)) {
    RowsRead(:final value) => value,
    RowsUnreadable(:final problem) => throw StateError(problem),
  };
  final added = await store.addCloudStrategy(
    servedAccount,
    StampedRead(header, point),
    [StampedRead(page, point)],
  );
  expect(added, isA<Saved<StrategySummary, LibraryRefusal>>());
  return store;
}

ServerReads serving(StrategyRowSet rows) => (
      pageList: (_) async => pageList(rows),
      page: (_, __) async => pageSnapshot(rows),
    );

Future<List<CloudStoreLine>> readBack(
  LibraryStore store,
  ServerReads server,
) async =>
    comparisonLines(
      when: 'after reopening the store',
      readAs: servedAccount.subject,
      held: await compareStoreWithServer(
        store,
        signedIn: servedAccount,
        server: server,
      ),
      expected: [(id: serverRows().strategy.publicId, name: 'Hand')],
      lagging: const [],
    );

List<String> problems(List<CloudStoreLine> lines) => [
      for (final line in lines)
        if (line.problem) line.text,
    ];

void main() {
  test('a store holding what the server holds reads back equal', () async {
    final rows = serverRows();
    final store = await storeHolding(rows);
    final lines = await readBack(store, serving(rows));
    expect(problems(lines), isEmpty);
    expect(
      [for (final line in lines) line.text],
      [contains('equal to the server\'s copy read as account-a, 1 pages')],
    );
    await store.close();
  });

  test(
      'a store behind the server on an item reads back with that item as a '
      'difference', () async {
    final store = await storeHolding(serverRows());
    final moved = serverRows(agentAt: const Offset(300, 400));
    final lines = await readBack(store, serving(moved));
    expect(problems(lines), [matches(RegExp(r'^CLOUDSTORE .*: item \S+: '))]);
    await store.close();
  });

  test(
      'a page the store never held is left out and named; a held page that '
      'differs still fails', () async {
    final second = secondPage();
    final rows = serverRows();
    final store = await openStore(MemoryStorage());
    final header = switch (pageListRead(pageList(rows, more: [second]))) {
      RowsRead(:final value) => value,
      RowsUnreadable(:final problem) => throw StateError(problem),
    };
    final page = switch (pageRead(pageSnapshot(rows), appCanRead)) {
      RowsRead(:final value) => value,
      RowsUnreadable(:final problem) => throw StateError(problem),
    };
    await store.addCloudStrategy(
      servedAccount,
      StampedRead(header, point),
      [StampedRead(page, point)],
    );
    final moved = serverRows(agentAt: const Offset(300, 400));
    final lines = await readBack(
      store,
      (
        pageList: (_) async => pageList(moved, more: [second]),
        page: (_, pageId) async => pageId == second.page.publicId
            ? RemotePageSnapshot(
                page: second.page,
                content: second.content,
                elements: const [],
                lineups: const [],
                assetsById: const {},
              )
            : pageSnapshot(moved),
      ),
    );
    expect(problems(lines), [matches(RegExp(r'^CLOUDSTORE .*: item \S+: '))]);
    expect(
      [for (final line in lines) line.text],
      contains(endsWith('1 pages never shown or needed, not compared: p2')),
    );
    await store.close();
  });

  test('a server read that fails is a verdict, not a thrown error', () async {
    final store = await storeHolding(serverRows());
    final lines = await readBack(
      store,
      (
        pageList: (_) async => throw StateError('the network is down'),
        page: (_, __) async => throw StateError('never asked'),
      ),
    );
    expect(
      problems(lines),
      [contains('could not read the server\'s copy: Bad state: the network')],
    );
    await store.close();
  });
}
