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
  final content = switch (await store.readStrategy(strategyId)) {
    Found(value: final StrategyContent value) => value,
    final other => fail('the strategy did not read: $other'),
  };
  final pageReads = <String, PageContent>{};
  for (final page in content.pages) {
    if (pageReads.containsKey(page.publicId)) {
      fail('the store holds page ${page.publicId} twice');
    }
    switch (await store.readPage(strategyId, page.publicId)) {
      case Found(:final value):
        pageReads[page.publicId] = value;
      case NotFound():
        break;
      case final other:
        fail('page ${page.publicId} did not read: $other');
    }
  }
  final shown = (await syncOf(store)).queue.shown;
  final both = shown.pages.keys.toSet().intersection(
    shown.trashed.keys.toSet(),
  );
  if (both.isNotEmpty) fail('the queue holds $both as live and trashed');

  expect(
    (
      revision: revisionOfRow(content.strategy),
      life: createdAtOf(content.strategy),
      here: true,
    ),
    (
      revision: shown.strategy?.revision,
      life: shown.strategy?.life,
      here: shown.strategy?.here,
    ),
    reason: 'the strategy row',
  );

  final unplaced = {for (final row in content.unplaced) row.ref.name};
  void expectHeader(
    String what,
    Map<String, Object> stored,
    Map<String, (ShownRow, Object)> held,
    String Function(String id) name,
  ) {
    expect(stored, {
      for (final MapEntry(:key, value: (row, kind)) in held.entries)
        if (row.here) key: (shownOf(row), kind),
    }, reason: '$what with a readable copy here');
    for (final MapEntry(:key, value: (row, _)) in held.entries) {
      if (row.here) {
        expect(
          unplaced.contains(name(key)),
          isFalse,
          reason: '$what $key is readable to the queue but damaged here',
        );
      }
    }
    for (final damaged in unplaced) {
      final owner = [
        for (final MapEntry(:key, value: (row, _)) in held.entries)
          if (name(key) == damaged) row,
      ].singleOrNull;
      if (owner != null) {
        expect(owner.here, isFalse, reason: '$what damaged as $damaged');
      }
    }
  }

  expectHeader(
    'page rows',
    {
      for (final page in content.pages)
        page.publicId: (heldOf(page, page.publicId), page is TrashedPage),
    },
    {
      for (final MapEntry(:key, :value) in shown.pages.entries)
        key: (value, false),
      for (final MapEntry(:key, :value) in shown.trashed.entries)
        key: (value, true),
    },
    pageName,
  );
  expectHeader(
    'settings rows',
    {
      for (final MapEntry(:key, :value) in content.settings.entries)
        key: (heldOf(value, key), true),
    },
    {
      for (final MapEntry(:key, :value) in shown.settings.entries)
        key: (value, true),
    },
    settingsName,
  );

  final items = <Target, Held>{};
  final damaged = <String, String>{};
  for (final MapEntry(key: page, value: read) in pageReads.entries) {
    for (final (target, row) in [
      for (final row in read.elements) (ElementTarget(row.publicId), row),
      for (final row in read.lineupGroups) (LineupTarget(row.publicId), row),
    ]) {
      if (items.containsKey(target)) {
        fail('the store holds $target on ${items[target]!.page} and $page');
      }
      items[target] = heldOf(row, page);
    }
    for (final row in read.unplaced) {
      damaged[row.ref.name] = page;
    }
  }
  expect(items, {
    for (final MapEntry(:key, :value) in shown.rows.entries)
      if (value.here) key: shownOf(value),
  }, reason: 'items with a readable copy here');
  String itemName(Target target, String page) => switch (target) {
    ElementTarget(:final elementPublicId) => elementName(page, elementPublicId),
    LineupTarget(:final lineupPublicId) => lineupName(page, lineupPublicId),
    _ => fail('$target is not an item'),
  };
  for (final MapEntry(key: target, value: row) in shown.rows.entries) {
    if (!row.here) {
      expect(
        items.containsKey(target),
        isFalse,
        reason: '$target is unreadable to the queue but readable here',
      );
    }
  }
  for (final MapEntry(key: name, value: page) in damaged.entries) {
    final owners = [
      for (final MapEntry(key: target, value: row) in shown.rows.entries)
        if (itemName(target, row.page) == name) row,
    ];
    for (final row in owners) {
      expect(row.here, isFalse, reason: 'item damaged as $name on $page');
    }
    final item = name.split('/').last;
    for (final MapEntry(key: target, value: row) in shown.rows.entries) {
      final id = switch (target) {
        ElementTarget(:final elementPublicId) => elementPublicId,
        LineupTarget(:final lineupPublicId) => lineupPublicId,
        _ => null,
      };
      if (id != null && digestOf(id) == item && row.page != page) {
        fail('$target is held on ${row.page} and damaged on $page');
      }
    }
  }
}

Future<ResultSource> beganIn(LibraryStore store) async {
  final recorded = await recordAll(store, [const ReadBegun()]);
  return effectsOf(recorded).whereType<ReadStartIssued>().single.source;
}
