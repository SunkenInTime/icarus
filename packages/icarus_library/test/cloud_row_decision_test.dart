import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

Future<void> arriveIn(
  LibraryStore store,
  ArrivedBase base,
  ResultPoint from,
) async {
  final recorded = await recordAll(store, [
    arrivedAs(base, session: await sessionOf(store), asked: from),
  ]);
  expect(recorded.outcomes.single, isA<ReportApplied>());
}

Future<PageRow> pageRowIn(LibraryStore store, String page) async =>
    switch (await store.readPage(strategyId, page)) {
      Found(:final value) => value.page,
      final other => fail('page $page did not read: $other'),
    };

Future<List<String>> itemsOn(LibraryStore store, String page) async =>
    switch (await store.readPage(strategyId, page)) {
      Found(:final value) => [
        for (final row in value.elements)
          if (row is LiveElement) row.publicId,
      ],
      final other => fail('page $page did not read: $other'),
    };

Future<LibraryStore> reopened(LibraryStore store, MemoryStorage storage) async {
  await store.close();
  final again = await openCloudStore(MemoryEngine(storage));
  await expectAgree(again);
  return again;
}

StrategyRowSet movedToB(StrategyRowSet rows) =>
    withOp(rows, movePatch('to-b', pageId: 'page-b', x: 40));

StrategyRowSet purged(StrategyRowSet rows, String id) => StrategyRowSet(
  strategy: rows.strategy,
  pages: rows.pages,
  settings: rows.settings,
  elements: [
    for (final row in rows.elements)
      if (row.publicId != id) row,
  ],
  lineupGroups: rows.lineupGroups,
);

String? nameOf(PageRow row) => switch (row) {
  LivePage(:final name) => name,
  _ => null,
};

StrategyRowSet renamed(StrategyRowSet rows) => withOp(
  rows,
  const PagePatchOp(
    opId: 'rename',
    pagePublicId: 'page-a',
    expectedPageRevision: 1,
    name: 'Renamed on the server',
  ),
);

StrategyRowSet withoutSettingsOf(StrategyRowSet rows, String page) =>
    StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: [
        for (final row in rows.settings)
          if (row.pagePublicId != page) row,
      ],
      elements: rows.elements,
      lineupGroups: rows.lineupGroups,
    );

LiveElement e1At({required int revision, required int life}) => LiveElement(
  publicId: 'e1',
  pagePublicId: 'page-a',
  payload: agentPayload('e1', const {}),
  sortIndex: 0,
  revision: revision,
  unknownFields: jsonObject({'createdAt': life}),
);

UnreadableElement e1WithoutRevision() => UnreadableElement(
  publicId: 'e1',
  pagePublicId: 'page-a',
  stored: {
    'publicId': 'e1',
    'pagePublicId': 'page-a',
    'createdAt': fixtureLife,
  },
  problem: 'no revision',
  reason: const FromNewerBuild(),
);

Taken pageAWith(Shown shown, ElementRow row) => shown.taken(
  PageRead(
    page: initialRows().page('page-a')!,
    elements: [row],
    lineupGroups: const [],
  ),
  arrival: null,
);

List<RowTaken> itemsTaken(Taken taken) => [
  for (final decision in taken.decisions)
    if (decision case RowTaken(row: ElementRow())) decision,
];

PageRead pageBCarrying(LiveElement e1) => PageRead(
  page: initialRows().page('page-b')!,
  elements: [...initialRows().elementsOn('page-b'), e1],
  lineupGroups: initialRows().lineupGroupsOn('page-b').toList(),
);

LiveElement e1OnB(LiveElement held, {required int revision}) => LiveElement(
  publicId: held.publicId,
  pagePublicId: 'page-b',
  payload: held.payload,
  sortIndex: held.sortIndex,
  revision: revision,
  unknownFields: held.unknownFields,
);

Shown listed() => Shown.nothing
    .taken(headerReadOf(initialRows()), arrival: null)
    .shown;

void main() {
  group('a row carried by more than one kind of result', () {
    test('a page list read before a page result, arriving after it, does not '
        'put back the page row the page result replaced, and the newer row '
        'is still there after a reopen', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await expectAgree(store);
      final listStart = tick();
      final pageStart = tick();
      final newer = renamed(initialRows());

      await arriveIn(store, pageReadOf(newer, 'page-a'), pageStart);
      expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');
      await expectAgree(store);

      await arriveIn(store, headerReadOf(initialRows()), listStart);
      expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');
      await expectAgree(store);

      store = await reopened(store, storage);
      expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');
    });

    test('a page result read before a page list, arriving after it, keeps the '
        'page row the list replaced, and after a reopen', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final pageStart = tick();
      final listStart = tick();

      await arriveIn(store, headerReadOf(renamed(initialRows())), listStart);
      await expectAgree(store);
      await arriveIn(store, pageReadOf(initialRows(), 'page-a'), pageStart);
      expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');
      await expectAgree(store);

      store = await reopened(store, storage);
      expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');
    });

    test('a page list that still lists a page but no longer carries its '
        'settings removes the settings the store held, and after a '
        'reopen', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final start = tick();
      expect(
        (await store.readStrategy(strategyId) as Found<StrategyRead>).value,
        isA<StrategyContent>().having(
          (content) => content.settings.keys,
          'settings',
          contains('page-a'),
        ),
      );

      await arriveIn(
        store,
        headerReadOf(withoutSettingsOf(initialRows(), 'page-a')),
        start,
      );
      Iterable<String> settingsIn(StrategyRead read) =>
          (read as StrategyContent).settings.keys;
      expect(
        settingsIn(
          (await store.readStrategy(strategyId) as Found<StrategyRead>).value,
        ),
        isNot(contains('page-a')),
      );
      await expectAgree(store);

      store = await reopened(store, storage);
      expect(
        settingsIn(
          (await store.readStrategy(strategyId) as Found<StrategyRead>).value,
        ),
        isNot(contains('page-a')),
      );
    });
  });

  group('which of two copies of a row is kept', () {
    test('a row without a revision never replaces one with a revision', () {
      final held = pageAWith(listed(), e1At(revision: 2, life: fixtureLife));
      final incoming = pageAWith(held.shown, e1WithoutRevision());
      expect(
        incoming.decisions.whereType<RowKept>().map((kept) => kept.because),
        [KeptBecause.heldIsNewer],
      );
      expect(itemsTaken(incoming), isEmpty);
      expect(incoming.shown.rows[const ElementTarget('e1')]?.revision, 2);
    });

    test('a row at the same revision under an older life does not replace '
        'the held one, nor does a higher revision under an older life', () {
      final held = pageAWith(
        listed(),
        e1At(revision: 3, life: fixtureLife + 50),
      );
      for (final stale in [
        e1At(revision: 3, life: fixtureLife),
        e1At(revision: 9, life: fixtureLife),
      ]) {
        final incoming = pageAWith(held.shown, stale);
        expect(itemsTaken(incoming), isEmpty);
        expect(
          incoming.shown.rows[const ElementTarget('e1')]?.life,
          fixtureLife + 50,
        );
      }
    });

    test('a row whose life is not known is compared by revision alone, in '
        'both directions', () {
      final withLife = pageAWith(
        listed(),
        e1At(revision: 2, life: fixtureLife),
      );
      final lifeless = LiveElement(
        publicId: 'e1',
        pagePublicId: 'page-a',
        payload: agentPayload('e1', const {}),
        sortIndex: 0,
        revision: 3,
      );
      final higherWithoutLife = pageAWith(withLife.shown, lifeless);
      expect(itemsTaken(higherWithoutLife), hasLength(1));
      expect(
        higherWithoutLife.shown.rows[const ElementTarget('e1')]?.revision,
        3,
      );

      final heldWithoutLife = pageAWith(listed(), lifeless);
      final lowerWithLife = pageAWith(
        heldWithoutLife.shown,
        e1At(revision: 2, life: fixtureLife + 50),
      );
      expect(itemsTaken(lowerWithLife), isEmpty);
      expect(lowerWithLife.shown.rows[const ElementTarget('e1')]?.revision, 3);

      final lowerWithoutLife = LiveElement(
        publicId: 'e1',
        pagePublicId: 'page-a',
        payload: agentPayload('e1', const {}),
        sortIndex: 0,
        revision: 2,
      );
      final heldLower = pageAWith(listed(), lowerWithoutLife);
      final higherWithLife = pageAWith(
        heldLower.shown,
        e1At(revision: 3, life: fixtureLife),
      );
      expect(itemsTaken(higherWithLife), hasLength(1));
      expect(higherWithLife.shown.rows[const ElementTarget('e1')]?.revision, 3);

      final heldHigher = pageAWith(
        listed(),
        e1At(revision: 3, life: fixtureLife),
      );
      final lowerAgain = pageAWith(heldHigher.shown, lowerWithoutLife);
      expect(itemsTaken(lowerAgain), isEmpty);
      expect(lowerAgain.shown.rows[const ElementTarget('e1')]?.revision, 3);
    });

    test('a row under a newer life replaces the held one even at a lower '
        'revision', () {
      final held = pageAWith(listed(), e1At(revision: 3, life: fixtureLife));
      final incoming = pageAWith(
        held.shown,
        e1At(revision: 1, life: fixtureLife + 50),
      );
      expect(itemsTaken(incoming), hasLength(1));
      expect(incoming.shown.rows[const ElementTarget('e1')]?.revision, 1);
    });
  });

  group('an item and the page it is on', () {
    test('an older page result does not take an item back from the page a '
        'newer result moved it to', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final olderA = tick();
      final newerB = tick();
      final moved = movedToB(initialRows());

      await arriveIn(store, pageReadOf(moved, 'page-b'), newerB);
      expect(await itemsOn(store, 'page-b'), contains('e1'));
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      await expectAgree(store);
      await arriveIn(store, pageReadOf(initialRows(), 'page-a'), olderA);
      expect(await itemsOn(store, 'page-b'), contains('e1'));
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      await expectAgree(store);

      store = await reopened(store, storage);
      expect(await itemsOn(store, 'page-b'), contains('e1'));
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
    });

    test('a page result read before the move, arriving after a newer result '
        'left the item out of the page it moved to (purged on the server), '
        'does not put it back', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final olderA = tick();
      final onB = tick();
      final goneFromB = tick();
      final moved = movedToB(initialRows());

      await arriveIn(store, pageReadOf(moved, 'page-b'), onB);
      await expectAgree(store);
      await arriveIn(
        store,
        pageReadOf(purged(moved, 'e1'), 'page-b'),
        goneFromB,
      );
      await expectAgree(store);
      await arriveIn(store, pageReadOf(initialRows(), 'page-a'), olderA);
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      expect(await itemsOn(store, 'page-b'), isNot(contains('e1')));
      await expectAgree(store);

      store = await reopened(store, storage);
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      expect(await itemsOn(store, 'page-b'), isNot(contains('e1')));
    });

    test('a page result read before another page left an item out because it '
        'moved there is taken', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final onB = tick();
      final leftA = tick();
      final moved = movedToB(initialRows());

      await arriveIn(store, pageReadOf(moved, 'page-a'), leftA);
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      expect(await itemsOn(store, 'page-b'), isNot(contains('e1')));
      await expectAgree(store);
      await arriveIn(store, pageReadOf(moved, 'page-b'), onB);
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      expect(await itemsOn(store, 'page-b'), contains('e1'));
      await expectAgree(store);

      store = await reopened(store, storage);
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      expect(await itemsOn(store, 'page-b'), contains('e1'));
    });

    test('a page result read before another page removed an item stays out '
        'when it carries the version last held, and is taken when it carries '
        'a newer one', () async {
      final held =
          initialRows()
                  .elementsOn('page-a')
                  .firstWhere((row) => row.publicId == 'e1')
              as LiveElement;
      for (final (revision, onB) in [
        (held.revision, false),
        (held.revision + 1, true),
      ]) {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        final readOfB = tick();
        final removing = tick();

        await arriveIn(
          store,
          pageReadOf(purged(initialRows(), 'e1'), 'page-a'),
          removing,
        );
        await arriveIn(
          store,
          pageBCarrying(e1OnB(held, revision: revision)),
          readOfB,
        );
        expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
        expect(
          await itemsOn(store, 'page-b'),
          onB ? contains('e1') : isNot(contains('e1')),
          reason: 'revision $revision',
        );
        await expectAgree(store);

        store = await reopened(store, storage);
        expect(
          await itemsOn(store, 'page-b'),
          onB ? contains('e1') : isNot(contains('e1')),
        );
      }
    });
  });

  for (final removal in ['the page is gone', 'a page list leaves it out']) {
    test(
      'an item taken on the page it moved to stays out when that page is '
      'removed ($removal) and an older result of its first page arrives',
      () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        final olderA = tick();
        final moved = movedToB(initialRows());
        await arriveIn(
          store,
          pageReadOf(moved, 'page-b'),
          tick(),
        );
        await arriveIn(
          store,
          removal == 'the page is gone'
              ? const PageGone('page-b')
              : headerReadOf(withoutPage(moved, 'page-b')),
          tick(),
        );
        await arriveIn(store, pageReadOf(initialRows(), 'page-a'), olderA);
        expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
        await expectAgree(store);
        store = await reopened(store, storage);
        expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      },
    );
  }

  test('a damaged copy left on a page an item moved away from refuses the '
      'strategy when its queue loads', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    final moved = movedToB(initialRows());
    await arriveIn(store, pageReadOf(moved, 'page-b'), tick());
    await store.close();
    final contents = editable(storage.contents);
    contents[strategyArea(strategyId)]![elementName('page-a', 'e1')] =
        '{"broken":true}';
    store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
    expect(
      await store.readPage(strategyId, 'page-a'),
      isA<InUnreadableStrategy<PageContent>>(),
    );
    expect(
      await refusedFor(store),
      'an item is held here on another page than in the queue, or on more '
      'than one',
    );
  });

  test('a trashed page the page list carried is held in Shown from its page '
      'row on disk, not from the stored results, which load whether or not '
      'they carry a trashed list', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    final trashed = initialRows().withRows([
      page('page-b', sortIndex: 1, deleted: true, revision: 2),
    ]);
    await arriveIn(store, headerReadOf(trashed), tick());
    expect((await syncOf(store)).queue.shown.trashed.keys, ['page-b']);
    await expectAgree(store);
    await store.close();

    final area = strategyArea(strategyId);
    final header = jsonDecode(storage.contents[area]!['read/header']!) as Map;
    expect(header.containsKey('trashed'), isFalse);
    expect((header['lives'] as Map?)?.containsKey('trashed') ?? false, isFalse);
    store = await reopened(store, storage);
    expect((await syncOf(store)).queue.shown.trashed.keys, ['page-b']);
    await store.close();

    final contents = editable(storage.contents);
    contents[area]!['read/header'] = jsonEncode({
      ...header,
      'trashed': header['pages'],
      'lives': {...?(header['lives'] as Map?), 'trashed': <String, Object?>{}},
    });
    store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
    expect((await syncOf(store)).queue.shown.trashed.keys, ['page-b']);
    await expectAgree(store);
  });
}

StrategyRowSet withoutPage(StrategyRowSet rows, String page) => StrategyRowSet(
  strategy: rows.strategy,
  pages: [
    for (final row in rows.pages)
      if (row.publicId != page) row,
  ],
  settings: [
    for (final row in rows.settings)
      if (row.pagePublicId != page) row,
  ],
  elements: [
    for (final row in rows.elements)
      if (row.pagePublicId != page) row,
  ],
  lineupGroups: rows.lineupGroups,
);
