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
}) async => switch (await LibraryStore.open(
  engine,
  canRead: readsKnownKinds,
  clock: clock,
  build: build,
)) {
  StoreOpened(:final store) => store,
  StoreNotOpened(:final problem) => fail('store did not open: $problem'),
};

Future<String?> refusedFor(LibraryStore store) async =>
    switch (await store.readStrategy(strategyId)) {
      InUnreadableStrategy(
        listing: UnreadableStrategyListing(
          refused: StoredRowsDisagree(:final reason),
        ),
      ) =>
        reason,
      _ => null,
    };

List<PageRead> pageReadsOf(StrategyRowSet rows) => [
  for (final page in rows.pages) pageReadOf(rows, page.publicId) as PageRead,
];

StampedRead<T> stamped<T extends ArrivedBase>(T base) =>
    StampedRead(base, tick());

List<StampedRead<PageRead>> stampedPages(Iterable<PageRead> pages) => [
  for (final page in pages) stamped(page),
];

Future<void> addCloud(LibraryStore store, StrategyRowSet rows) async =>
    savedValue(
      await store.addCloudStrategy(
        testAccount,
        stamped(headerReadOf(rows)),
        stampedPages(pageReadsOf(rows)),
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
  await recordAll(store, [await arrivalIn(store, headerReadOf(server))]);
  for (final page in pages ?? server.pages.map((page) => page.publicId)) {
    await recordAll(store, [await arrivalIn(store, pageReadOf(server, page))]);
  }
}

Future<ReadAsked> askedIn(LibraryStore store) async =>
    askRead((await syncOf(store)).queue);

BaseArrived arrivedAs(
  ArrivedBase base, {
  required int session,
  required ReadAsked asked,
}) => BaseArrived(
  base,
  session: session,
  point: asked.point,
  requestedAt: asked.requestedAt,
);

Future<BaseArrived> arrivalIn(LibraryStore store, ArrivedBase base) async {
  final session = (await syncOf(store)).queue.session;
  return BaseArrived(
    base,
    session: session.number,
    point: tick(),
    requestedAt: session.sequence,
  );
}

Future<ResultRefused> readRefusedIn(
  LibraryStore store,
  String? page,
  String problem,
) async {
  final session = (await syncOf(store)).queue.session;
  return ResultRefused(
    page: page,
    problem: problem,
    session: session.number,
    point: tick(),
    requestedAt: session.sequence,
  );
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

typedef StoredPage = ({
  List<ElementRow> elements,
  List<LineupGroupRow> lineupGroups,
  List<String> damaged,
});

List<String> agreementProblems({
  required StrategyRow strategy,
  required List<PageRow> pages,
  required Map<String, PageSettingsRow> settings,
  required List<String> damaged,
  required Map<String, StoredPage> content,
  required Shown shown,
}) {
  final problems = <String>[];
  final digests = <String, Target>{
    for (final target in shown.rows.keys)
      switch (target) {
        ElementTarget(:final elementPublicId) => digestOf(elementPublicId),
        LineupTarget(:final lineupPublicId) => digestOf(lineupPublicId),
        _ => '',
      }: target,
  };
  for (final name in damaged) {
    problems.add('a damaged row is held here as $name');
  }
  final both = shown.pages.keys.toSet().intersection(
    shown.trashed.keys.toSet(),
  );
  if (both.isNotEmpty) {
    problems.add('the queue holds $both as live and trashed');
  }
  final pageIds = <String>{};
  for (final page in pages) {
    if (!pageIds.add(page.publicId)) {
      problems.add('page ${page.publicId} is held twice here');
    }
  }
  if (shown.strategy case final held?
      when (revisionOfRow(strategy), createdAtOf(strategy)) !=
          (held.revision, held.life)) {
    problems.add('the strategy row is at another version here');
  }
  final storedPages = {
    for (final page in pages)
      page.publicId: (heldOf(page, page.publicId), page is TrashedPage),
  };
  final shownPages = {
    for (final MapEntry(:key, :value) in shown.pages.entries)
      key: (shownOf(value), false),
    for (final MapEntry(:key, :value) in shown.trashed.entries)
      key: (shownOf(value), true),
  };
  for (final page in {...storedPages.keys, ...shownPages.keys}) {
    if (storedPages[page] != shownPages[page]) {
      problems.add(
        'page $page is ${storedPages[page]} here and ${shownPages[page]} in '
        'the queue',
      );
    }
  }
  for (final page in {...settings.keys, ...shown.settings.keys}) {
    final here = switch (settings[page]) {
      final row? => heldOf(row, page),
      null => null,
    };
    final queued = switch (shown.settings[page]) {
      final row? => shownOf(row),
      null => null,
    };
    if (here != queued) {
      problems.add('the settings of $page are $here here and $queued queued');
    }
  }
  final items = <Target, Held>{};
  for (final MapEntry(key: page, value: stored) in content.entries) {
    for (final name in stored.damaged) {
      final owner = digests[name.split('/').last];
      problems.add(
        owner == null
            ? 'a damaged row is held on $page as $name'
            : 'a damaged copy of $owner is held on $page',
      );
    }
    for (final (target, row) in <(Target, Row)>[
      for (final row in stored.elements) (ElementTarget(row.publicId), row),
      for (final row in stored.lineupGroups) (LineupTarget(row.publicId), row),
    ]) {
      if (items[target] case final first?) {
        problems.add('$target is held on ${first.page} and on $page here');
        continue;
      }
      items[target] = heldOf(row, page);
    }
  }
  final shownItems = {
    for (final MapEntry(:key, :value) in shown.rows.entries)
      key: shownOf(value),
  };
  for (final target in {...items.keys, ...shownItems.keys}) {
    final here = items[target];
    final queued = shownItems[target];
    if (here == queued) continue;
    if (here != null && queued != null && here.page != queued.page) {
      problems.add(
        '$target is on ${here.page} here and on ${queued.page} in the queue',
      );
    } else {
      problems.add('$target is $here here and $queued in the queue');
    }
  }
  return problems;
}

Future<void> expectAgree(LibraryStore store) async {
  final strategy = switch (await store.readStrategy(strategyId)) {
    Found(value: final StrategyContent value) => value,
    final other => fail('the strategy did not read: $other'),
  };
  final content = <String, StoredPage>{};
  for (final page in strategy.pages) {
    if (content.containsKey(page.publicId)) continue;
    switch (await store.readPage(strategyId, page.publicId)) {
      case Found(:final value):
        content[page.publicId] = (
          elements: value.elements.toList(),
          lineupGroups: value.lineupGroups.toList(),
          damaged: [for (final row in value.unplaced) row.ref.name],
        );
      case NotFound():
        break;
      case final other:
        fail('page ${page.publicId} did not read: $other');
    }
  }
  final problems = agreementProblems(
    strategy: strategy.strategy,
    pages: strategy.pages,
    settings: strategy.settings,
    damaged: [for (final row in strategy.unplaced) row.ref.name],
    content: content,
    shown: (await syncOf(store)).queue.shown,
  );
  if (problems.isNotEmpty) fail(problems.join('\n'));
}
