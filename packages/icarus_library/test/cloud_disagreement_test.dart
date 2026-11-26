import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart'
    show CloudFacts, CloudRowRead, factsFromText;
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

final area = strategyArea(strategyId);

final class ServingAnotherRevision extends ForwardingLease {
  ServingAnotherRevision(super.inner, this.key, this.switched);

  final String key;
  final bool Function() switched;

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async =>
      switch (await super.entries(area, prefix)) {
        Done(:final value) when switched() => Done([
          for (final entry in value)
            entry.key == key
                ? (
                    key: entry.key,
                    value: jsonEncode({...json(entry.value), 'revision': 4}),
                  )
                : entry,
        ]),
        final other => other,
      };
}

Future<Contents> addedOnDisk([StrategyRowSet? rows]) async {
  final storage = MemoryStorage();
  final store = await openCloudStore(MemoryEngine(storage));
  await addCloud(store, rows ?? initialRows());
  await store.close();
  return editable(storage.contents);
}

Map<String, Object?> json(String text) =>
    jsonDecode(text) as Map<String, Object?>;

Future<void> expectSetAside(
  LibraryStore store,
  MemoryStorage storage,
  String reason,
) async {
  final base = await baseOf(store);
  expect(base, isA<BaseRereading>());
  expect((base as BaseRereading).reason, contains(reason));
  final queue = (await syncOf(store)).queue;
  expect(queue.shown.list, isA<ReadOwed>());
  expect(queue.shown.rows, isEmpty);
  expect([
    for (final key in storage.contents[area]!.keys)
      if (key.startsWith('content/')) key,
  ], isEmpty);
}

Future<BaseState> baseOf(LibraryStore store) async =>
    (await syncOf(store)).queue.strategy.base;

Future<LibraryStore> openedAndPaged(
  MemoryStorage storage, {
  String build = build,
  int buildNumber = 0,
}) async {
  final store = await openCloudStore(
    MemoryEngine(storage),
    build: build,
    buildNumber: buildNumber,
  );
  await recordAll(store, [AppRestarted(build: build)]);
  for (final page in ['page-a', 'page-b']) {
    await store.readPage(strategyId, page);
  }
  return store;
}

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

Future<void> readAgain(LibraryStore store, StrategyRowSet server) async {
  await arrive(store, headerReadOf(server));
  for (final page in server.pages) {
    await arrive(store, pageReadOf(server, page.publicId));
  }
}

String movedTo(String stored, String page, {int? revision}) =>
    jsonEncode({...json(stored), 'pagePublicId': page, 'revision': ?revision});

UnreadableElement fromANewerBuild(String id) => UnreadableElement(
  publicId: id,
  pagePublicId: 'page-a',
  stored: {
    ...element(id).toJson(),
    'payload': {
      'kind': 'hologram',
      'payloadVersion': 1,
      'data': <String, Object?>{},
    },
  },
  problem: 'a kind from a newer build',
  reason: const FromNewerBuild(),
);

void main() {
  group('the line between agreeing and disagreeing', () {
    test('a row this build cannot read agrees when its name and version '
        'match', () async {
      final rows = initialRows().withRows([fromANewerBuild('e9')]);
      final storage = MemoryStorage(await addedOnDisk(rows));
      final store = await openedAndPaged(storage);
      expect(await baseOf(store), isA<BaseAgrees>());
      await expectAgree(store);
    });

    test('an unplaced row where the queue holds a row disagrees', () async {
      final disk = await addedOnDisk();
      disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
      final storage = MemoryStorage(disk);
      final store = await openedAndPaged(storage);
      await expectSetAside(store, storage, 'a row on page page-a is damaged');
      expect(
        storage.contents[area]!.containsKey(elementName('page-a', 'e1')),
        isFalse,
      );
    });

    test('a row of a kind this build does not know is left out', () async {
      final disk = await addedOnDisk();
      disk[area]!['content/${digestOf('page-a')}/z/${digestOf('x')}'] =
          '{"kind":"from a newer build"}';
      final store = await openedAndPaged(MemoryStorage(disk));
      expect(await baseOf(store), isA<BaseAgrees>());
    });

    test('the strategy row is compared by version only', () async {
      final renamed = await addedOnDisk();
      renamed[area]!['strategy'] = jsonEncode({
        ...json(renamed[area]!['strategy']!),
        'name': 'Renamed here',
      });
      expect(
        await baseOf(await openedAndPaged(MemoryStorage(renamed))),
        isA<BaseAgrees>(),
      );
      final newer = await addedOnDisk();
      newer[area]!['strategy'] = jsonEncode({
        ...json(newer[area]!['strategy']!),
        'revision': 9,
      });
      expect(
        await baseOf(await openedAndPaged(MemoryStorage(newer))),
        isA<BaseRereading>(),
      );
    });

    test(
      'a page trashed on disk that the queue holds live disagrees',
      () async {
        final disk = await addedOnDisk();
        disk[area]![pageName('page-b')] = jsonEncode({
          ...json(disk[area]![pageName('page-b')]!),
          'deleted': true,
        });
        final storage = MemoryStorage(disk);
        final store = await openedAndPaged(storage);
        await expectSetAside(
          store,
          storage,
          'page page-b is live in the queue and not here',
        );
      },
    );
  });

  test('a settings row on the wrong page with the count unchanged '
      'disagrees, and reading again ends agreeing', () async {
    final rows = strategyRows(
      pageSettings: [settings('page-a')],
      elements: initialRows().elements.toList(),
    );
    final disk = await addedOnDisk(rows);
    final moved = disk[area]!.remove(settingsName('page-a'))!;
    disk[area]![settingsName('page-b')] = jsonEncode({
      ...json(moved),
      'pagePublicId': 'page-b',
    });
    final storage = MemoryStorage(disk);
    final store = await openedAndPaged(storage);
    expect(
      (await baseOf(store) as BaseRereading).reason,
      contains('the settings of page page-a are at null here'),
    );
    await readAgain(store, rows);
    expect(await baseOf(store), isA<BaseAgrees>());
    await expectAgree(store);
  });

  test('a page the queue holds with no stored row, and no settings, '
      'disagrees', () async {
    final rows = strategyRows(
      pageSettings: [settings('page-a')],
      elements: initialRows().elements.toList(),
    );
    final disk = await addedOnDisk(rows);
    disk[area]!.remove(pageName('page-b'));
    final storage = MemoryStorage(disk);
    final store = await openedAndPaged(storage);
    await expectSetAside(
      store,
      storage,
      'page page-b is live in the queue and not here',
    );
  });

  group('a store that disagrees is read again and ends agreeing', () {
    void dropFromHeader(Contents disk, String page, List<String> lists) {
      final header = json(disk[area]!['read/header']!);
      final lives = {...header['lives']! as Map<String, Object?>};
      disk[area]!['read/header'] = jsonEncode({
        ...header,
        for (final list in lists)
          list: [
            for (final row in header[list]! as List<Object?>)
              if ((row! as List).first != page) row,
          ],
        'lives': {
          ...lives,
          for (final list in lists)
            list: {
              for (final MapEntry(:key, :value)
                  in (lives[list]! as Map<String, Object?>).entries)
                if (key != page) key: value,
            },
        },
      });
    }

    void dropFromPage(Contents disk, String page, String entry) {
      final key = 'read/page/${digestOf(page)}';
      final group = json(disk[area]![key]!);
      disk[area]![key] = jsonEncode({
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
      });
    }

    String revised(String stored, int revision) =>
        jsonEncode({...json(stored), 'revision': revision});

    final seeds = <String, (String, void Function(Contents disk))>{
      'a damaged page row': (
        'a page or settings row is damaged here',
        (disk) => disk[area]![pageName('page-b')] = '{"broken":true}',
      ),
      'the only copy of an item on another page': (
        'on another page than in the queue, or on more than one',
        (disk) {
          final stored = disk[area]!.remove(elementName('page-a', 'e1'))!;
          disk[area]![elementName('page-b', 'e1')] = movedTo(stored, 'page-b');
        },
      ),
      'a placed item whose revision cannot be read': (
        'ElementTarget(e1) is at null here',
        (disk) => disk[area]![elementName('page-a', 'e1')] = jsonEncode({
          for (final MapEntry(:key, :value) in json(
            disk[area]![elementName('page-a', 'e1')]!,
          ).entries)
            if (key != 'revision') key: value,
        }),
      ),
      'a page at another version': (
        'page page-b is at',
        (disk) => disk[area]![pageName('page-b')] = revised(
          disk[area]![pageName('page-b')]!,
          5,
        ),
      ),
      'a stored page the queue does not hold': (
        'page page-b is live here and not in the queue',
        (disk) => dropFromHeader(disk, 'page-b', ['pages']),
      ),
      'settings with no stored row': (
        'the settings held here are not the ones the queue holds',
        (disk) => disk[area]!.remove(settingsName('page-a')),
      ),
      'settings at another version': (
        'the settings of page page-a are at',
        (disk) => disk[area]![settingsName('page-a')] = revised(
          disk[area]![settingsName('page-a')]!,
          7,
        ),
      ),
      'a stored item the queue does not hold': (
        'an item is held here that the queue does not hold',
        (disk) => dropFromPage(disk, 'page-a', 'element:e1'),
      ),
      'a second copy of an item': (
        'on another page than in the queue, or on more than one',
        (disk) => disk[area]![elementName('page-b', 'e1')] = movedTo(
          disk[area]![elementName('page-a', 'e1')]!,
          'page-b',
        ),
      ),
      'an item on a page with no stored row': (
        'an item is held on a page with no page row here',
        (disk) {
          disk[area]!
            ..remove(pageName('page-b'))
            ..remove(settingsName('page-b'));
          dropFromHeader(disk, 'page-b', ['pages', 'settings']);
        },
      ),
      'an item the queue holds with no stored copy': (
        'the queue holds an item that has no copy here',
        (disk) => disk[area]!.remove(elementName('page-a', 'e1')),
      ),
      'a damaged item': (
        'a row on page page-a is damaged here',
        (disk) => disk[area]![elementName('page-a', 'e1')] = '{"broken":true}',
      ),
      'an item at another version': (
        'ElementTarget(e1) is at',
        (disk) => disk[area]![elementName('page-a', 'e1')] = revised(
          disk[area]![elementName('page-a', 'e1')]!,
          4,
        ),
      ),
    };
    for (final MapEntry(key: what, value: (reason, seed)) in seeds.entries) {
      test(what, () async {
        final disk = await addedOnDisk();
        seed(disk);
        final storage = MemoryStorage(disk);
        final store = await openedAndPaged(storage);
        final base = await baseOf(store);
        expect(base, isA<BaseRereading>());
        expect((base as BaseRereading).tried, [build]);
        expect(base.reason, contains(reason));
        final shown = (await syncOf(store)).queue.shown;
        expect(shown.rows, isEmpty);
        expect(shown.list, isA<ReadOwed>());
        expect(
          (await store.readPage(strategyId, 'page-a') as Found<PageContent>)
              .value
              .content,
          const ContentNotRead(),
        );

        await readAgain(store, initialRows());
        expect(await baseOf(store), isA<BaseAgrees>());
        await expectAgree(store);
        await store.close();

        final again = await openedAndPaged(MemoryStorage(storage.contents));
        expect(await baseOf(again), isA<BaseAgrees>());
        await expectAgree(again);
      });
    }
  });

  test('work the user queued before the set-aside is kept, waits for the page '
      'list the set-aside owes, and then sends', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    savedValue(
      await store.commitAs(
        testAccount,
        strategyId,
        movePatch('kept', x: 90, merge: FieldMerge(fields: ['position'])),
        seen: await seenIn(store),
      ),
    );
    await store.close();
    final disk = editable(storage.contents);
    disk[area]![elementName('page-b', 'e3')] = '{"broken":true}';
    store = await openedAndPaged(MemoryStorage(disk));
    expect(await baseOf(store), isA<BaseRereading>());
    expect((await syncOf(store)).queue.entries.map((entry) => entry.id), [
      'kept',
    ]);
    expect((await syncOf(store)).views['kept']!.holds.map((hold) => '$hold'), [
      'awaiting a result for the page list',
    ]);
    await arrive(store, headerReadOf(initialRows()));
    final batch = await claimAll(store);
    expect(batch.ops.map((op) => op.opId), ['kept']);
  });

  test('a page whose base is being read again cannot be copied', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final store = await openedAndPaged(MemoryStorage(disk));
    await arrive(store, headerReadOf(initialRows()));
    expect(
      await store.commitAs(
        testAccount,
        strategyId,
        pageAdd('copy', 'page-c', copyFrom: 'page-a', sortIndex: 2),
        seen: await seenIn(store),
      ),
      isA<Refused<Committed, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        const CopyNeedsContent('page-a'),
      ),
    );
  });

  test('a set-aside that is not written leaves the old state, and the next '
      'open sets the base aside again', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final storage = MemoryStorage(disk);
    final refusing = await openCloudStore(
      flaky(MemoryEngine(storage), {0: Failing.refused}),
    );
    expect(
      await refusing.record(testAccount, strategyId, [
        const AppRestarted(build: build),
      ]),
      isA<NotSaved<Recorded, CommitRefusal>>(),
    );
    await refusing.close();
    expect(
      storage.contents[area]!.containsKey(elementName('page-a', 'e1')),
      isTrue,
    );
    final store = await openedAndPaged(storage);
    expect(await baseOf(store), isA<BaseRereading>());
  });

  test('a store that agrees is opened, paged through and given results with '
      'no set-aside', () async {
    final storage = MemoryStorage(await addedOnDisk());
    final store = await openedAndPaged(storage);
    await readAgain(store, withOp(initialRows(), movePatch('later', x: 30)));
    expect(await baseOf(store), isA<BaseAgrees>());
    await expectAgree(store);
  });

  test('a page list that keeps every page loads none of their content, and '
      'a page result loads only its own page', () async {
    final disk = await addedOnDisk();
    final (engine, counts) = counting(MemoryEngine(MemoryStorage(disk)));
    final store = await openCloudStore(engine);
    await recordAll(store, [const AppRestarted(build: build)]);
    final start = await beganIn(store);
    counts.reset();
    await recordAll(store, [
      BaseArrived(
        headerReadOf(initialRows()),
        session: await sessionOf(store),
        from: start,
      ),
    ]);
    expect([
      for (final (_, prefix) in counts.entryListings)
        if (prefix.startsWith('content/')) prefix,
    ], isEmpty);
    final pageStart = await beganIn(store);
    counts.reset();
    await recordAll(store, [
      BaseArrived(
        pageReadOf(initialRows(), 'page-a'),
        session: await sessionOf(store),
        from: pageStart,
      ),
    ]);
    expect(
      [
        for (final (_, prefix) in counts.entryListings)
          if (prefix.startsWith('content/')) prefix,
      ],
      ['content/${digestOf('page-a')}/'],
    );
  });

  test('the set-aside and the stored state land in one commit', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final storage = MemoryStorage(disk);
    final (engine, counts) = counting(MemoryEngine(storage));
    final store = await openCloudStore(engine);
    await store.readPage(strategyId, 'page-a');
    expect(counts.commits, 1);
    expect(await baseOf(store), isA<BaseRereading>());
    expect(counts.written, contains((area, 'cloud')));
    expect(counts.deleted, contains((area, elementName('page-a', 'e1'))));
    expect(
      factsFromText(storage.contents[area]!['cloud']!),
      isA<CloudRowRead<CloudFacts>>().having(
        (read) => read.value.facts.base,
        'base',
        isA<BaseRereading>(),
      ),
    );
  });

  test('after a set-aside the list is owed, and once it lands every page it '
      'lists is to be read', () async {
    final disk = await addedOnDisk();
    disk[area]!.remove(elementName('page-b', 'e3'));
    final store = await openedAndPaged(MemoryStorage(disk));
    final queue = (await syncOf(store)).queue;
    expect(queue.shown.list, isA<ReadOwed>());
    await arrive(store, headerReadOf(initialRows()));
    expect(pagesNeverRead((await syncOf(store)).queue), {'page-a', 'page-b'});
  });

  test('a lower stored revision than the queue holds disagrees with digest '
      'checks off', () async {
    final checked = shownTakesChecked;
    addTearDown(() => shownTakesChecked = checked);
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    final older = storage.contents[area]![elementName('page-a', 'e1')]!;
    await arrive(
      store,
      pageReadOf(withOp(initialRows(), movePatch('later', x: 70)), 'page-a'),
    );
    await store.close();
    final disk = editable(storage.contents);
    disk[area]![elementName('page-a', 'e1')] = older;
    shownTakesChecked = false;
    store = await openedAndPaged(MemoryStorage(disk));
    expect(await baseOf(store), isA<BaseRereading>());
  });

  test('a store that agrees opens and pages through with no commit', () async {
    final (engine, counts) = counting(
      MemoryEngine(MemoryStorage(await addedOnDisk())),
    );
    final store = await openCloudStore(engine);
    await store.readStrategy(strategyId);
    for (final page in ['page-a', 'page-b']) {
      await store.readPage(strategyId, page);
    }
    expect(counts.commits, 0);
    expect(await baseOf(store), isA<BaseAgrees>());
  });

  test('a page the queue knows only by its settings has its settings stored '
      'with no page row: that is a disagreement, and once the list is read '
      'again the stored settings are gone', () async {
    final disk = await addedOnDisk();
    final settingsA = json(disk[area]![settingsName('page-a')]!);
    disk[area]![settingsName('page-c')] = jsonEncode({
      ...settingsA,
      'pagePublicId': 'page-c',
    });
    final header = json(disk[area]!['read/header']!);
    final listed =
        (header['settings']! as List<Object?>).firstWhere(
              (row) => (row! as List).first == 'page-a',
            )!
            as List<Object?>;
    disk[area]!['read/header'] = jsonEncode({
      ...header,
      'settings': [
        ...header['settings']! as List<Object?>,
        ['page-c', 'page-c', ...listed.skip(2)],
      ],
      'lives': {
        ...header['lives']! as Map<String, Object?>,
        'settings': {
          ...(header['lives']! as Map<String, Object?>)['settings']!
              as Map<String, Object?>,
          'page-c': fixtureLife,
        },
      },
    });
    final storage = MemoryStorage(disk);
    final store = await openedAndPaged(storage);
    expect(await baseOf(store), isA<BaseRereading>());
    await readAgain(store, initialRows());
    expect(
      storage.contents[area]!.containsKey(settingsName('page-c')),
      isFalse,
    );
    expect(await baseOf(store), isA<BaseAgrees>());
    await expectAgree(store);
  });

  test('a page that goes leaves no item index entry behind, so a newer copy '
      'of one of its items shows on another page', () async {
    final store = await openedAndPaged(MemoryStorage(await addedOnDisk()));
    await arrive(store, const PageGone('page-b'));
    final moved = withOp(
      initialRows(),
      movePatch('to-a', elementId: 'e3', pageId: 'page-a', x: 5),
    );
    await arrive(store, pageReadOf(moved, 'page-a'));
    expect([
      for (final row
          in (await store.readPage(strategyId, 'page-a') as Found<PageContent>)
              .value
              .elements)
        row.publicId,
    ], contains('e3'));
  });

  test('a re-read that the app is restarted in the middle of still ends '
      'agreeing once the pages not yet read are read', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final storage = MemoryStorage(disk);
    var store = await openedAndPaged(storage);
    await arrive(store, headerReadOf(initialRows()));
    await arrive(store, pageReadOf(initialRows(), 'page-a'));
    await store.close();
    store = await openCloudStore(MemoryEngine(MemoryStorage(storage.contents)));
    await recordAll(store, [const AppRestarted(build: build)]);
    expect(await baseOf(store), isA<BaseRereading>());
    expect(pagesNeverRead((await syncOf(store)).queue), {'page-b'});
    await arrive(store, pageReadOf(initialRows(), 'page-b'));
    expect(await baseOf(store), isA<BaseAgrees>());
    await expectAgree(store);
  });

  Future<MemoryStorage> rereadingStorage() async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final storage = MemoryStorage(disk);
    final store = await openedAndPaged(storage);
    expect(await baseOf(store), isA<BaseRereading>());
    await store.close();
    return MemoryStorage(storage.contents);
  }

  Future<MemoryStorage> heldStorage() async {
    final rereading = await rereadingStorage();
    var store = await openedAndPaged(rereading);
    await arrive(store, headerReadOf(initialRows()));
    await arrive(store, pageReadOf(initialRows(), 'page-a'));
    await store.close();
    final planted = editable(rereading.contents);
    planted[area]![elementName('page-a', 'stray')] = jsonEncode(
      element('stray').toJson(),
    );
    final held = MemoryStorage(planted);
    store = await openedAndPaged(held);
    expect(await baseOf(store), isA<BaseHeld>());
    await store.close();
    return MemoryStorage(held.contents);
  }

  group('a base held after it was read again', () {
    test('a row found while the base is read again holds it: the base rows '
        'leave and nothing is read', () async {
      final held = await heldStorage();
      expect(
        held.contents[area]!.containsKey(elementName('page-a', 'stray')),
        isFalse,
      );
      final store = await openedAndPaged(held);
      final base = await baseOf(store);
      expect((base as BaseHeld).tried, [build]);
      final queue = (await syncOf(store)).queue;
      expect(queue.shown.rows, isEmpty);
      expect(isDebt(queue.shown.list), isFalse);
      expect(pagesNeverRead(queue), isEmpty);
    });

    test('takes no result, shows no page, and still sends work that needs no '
        'evidence from the base', () async {
      final store = await openedAndPaged(await heldStorage());
      final recorded = await recordAll(store, [
        BaseArrived(
          pageReadOf(initialRows(), 'page-a'),
          session: await sessionOf(store),
          from: await beganIn(store),
        ),
      ]);
      expect(
        recorded.outcomes.single,
        isA<ReportNotApplicable>().having(
          (outcome) => outcome.why,
          'why',
          isA<BaseIsHeld>(),
        ),
      );
      final page =
          (await store.readPage(strategyId, 'page-a') as Found<PageContent>)
              .value;
      expect(page.content, const ContentNotRead());
      expect(page.elements, isEmpty);
      savedValue(
        await store.commitAs(
          testAccount,
          strategyId,
          elementAdd('added-while-held'),
          seen: await seenIn(store),
        ),
      );
      final sent = await claimAll(store);
      expect(sent.ops.map((op) => op.opId), ['added-while-held']);
      await recordAll(store, [
        OpAnswered(
          sent.attempt,
          const AppliedAnswer('added-while-held', revision: 1, life: 42),
        ),
      ]);
      final sync = await syncOf(store);
      expect(sync.queue.entries, isEmpty);
      expect(sync.tally.waiting, isEmpty);
      expect(sync.tally.attention, isEmpty);
      expect(await baseOf(store), isA<BaseHeld>());
    });

    test('a base row found on disk in a held strategy is removed, and the '
        'strategy stays held', () async {
      final held = editable((await heldStorage()).contents);
      held[area]![elementName('page-b', 'e3')] = jsonEncode(
        element('e3', pageId: 'page-b').toJson(),
      );
      final storage = MemoryStorage(held);
      final store = await openedAndPaged(storage);
      expect(await baseOf(store), isA<BaseHeld>());
      expect(
        storage.contents[area]!.containsKey(elementName('page-b', 'e3')),
        isFalse,
      );
    });

    test('the same build does not read it again, and a build that has not '
        'tried reads it again once and ends agreeing', () async {
      final held = await heldStorage();
      var store = await openedAndPaged(held);
      expect(await baseOf(store), isA<BaseHeld>());
      await store.close();
      store = await openedAndPaged(
        MemoryStorage(held.contents),
        build: 'a later build',
      );
      final reread = await baseOf(store);
      expect(reread, isA<BaseRereading>());
      expect((reread as BaseRereading).tried, [build, 'a later build']);
      await readAgain(store, initialRows());
      expect(await baseOf(store), isA<BaseAgrees>());
      await expectAgree(store);
    });
  });

  test(
    'a fix shipped under the same version name, with another build '
    'number, reads a held base again; two builds taking turns do not',
    () async {
      final held = await heldStorage();
      final store = await openedAndPaged(
        MemoryStorage(held.contents),
        buildNumber: 2,
      );
      expect((await baseOf(store) as BaseRereading).tried, [build, '$build+2']);
      await store.close();

      final twice = editable((await heldStorage()).contents);
      final facts = json(twice[area]!['cloud']!);
      twice[area]!['cloud'] = jsonEncode({
        ...facts,
        'base': {
          ...facts['base']! as Map<String, Object?>,
          'tried': [build, 'b'],
        },
      });
      for (final turn in [build, 'b', build, 'b']) {
        final opened = await openedAndPaged(MemoryStorage(twice), build: turn);
        expect(
          await baseOf(opened),
          isA<BaseHeld>(),
          reason: 'opened by $turn',
        );
        await opened.close();
      }
    },
  );

  test('a build that has not tried, opening a re-read under way, is added to '
      'the builds that tried', () async {
    final rereading = await rereadingStorage();
    final store = await openedAndPaged(rereading, build: 'a later build');
    final base = await baseOf(store);
    expect((base as BaseRereading).tried, [build, 'a later build']);
  });

  test('a restart before the list lands leaves the list owed, writes nothing '
      'more, and the list is still read', () async {
    final (engine, counts) = counting(MemoryEngine(await rereadingStorage()));
    final store = await openCloudStore(engine);
    await recordAll(store, [const AppRestarted(build: build)]);
    await store.readPage(strategyId, 'page-a');
    expect(await baseOf(store), isA<BaseRereading>());
    expect(counts.deleted, isEmpty);
    expect((await syncOf(store)).queue.shown.list, isA<ReadOwed>());
  });

  test('a set-aside found by a reader wakes the sender', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final store = await openCloudStore(MemoryEngine(MemoryStorage(disk)));
    await store.readStrategy(strategyId);
    final changes = <StoreChange>[];
    final watching = store.changes.listen(changes.add);
    await store.readPage(strategyId, 'page-a');
    await Future<void>.delayed(Duration.zero);
    await watching.cancel();
    expect(await baseOf(store), isA<BaseRereading>());
    expect(changes.whereType<StrategyRefreshed>(), isNotEmpty);
  });

  group('a strategy life the queue holds that the server does not', () {
    for (final (what, shift) in [('newer', 1), ('older', -1)]) {
      test('$what than the stored one: the next list is taken whatever life '
          'it names, and work for that life still sends', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        savedValue(
          await store.commitAs(
            testAccount,
            strategyId,
            movePatch('kept', x: 90, merge: FieldMerge(fields: ['position'])),
            seen: await seenIn(store),
          ),
        );
        await store.close();
        final disk = editable(storage.contents);
        final header = json(disk[area]!['read/header']!);
        final lives = {...header['lives']! as Map<String, Object?>};
        final strategyLives = {...lives['strategy']! as Map<String, Object?>};
        strategyLives['strategy'] =
            (strategyLives['strategy']! as int) + shift * 1000;
        disk[area]!['read/header'] = jsonEncode({
          ...header,
          'lives': {...lives, 'strategy': strategyLives},
        });
        store = await openedAndPaged(MemoryStorage(disk));
        expect(await baseOf(store), isA<BaseRereading>());
        await readAgain(store, initialRows());
        expect(await baseOf(store), isA<BaseAgrees>());
        expect((await syncOf(store)).queue.entries.map((entry) => entry.id), [
          'kept',
        ]);
        expect((await claimAll(store)).ops.map((op) => op.opId), ['kept']);
      });
    }
  });

  test('a strategy gone during a re-read removes the page and settings rows '
      'and ends it', () async {
    final rereading = await rereadingStorage();
    final store = await openedAndPaged(rereading);
    await arrive(store, const StrategyGone());
    expect(await baseOf(store), isA<BaseAgrees>());
    expect([
      for (final key in rereading.contents[area]!.keys)
        if (key.startsWith('page/') || key.startsWith('settings/')) key,
    ], isEmpty);
  });

  test('a page list removes a stored page it does not list, even one the '
      'queue does not know, while the base is read again', () async {
    final planted = editable((await rereadingStorage()).contents);
    planted[area]![pageName('page-z')] = jsonEncode({
      ...json(planted[area]![pageName('page-b')]!),
      'publicId': 'page-z',
      'sortIndex': 5,
    });
    final storage = MemoryStorage(planted);
    final store = await openedAndPaged(storage);
    expect(await baseOf(store), isA<BaseRereading>());
    await arrive(store, headerReadOf(initialRows()));
    expect(storage.contents[area]!.containsKey(pageName('page-z')), isFalse);
  });

  group(
    'a write of a new state that is refused or whose outcome is unknown',
    () {
      for (final (what, failing) in [
        ('refused', Failing.refused),
        ('unknown, landed', Failing.landed),
        ('unknown, lost', Failing.lost),
      ]) {
        test('a set-aside: $what', () async {
          final disk = await addedOnDisk();
          disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
          final storage = MemoryStorage(disk);
          var store = await openCloudStore(
            flaky(MemoryEngine(storage), {0: failing}),
          );
          await store.readPage(strategyId, 'page-a');
          await store.close();
          store = await openedAndPaged(MemoryStorage(storage.contents));
          expect(await baseOf(store), isA<BaseRereading>());
          expect(
            storage.contents[area]!.containsKey(elementName('page-a', 'e1')),
            failing != Failing.landed,
          );
        });

        test('a re-read going to held: $what', () async {
          final rereading = await rereadingStorage();
          var store = await openedAndPaged(rereading);
          await arrive(store, headerReadOf(initialRows()));
          await arrive(store, pageReadOf(initialRows(), 'page-a'));
          await store.close();
          final planted = editable(rereading.contents);
          planted[area]![elementName('page-a', 'stray')] = jsonEncode(
            element('stray').toJson(),
          );
          final storage = MemoryStorage(planted);
          store = await openCloudStore(
            flaky(MemoryEngine(storage), {0: failing}),
          );
          await store.readPage(strategyId, 'page-a');
          await store.close();
          store = await openedAndPaged(MemoryStorage(storage.contents));
          expect(await baseOf(store), isA<BaseHeld>());
        });

        test('completing a re-read: $what', () async {
          final rereading = await rereadingStorage();
          var store = await openedAndPaged(rereading);
          await arrive(store, headerReadOf(initialRows()));
          await arrive(store, pageReadOf(initialRows(), 'page-a'));
          await store.close();
          final disk = MemoryStorage(rereading.contents);
          store = await openCloudStore(flaky(MemoryEngine(disk), {1: failing}));
          await recordAll(store, [const AppRestarted(build: build)]);
          final start = await beganIn(store);
          await store.record(testAccount, strategyId, [
            BaseArrived(
              pageReadOf(initialRows(), 'page-b'),
              session: await sessionOf(store),
              from: start,
            ),
          ]);
          await store.close();
          store = await openedAndPaged(MemoryStorage(disk.contents));
          final base = await baseOf(store);
          if (failing == Failing.landed) {
            expect(base, isA<BaseAgrees>());
          } else {
            expect(base, isA<BaseRereading>());
            expect(pagesNeverRead((await syncOf(store)).queue), {'page-b'});
            await arrive(store, pageReadOf(initialRows(), 'page-b'));
            expect(await baseOf(store), isA<BaseAgrees>());
          }
          await expectAgree(store);
        });
      }
    },
  );

  test('a result older than the fence loads nothing', () async {
    final disk = await addedOnDisk();
    final storage = MemoryStorage(disk);
    var store = await openCloudStore(MemoryEngine(storage));
    await recordAll(store, [const AppRestarted(build: build)]);
    final before = await beganIn(store);
    await store.close();
    final damaged = editable(storage.contents);
    damaged[area]![elementName('page-b', 'e3')] = '{"broken":true}';
    final (engine, counts) = counting(MemoryEngine(MemoryStorage(damaged)));
    store = await openCloudStore(engine);
    await store.readPage(strategyId, 'page-b');
    expect(await baseOf(store), isA<BaseRereading>());
    counts.reset();
    await store.record(testAccount, strategyId, [
      BaseArrived(
        pageReadOf(initialRows(), 'page-a'),
        session: await sessionOf(store),
        from: before,
      ),
    ]);
    expect([
      for (final (_, prefix) in counts.entryListings)
        if (prefix.startsWith('content/')) prefix,
    ], isEmpty);
  });

  test('a result whose page disagrees is not decided from that page: the '
      'record path sets the base aside first', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = jsonEncode({
      ...json(disk[area]![elementName('page-a', 'e1')]!),
      'revision': 4,
    });
    final storage = MemoryStorage(disk);
    final store = await openCloudStore(MemoryEngine(storage));
    await recordAll(store, [const AppRestarted(build: build)]);
    final start = await beganIn(store);
    final recorded = await recordAll(store, [
      BaseArrived(
        pageReadOf(initialRows(), 'page-a'),
        session: await sessionOf(store),
        from: start,
      ),
    ]);
    expect(recorded.outcomes.single, isA<ReportNotApplicable>());
    await expectSetAside(store, storage, 'ElementTarget(e1) is at 4');
  });

  test('a page loaded again after the strategy was dropped from memory is '
      'checked again', () async {
    final storage = MemoryStorage(await addedOnDisk());
    var switched = false;
    final store = await openCloudStore(
      WrappingEngine(
        MemoryEngine(storage),
        (lease) => FlakyLease(
          ServingAnotherRevision(
            lease,
            elementName('page-a', 'e1'),
            () => switched,
          ),
          {0: Failing.refused},
        ),
      ),
    );
    await store.readPage(strategyId, 'page-a');
    expect(await baseOf(store), isA<BaseAgrees>());
    switched = true;
    expect(
      await store.record(testAccount, strategyId, [
        const AppRestarted(build: build),
      ]),
      isA<NotSaved<Recorded, CommitRefusal>>(),
    );
    await store.readPage(strategyId, 'page-a');
    final base = await baseOf(store);
    expect(base, isA<BaseRereading>());
    expect(
      (base as BaseRereading).reason,
      contains('ElementTarget(e1) is at 4'),
    );
  });

  test('a read begun before the set-aside is refused after it, and leaves '
      'the retained page row alone', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final storage = MemoryStorage(disk);
    final store = await openCloudStore(MemoryEngine(storage));
    await recordAll(store, [const AppRestarted(build: build)]);
    final before = await beganIn(store);
    await store.readPage(strategyId, 'page-a');
    expect(await baseOf(store), isA<BaseRereading>());
    final recorded = await recordAll(store, [
      BaseArrived(
        const PageGone('page-b'),
        session: await sessionOf(store),
        from: before,
      ),
    ]);
    expect(recorded.outcomes.single, isA<ReportNotApplicable>());
    expect(storage.contents[area]!.containsKey(pageName('page-b')), isTrue);
  });

  test(
    'a page read again is not shown until the whole re-read is done',
    () async {
      final store = await openedAndPaged(await rereadingStorage());
      await arrive(store, headerReadOf(initialRows()));
      await arrive(store, pageReadOf(initialRows(), 'page-a'));
      final page =
          (await store.readPage(strategyId, 'page-a') as Found<PageContent>)
              .value;
      expect(page.content, const ContentNotRead());
      expect(page.elements, isEmpty);
      await arrive(store, pageReadOf(initialRows(), 'page-b'));
      expect(
        (await store.readPage(strategyId, 'page-a') as Found<PageContent>)
            .value
            .content,
        const ContentShown(),
      );
    },
  );

  test(
    'a page of a held strategy cannot be copied, and nothing is queued',
    () async {
      final store = await openedAndPaged(await heldStorage());
      expect(
        await store.commitAs(
          testAccount,
          strategyId,
          pageAdd('copy', 'page-c', copyFrom: 'page-a', sortIndex: 2),
          seen: await seenIn(store),
        ),
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          const CopyNeedsContent('page-a'),
        ),
      );
      expect((await syncOf(store)).queue.entries, isEmpty);
    },
  );

  test(
    'when the owed list lands, queued work written for another life of '
    'the strategy is set aside, and work for the list\'s life stays',
    () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      for (final (id, item) in [('same', 'e1'), ('other', 'e2')]) {
        savedValue(
          await store.commitAs(
            testAccount,
            strategyId,
            movePatch(
              id,
              elementId: item,
              x: 9,
              merge: FieldMerge(fields: ['position']),
            ),
            seen: await seenIn(store),
          ),
        );
      }
      await store.close();
      final disk = editable(storage.contents);
      final other = disk[area]!.keys.firstWhere(
        (key) =>
            key.startsWith('pending/') && disk[area]![key]!.contains('"other"'),
      );
      final entry = json(disk[area]![other]!);
      disk[area]![other] = jsonEncode({
        ...entry,
        'strategyLife': (entry['strategyLife']! as int) - 1000,
      });
      disk[area]![elementName('page-b', 'e3')] = '{"broken":true}';
      store = await openedAndPaged(MemoryStorage(disk));
      expect(await baseOf(store), isA<BaseRereading>());
      await arrive(store, headerReadOf(initialRows()));
      final queue = (await syncOf(store)).queue;
      expect(queue.entries.map((entry) => entry.id), ['same']);
      expect(queue.strategy.setAside.count, 1);
    },
  );

  test('a result older than one already taken loads none of the pages its '
      'items are held on', () async {
    final storage = MemoryStorage(await addedOnDisk());
    final store = await openCloudStore(MemoryEngine(storage));
    await recordAll(store, [const AppRestarted(build: build)]);
    final older = await beganIn(store);
    final newer = await beganIn(store);
    await recordAll(store, [
      BaseArrived(
        pageReadOf(initialRows(), 'page-b'),
        session: await sessionOf(store),
        from: newer,
      ),
    ]);
    await store.close();
    final (engine, counts) = counting(
      MemoryEngine(MemoryStorage(storage.contents)),
    );
    final again = await openCloudStore(engine);
    await recordAll(again, [const AppRestarted(build: build)]);
    final stale = await beganIn(again);
    await recordAll(again, [
      BaseArrived(
        pageReadOf(initialRows(), 'page-b'),
        session: await sessionOf(again),
        from: await beganIn(again),
      ),
    ]);
    counts.reset();
    final moved = movePatch('to-b', pageId: 'page-b', x: 3);
    await again.record(testAccount, strategyId, [
      BaseArrived(
        pageReadOf(withOp(initialRows(), moved), 'page-b'),
        session: await sessionOf(again),
        from: stale,
      ),
    ]);
    expect([
      for (final (_, prefix) in counts.entryListings)
        if (prefix.startsWith('content/')) prefix,
    ], isEmpty);
    expect(older, isNot(newer));
  });

  test('a page a list leaves is checked before the list is applied: a '
      'disagreement on it sets the base aside and the list is dropped behind '
      'the fence', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-b', 'e3')] = jsonEncode({
      ...json(disk[area]![elementName('page-b', 'e3')]!),
      'revision': 4,
    });
    final storage = MemoryStorage(disk);
    final store = await openCloudStore(MemoryEngine(storage));
    await recordAll(store, [const AppRestarted(build: build)]);
    final start = await beganIn(store);
    final recorded = await recordAll(store, [
      BaseArrived(
        headerReadOf(withoutPage(initialRows(), 'page-b')),
        session: await sessionOf(store),
        from: start,
      ),
    ]);
    expect(recorded.outcomes.single, isA<ReportNotApplicable>());
    await expectSetAside(store, storage, 'ElementTarget(e3) is at 4');
  });

  test('the library counts nothing on pages being read again, and counts '
      'them again once the base agrees', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final store = await openCloudStore(MemoryEngine(MemoryStorage(disk)));
    await recordAll(store, [AppRestarted(build: build)]);
    int items(LibraryStore store) => listOf(store).strategies.single.itemCount;
    expect(items(store), 3);
    await store.readPage(strategyId, 'page-a');
    expect(await baseOf(store), isA<BaseRereading>());
    expect(items(store), 0);
    await readAgain(store, initialRows());
    expect(await baseOf(store), isA<BaseAgrees>());
    expect(items(store), 3);
  });

  test('while the list is owed, a trashed page row kept on disk is not '
      'taken into the queue', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
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
    final disk = editable(storage.contents);
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final setAside = MemoryStorage(disk);
    store = await openedAndPaged(setAside);
    expect(await baseOf(store), isA<BaseRereading>());
    await store.close();
    store = await openedAndPaged(MemoryStorage(setAside.contents));
    expect((await syncOf(store)).queue.shown.trashed, isEmpty);
  });

  test(
    'a page list carrying an unreadable trashed page counts it as trashed',
    () {
      final unreadable = UnreadablePage(
        publicId: 'page-b',
        strategyPublicId: strategyId,
        sortIndex: 1,
        trashed: true,
        stored: {'publicId': 'page-b', 'deleted': true, 'revision': 2},
        problem: 'a page from a newer build',
      );
      final shown = Shown.nothing
          .taken(
            HeaderRead(
              strategy: initialRows().strategy,
              pages: [initialRows().page('page-a')!, unreadable],
              settings: initialRows().settings.toList(),
            ),
            started: ReadStart.beforeAnyRead,
          )
          .shown;
      expect(shown.pages.keys, ['page-a']);
      expect(shown.trashed.keys, ['page-b']);
    },
  );
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
