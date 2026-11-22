import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

Future<LibraryStore> openCloudStore(
  StorageEngine engine, {
  String build = build,
  DateTime Function() clock = fixedClock,
}) async => switch (await LibraryStore.open(
  engine,
  canRead: readsKnownKinds,
  clock: clock,
  build: build,
)) {
  StoreOpened(:final store) => store,
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

Future<void> readServer(
  LibraryStore store,
  StrategyRowSet server, {
  Iterable<String>? pages,
}) async {
  final session = await sessionOf(store);
  await recordAll(store, [BaseArrived(headerReadOf(server), session: session)]);
  for (final page in pages ?? server.pages.map((page) => page.publicId)) {
    await recordAll(store, [
      BaseArrived(pageReadOf(server, page), session: session),
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
