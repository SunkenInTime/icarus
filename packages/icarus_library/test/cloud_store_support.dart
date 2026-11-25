import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/op_facts.dart' show revisionOfRow;
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

Future<LibraryStore> openCloudStore(
  StorageEngine engine, {
  String build = build,
  DateTime Function() clock = fixedClock,
  CloudResults results = CloudResults.thisDevicesReads,
}) async => switch (await LibraryStore.open(
  engine,
  canRead: readsKnownKinds,
  clock: clock,
  build: build,
)) {
  StoreOpened(:final store) => store..takeCloudResultsFrom(results),
  StoreNotOpened(:final problem) => fail('store did not open: $problem'),
};

List<PageRead> pageReadsOf(StrategyRowSet rows) => [
  for (final page in rows.pages) pageReadOf(rows, page.publicId) as PageRead,
];

Future<void> addCloud(LibraryStore store, StrategyRowSet rows) async =>
    savedValue(
      await store.addCloudStrategy(
        testAccount,
        headerReadOf(rows),
        pageReadsOf(rows),
      ),
    );

CloudStrategy cloudOf(StrategySync sync) => switch (sync) {
  final CloudStrategy cloud => cloud,
  LocalStrategy() || CloudHeld() => fail('expected a cloud strategy'),
};

Future<CloudStrategy> syncOf(LibraryStore store) async =>
    cloudOf(strategyOf(await store.readStrategy(strategyId)).sync);

Future<Recorded> recordAll(LibraryStore store, List<QueueEvent> events) async =>
    savedValue(await store.record(testAccount, strategyId, events));

List<QueueEffect> effectsOf(Recorded recorded) => [
  for (final outcome in recorded.outcomes)
    if (outcome case ReportApplied(:final effects)) ...effects,
];

Future<int> sessionOf(LibraryStore store) async =>
    (await syncOf(store)).queue.session.number;

Future<ResultSource> readStartOf(LibraryStore store) async =>
    readFrom((await syncOf(store)).queue);

Future<void> readServer(
  LibraryStore store,
  StrategyRowSet server, {
  Iterable<String>? pages,
}) async {
  final session = await sessionOf(store);
  await recordAll(store, [
    BaseArrived(
      headerReadOf(server),
      session: session,
      from: await readStartOf(store),
    ),
  ]);
  for (final page in pages ?? server.pages.map((page) => page.publicId)) {
    await recordAll(store, [
      BaseArrived(
        pageReadOf(server, page),
        session: session,
        from: await readStartOf(store),
      ),
    ]);
  }
}

Future<SendBatch> claimAll(
  LibraryStore store, {
  String client = clientId,
}) async {
  final views = (await syncOf(store)).views;
  final queue = (await syncOf(store)).queue;
  final ids = [
    for (final entry in queue.entries)
      if (views[entry.id]?.sendable ?? false) entry.id,
  ];
  return effectsOf(
    await recordAll(store, [
      BatchClaimed(clientId: client, opIds: ids, at: fixedClock()),
    ]),
  ).whereType<SendBatch>().single;
}

Future<StrategyRead> seenIn(
  LibraryStore store, [
  String id = strategyId,
]) async => switch (await store.readStrategy(id)) {
  Found(:final value) => value,
  final other => fail('$id could not be read: $other'),
};

typedef Held = ({String page, int? revision, int? life, String digest});

Held heldOf(Row row, String page) => (
  page: page,
  revision: revisionOfRow(row),
  life: createdAtOf(row),
  digest: rowDigest(row),
);

Held shownOf(ShownRow row) => (
  page: row.page,
  revision: row.revision,
  life: row.life,
  digest: row.digest,
);

Future<void> expectAgree(LibraryStore store) async {
  final shown = (await syncOf(store)).queue.shown;
  final content = switch (await store.readStrategy(strategyId)) {
    Found(value: final StrategyContent value) => value,
    final other => fail('the strategy did not read: $other'),
  };
  expect(
    (
      revision: revisionOfRow(content.strategy),
      life: createdAtOf(content.strategy),
    ),
    (revision: shown.strategy?.revision, life: shown.strategy?.life),
    reason: 'the strategy row',
  );
  expect(
    {
      for (final page in content.pages)
        page.publicId: (heldOf(page, page.publicId), page is TrashedPage),
    },
    {
      for (final MapEntry(:key, :value) in shown.pages.entries)
        key: (shownOf(value), false),
      for (final MapEntry(:key, :value) in shown.trashed.entries)
        key: (shownOf(value), true),
    },
    reason: 'page rows',
  );
  expect(
    {
      for (final MapEntry(:key, :value) in content.settings.entries)
        key: heldOf(value, key),
    },
    {
      for (final MapEntry(:key, :value) in shown.settings.entries)
        key: shownOf(value),
    },
    reason: 'settings rows',
  );
  final items = <Target, Held>{};
  for (final page in content.pages) {
    switch (await store.readPage(strategyId, page.publicId)) {
      case Found(:final value):
        for (final row in value.elements) {
          items[ElementTarget(row.publicId)] = heldOf(row, page.publicId);
        }
        for (final row in value.lineupGroups) {
          items[LineupTarget(row.publicId)] = heldOf(row, page.publicId);
        }
      case NotFound():
        break;
      case final other:
        fail('page ${page.publicId} did not read: $other');
    }
  }
  expect(items, {
    for (final MapEntry(:key, :value) in shown.rows.entries)
      key: shownOf(value),
  }, reason: 'items');
}

Future<ResultSource> beganIn(LibraryStore store) async {
  final recorded = await recordAll(store, [const ReadBegun()]);
  return effectsOf(recorded).whereType<ReadStartIssued>().single.source;
}
