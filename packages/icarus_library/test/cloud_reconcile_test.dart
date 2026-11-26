import 'dart:async';
import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

final area = strategyArea(strategyId);

Future<Contents> addedOnDisk([StrategyRowSet? rows]) async {
  final storage = MemoryStorage();
  final store = await openCloudStore(MemoryEngine(storage));
  await addCloud(store, rows ?? initialRows());
  await store.close();
  return editable(storage.contents);
}

typedef Opened = ({LibraryStore store, List<Repair> repairs, Contents disk});

late MemoryStorage openedOn;

Future<Opened> opened(Contents contents) async {
  final storage = MemoryStorage(contents);
  final store = await openCloudStore(MemoryEngine(storage));
  final repairs = <Repair>[];
  final watching = store.changes.listen((change) {
    if (change case StoreRepaired(repairs: final made)) repairs.addAll(made);
  });
  await expectAgree(store);
  await Future<void>.delayed(Duration.zero);
  await watching.cancel();
  await store.close();
  openedOn = MemoryStorage(storage.contents);
  final again = await openCloudStore(MemoryEngine(openedOn));
  final later = <Repair>[];
  final watchingAgain = again.changes.listen((change) {
    if (change case StoreRepaired(repairs: final made)) later.addAll(made);
  });
  await expectAgree(again);
  await Future<void>.delayed(Duration.zero);
  await watchingAgain.cancel();
  expect(later, isEmpty, reason: 'a second open repairs nothing');
  return (store: again, repairs: repairs, disk: editable(storage.contents));
}

Map<String, Object?> json(String text) =>
    jsonDecode(text) as Map<String, Object?>;

void editGroup(
  Contents contents,
  String key,
  Map<String, Object?> Function(Map<String, Object?> group) change,
) => contents[area]![key] = jsonEncode(change(json(contents[area]![key]!)));

Map<String, Object?> withoutEntry(Map<String, Object?> group, String entry) => {
  for (final MapEntry(:key, :value) in group.entries)
    key: switch (value) {
      final List<Object?> rows => [
        for (final row in rows)
          if (!(row is List && row.first == entry)) row,
      ],
      final Map<String, Object?> lives => {
        for (final MapEntry(:key, :value) in lives.entries)
          if (key != entry) key: value,
      },
      _ => value,
    },
};

String pageGroup(String page) => 'read/page/${digestOf(page)}';

String movedTo(String stored, String page, {int? revision}) =>
    jsonEncode({...json(stored), 'pagePublicId': page, 'revision': ?revision});

Future<PageContent> pageIn(LibraryStore store, String page) async =>
    switch (await store.readPage(strategyId, page)) {
      Found(:final value) => value,
      final other => fail('page $page did not read: $other'),
    };

Future<List<String>> itemsOn(LibraryStore store, String page) async => [
  for (final row in (await pageIn(store, page)).elements)
    if (row is LiveElement) row.publicId,
];

Future<void> arrive(LibraryStore store, ArrivedBase base) async {
  final recorded = await recordAll(store, [
    BaseArrived(
      base,
      session: await sessionOf(store),
      from: await beganIn(store),
    ),
  ]);
  expect(recorded.outcomes.single, isA<ReportApplied>());
}

Future<LibraryStore> restarted(LibraryStore store) async {
  await recordAll(store, [const AppRestarted(build: build)]);
  return store;
}

void main() {
  group('an item the queue holds with no copy on this device', () {
    test('is held at its version with no readable copy, reported once, and '
        'the next result of its page at that version writes it', () async {
      final disk = await addedOnDisk();
      disk[area]!.remove(elementName('page-a', 'e1'));
      final (:store, :repairs, disk: _) = await opened(disk);
      expect(repairs, [
        NoCopyOnThisDevice(
          const ElementTarget('e1'),
          page: 'page-a',
          version: const Version(1, life: fixtureLife),
        ),
      ]);
      final held = (await syncOf(
        store,
      )).queue.shown.rows[const ElementTarget('e1')]!;
      expect(held.here, isFalse);
      expect(
        (await syncOf(store)).queue.shown.pageRead('page-a'),
        isA<ReadOwed>(),
      );

      await restarted(store);
      await arrive(store, pageReadOf(initialRows(), 'page-a'));
      expect(await itemsOn(store, 'page-a'), contains('e1'));
      expect(
        (await syncOf(store)).queue.shown.rows[const ElementTarget('e1')]!.here,
        isTrue,
      );
      await expectAgree(store);
    });
  });

  group('an item stored damaged where the queue holds it', () {
    test('is held at its version with no readable copy, and an older result '
        'of its page neither replaces nor removes the damaged copy', () async {
      final newer = withOp(initialRows(), movePatch('later', x: 70));
      final disk = await addedOnDisk(newer);
      disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
      final (:store, :repairs, disk: _) = await opened(disk);
      expect(repairs, [
        DamagedOnThisDevice(
          const ElementTarget('e1'),
          page: 'page-a',
          version: versionOfRow(newer.element('e1')!),
        ),
      ]);

      await restarted(store);
      await arrive(store, pageReadOf(initialRows(), 'page-a'));
      expect((await pageIn(store, 'page-a')).unplaced, hasLength(1));
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      await expectAgree(store);

      await arrive(store, pageReadOf(newer, 'page-a'));
      expect((await pageIn(store, 'page-a')).unplaced, isEmpty);
      expect(await itemsOn(store, 'page-a'), contains('e1'));
      await expectAgree(store);
    });
  });

  group('a second stored copy of an item the queue holds on one page', () {
    for (final damaged in [false, true]) {
      test('is removed${damaged ? ', damaged' : ''}, and the copy on the '
          "queue's page stays", () async {
        final disk = await addedOnDisk();
        final stored = disk[area]![elementName('page-a', 'e1')]!;
        disk[area]![elementName('page-b', 'e1')] = damaged
            ? '{"broken":true}'
            : movedTo(stored, 'page-b', revision: 5);
        final (:store, :repairs, disk: after) = await opened(disk);
        expect(repairs, [
          SecondCopyRemoved(const ElementTarget('e1'), page: 'page-b'),
        ]);
        expect(after[area]!.containsKey(elementName('page-b', 'e1')), isFalse);
        expect(await itemsOn(store, 'page-a'), contains('e1'));
      });
    }
  });

  group('a stored item the queue does not hold', () {
    test('is taken into the queue at its stored version and page, loses to a '
        'newer result by version, and a page result that leaves it out '
        'removes it and keeps out an older read', () async {
      final disk = await addedOnDisk();
      editGroup(
        disk,
        pageGroup('page-a'),
        (group) => withoutEntry(group, 'element:e1'),
      );
      final (:store, :repairs, disk: _) = await opened(disk);
      expect(repairs, [
        TakenFromThisDevice(
          const ElementTarget('e1'),
          page: 'page-a',
          version: const Version(1, life: fixtureLife),
        ),
      ]);

      await restarted(store);
      final stale = await beganIn(store);
      final newer = withOp(initialRows(), movePatch('later', x: 70));
      await arrive(store, pageReadOf(newer, 'page-a'));
      expect(
        (await syncOf(
          store,
        )).queue.shown.rows[const ElementTarget('e1')]!.revision,
        2,
      );
      await arrive(store, pageReadOf(purged(newer, 'e1'), 'page-a'));
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      final again = await recordAll(store, [
        BaseArrived(
          pageReadOf(initialRows(), 'page-a'),
          session: await sessionOf(store),
          from: stale,
        ),
      ]);
      expect(again.outcomes.single, isA<ReportNotApplicable>());
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      await expectAgree(store);
    });
  });

  group('two stored copies of an item the queue does not hold', () {
    for (final (newerOn, olderOn) in [
      ('page-a', 'page-b'),
      ('page-b', 'page-a'),
    ]) {
      test(
        'the newer copy is kept whichever page it is on ($newerOn)',
        () async {
          final disk = await addedOnDisk();
          final stored = disk[area]![elementName('page-a', 'e1')]!;
          disk[area]!
            ..[elementName(newerOn, 'e1')] = movedTo(
              stored,
              newerOn,
              revision: 4,
            )
            ..[elementName(olderOn, 'e1')] = movedTo(
              stored,
              olderOn,
              revision: 2,
            );
          editGroup(
            disk,
            pageGroup('page-a'),
            (group) => withoutEntry(group, 'element:e1'),
          );
          final (:store, :repairs, disk: after) = await opened(disk);
          expect(repairs.toSet(), {
            SecondCopyRemoved(const ElementTarget('e1'), page: olderOn),
            TakenFromThisDevice(
              const ElementTarget('e1'),
              page: newerOn,
              version: const Version(4, life: fixtureLife),
            ),
          });
          expect(after[area]!.containsKey(elementName(olderOn, 'e1')), isFalse);
          expect(await itemsOn(store, newerOn), contains('e1'));
        },
      );
    }

    test('a readable copy wins over a damaged one, and between two readable '
        'copies at the same version the lower page id wins', () async {
      for (final (pageA, pageB, keep) in <(String?, String?, String)>[
        ('{"broken":true}', null, 'page-b'),
        (null, null, 'page-a'),
      ]) {
        final disk = await addedOnDisk();
        final stored = disk[area]![elementName('page-a', 'e1')]!;
        disk[area]!
          ..[elementName('page-a', 'e1')] =
              pageA ?? movedTo(stored, 'page-a', revision: 3)
          ..[elementName('page-b', 'e1')] =
              pageB ?? movedTo(stored, 'page-b', revision: 3);
        editGroup(
          disk,
          pageGroup('page-a'),
          (group) => withoutEntry(group, 'element:e1'),
        );
        final (:store, repairs: _, disk: _) = await opened(disk);
        expect(
          (await syncOf(
            store,
          )).queue.shown.rows[const ElementTarget('e1')]!.page,
          keep,
        );
        expect(await itemsOn(store, keep), contains('e1'));
      }
    });
  });

  group('page, settings and strategy rows', () {
    test('a page the queue holds with no stored row is held with no '
        'readable copy, and the next page list writes it', () async {
      final disk = await addedOnDisk();
      disk[area]!.remove(pageName('page-b'));
      final (:store, :repairs, disk: _) = await opened(disk);
      expect(
        repairs,
        contains(
          NoCopyOnThisDevice(
            const PageTarget('page-b'),
            page: 'page-b',
            version: const Version(1, life: fixtureLife),
          ),
        ),
      );
      expect((await syncOf(store)).queue.shown.list, isA<ReadOwed>());
      await restarted(store);
      await arrive(store, headerReadOf(initialRows()));
      await expectAgree(store);
      expect((await syncOf(store)).queue.shown.pages['page-b']!.here, isTrue);
    });

    test('a damaged page row the queue holds is held with no readable '
        'copy', () async {
      final disk = await addedOnDisk();
      disk[area]![pageName('page-b')] = '{"broken":true}';
      final (:store, :repairs, disk: _) = await opened(disk);
      expect(
        repairs,
        contains(
          DamagedOnThisDevice(
            const PageTarget('page-b'),
            page: 'page-b',
            version: const Version(1, life: fixtureLife),
          ),
        ),
      );
      await expectAgree(store);
    });

    test('a stored page row the queue does not hold, and settings at another '
        'version, are taken as stored', () async {
      final disk = await addedOnDisk();
      editGroup(disk, 'read/header', (group) {
        final dropped = withoutEntry(group, 'page-b');
        return {
          ...dropped,
          'pages': [
            for (final row in dropped['pages']! as List<Object?>)
              if ((row! as List).first != 'page-b') row,
          ],
        };
      });
      disk[area]![settingsName('page-a')] = jsonEncode({
        ...json(disk[area]![settingsName('page-a')]!),
        'revision': 7,
      });
      final (store: _, :repairs, disk: _) = await opened(disk);
      expect(
        repairs.toSet(),
        containsAll([
          TakenFromThisDevice(
            const PageTarget('page-b'),
            page: 'page-b',
            version: const Version(1, life: fixtureLife),
          ),
          TakenFromThisDevice(
            const SettingsTarget('page-a'),
            page: 'page-a',
            version: const Version(7, life: fixtureLife),
          ),
        ]),
      );
    });

    test('a strategy row at another version is taken as stored', () async {
      final disk = await addedOnDisk();
      disk[area]!['strategy'] = jsonEncode({
        ...json(disk[area]!['strategy']!),
        'revision': 9,
      });
      final (store: _, :repairs, disk: _) = await opened(disk);
      expect(repairs, [
        TakenFromThisDevice(
          const StrategyTarget(),
          page: '',
          version: Version(9, life: strategyCreatedAt.millisecondsSinceEpoch),
        ),
      ]);
    });
  });

  test('an item the queue holds with no stored copy is repaired when the '
      'strategy is opened, before any of its pages is read', () async {
    final disk = await addedOnDisk();
    disk[area]!.remove(elementName('page-a', 'e1'));
    final store = await openCloudStore(MemoryEngine(MemoryStorage(disk)));
    final repairs = <Repair>[];
    final watching = store.changes.listen((change) {
      if (change case StoreRepaired(repairs: final made)) repairs.addAll(made);
    });
    expect(await store.readStrategy(strategyId), isA<Found<StrategyRead>>());
    await Future<void>.delayed(Duration.zero);
    await watching.cancel();
    expect(repairs, [
      NoCopyOnThisDevice(
        const ElementTarget('e1'),
        page: 'page-a',
        version: const Version(1, life: fixtureLife),
      ),
    ]);
  });

  test('a page the queue knows only by its items is left by a page list that '
      'does not list it', () async {
    final disk = await addedOnDisk();
    disk[area]!.remove(pageName('page-b'));
    disk[area]!.remove(settingsName('page-b'));
    editGroup(disk, 'read/header', (group) {
      final dropped = withoutEntry(withoutEntry(group, 'page-b'), 'page-b');
      return {
        ...dropped,
        for (final list in ['pages', 'settings'])
          list: [
            for (final row in dropped[list]! as List<Object?>)
              if ((row! as List).first != 'page-b') row,
          ],
      };
    });
    final (:store, repairs: _, disk: _) = await opened(disk);
    final before = (await syncOf(store)).queue.shown;
    expect(before.pages.containsKey('page-b'), isFalse);
    expect(before.rows[const ElementTarget('e3')]?.page, 'page-b');

    await restarted(store);
    await arrive(store, headerReadOf(withoutPageB(initialRows())));
    expect(
      (await syncOf(
        store,
      )).queue.shown.rows.containsKey(const ElementTarget('e3')),
      isFalse,
    );
    await expectAgree(store);
    expect(
      openedOn.contents[area]!.containsKey(elementName('page-b', 'e3')),
      isFalse,
    );
  });

  test('a trashed page is known from its stored page row at every open, and '
      'is not repaired again', () async {
    final storage = MemoryStorage();
    final store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    await arrive(
      store,
      headerReadOf(
        initialRows().withRows([
          page('page-b', sortIndex: 1, deleted: true, revision: 2),
        ]),
      ),
    );
    await store.close();
    final (store: again, :repairs, disk: _) = await opened(
      editable(storage.contents),
    );
    expect(repairs, isEmpty);
    expect((await syncOf(again)).queue.shown.trashed.keys, ['page-b']);
  });

  test('an item damaged on the page the queue holds it on moves to another '
      'page with a newer result, and no second copy is left', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final (:store, repairs: _, disk: _) = await opened(disk);
    await restarted(store);
    final moved = withOp(
      initialRows(),
      movePatch('to-b', pageId: 'page-b', x: 40),
    );
    await arrive(store, pageReadOf(moved, 'page-b'));
    expect((await pageIn(store, 'page-a')).unplaced, isEmpty);
    expect(await itemsOn(store, 'page-b'), contains('e1'));
    await expectAgree(store);
  });

  test('a store that agrees is opened with no repair and no write', () async {
    final disk = await addedOnDisk();
    final before = editable(disk);
    final (store: _, :repairs, disk: after) = await opened(disk);
    expect(repairs, isEmpty);
    expect(after, before);
  });
}

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

StrategyRowSet withoutPageB(StrategyRowSet rows) => StrategyRowSet(
  strategy: rows.strategy,
  pages: [
    for (final row in rows.pages)
      if (row.publicId != 'page-b') row,
  ],
  settings: [
    for (final row in rows.settings)
      if (row.pagePublicId != 'page-b') row,
  ],
  elements: [
    for (final row in rows.elements)
      if (row.pagePublicId != 'page-b') row,
  ],
  lineupGroups: rows.lineupGroups,
);
