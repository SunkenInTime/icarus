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

  Future<LibraryStore> storeHoldingTheFirstOfTwoPages(
    MemoryStorage storage,
  ) async {
    final rows = serverRows();
    final store = await openStore(storage);
    final header = switch (pageListRead(pageList(rows, more: [secondPage()]))) {
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
    return store;
  }

  ({ServerReads reads, List<String> pagesRead}) servingTwoPages(
    StrategyRowSet rows,
  ) {
    final second = secondPage();
    final pagesRead = <String>[];
    return (
      pagesRead: pagesRead,
      reads: (
        pageList: (_) async => pageList(rows, more: [second]),
        page: (_, pageId) async {
          pagesRead.add(pageId);
          return pageId == second.page.publicId
              ? RemotePageSnapshot(
                  page: second.page,
                  content: second.content,
                  elements: const [],
                  lineups: const [],
                  assetsById: const {},
                )
              : pageSnapshot(rows);
        },
      ),
    );
  }

  List<String> textOf(List<CloudStoreLine> lines) =>
      [for (final line in lines) line.text];

  test(
      'a page the store never held is left out, named, and not read from the '
      'server; a held page that differs still fails', () async {
    final store = await storeHoldingTheFirstOfTwoPages(MemoryStorage());
    final server = servingTwoPages(serverRows(agentAt: const Offset(300, 400)));
    final lines = await readBack(store, server.reads);
    expect(problems(lines), [matches(RegExp(r'^CLOUDSTORE .*: item \S+: '))]);
    expect(
      textOf(lines),
      contains(endsWith('1 pages the store never held, not compared: p2')),
    );
    expect(server.pagesRead, isNot(contains('p2')));
    await store.close();
  });

  test(
      'with a page left out, an equal comparison says only the pages '
      'compared are equal, and how many', () async {
    final store = await storeHoldingTheFirstOfTwoPages(MemoryStorage());
    final lines = await readBack(store, servingTwoPages(serverRows()).reads);
    expect(problems(lines), isEmpty);
    expect(textOf(lines), [
      endsWith('1 pages the store never held, not compared: p2'),
      endsWith('the 1 pages compared equal to the server\'s copy read as '
          'account-a, 1 of 2 pages not compared'),
    ]);
    expect(textOf(lines), isNot(contains(contains(', 2 pages'))));
    await store.close();
  });

  test(
      'a strategy held in the queue is never left partly compared or called '
      'equal: with pages the store gives no content for, it is not compared',
      () async {
    final storage = MemoryStorage();
    await (await storeHoldingTheFirstOfTwoPages(storage)).close();
    final contents = {
      for (final MapEntry(:key, :value) in storage.contents.entries)
        key: {...value},
    };
    contents[strategyArea(serverRows().strategy.publicId)]![
        'pending/${'7'.padLeft(16, '0')}'] = '{"version":99}';
    final store = await openStore(MemoryStorage(contents));
    expect(
      switch (await store.readStrategy(serverRows().strategy.publicId)) {
        Found(:final value) => value.sync,
        _ => null,
      },
      isA<CloudHeld>(),
    );
    final server = servingTwoPages(serverRows());
    final lines = await readBack(store, server.reads);
    expect(problems(lines), [
      allOf(
        contains('got no verdict'),
        contains('held in the queue, and the store gives no content for '
            'p1, p2'),
      ),
    ]);
    expect(textOf(lines), isNot(contains(contains('equal'))));
    expect(server.pagesRead, isEmpty);
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
