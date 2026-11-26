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

Future<Contents> addedOnDisk([StrategyRowSet? rows]) async {
  final storage = MemoryStorage();
  final store = await openCloudStore(MemoryEngine(storage));
  await addCloud(store, rows ?? initialRows());
  await store.close();
  return editable(storage.contents);
}

Map<String, Object?> json(String text) =>
    jsonDecode(text) as Map<String, Object?>;

Future<BaseState> baseOf(LibraryStore store) async =>
    (await syncOf(store)).queue.strategy.base;

Future<LibraryStore> openedAndPaged(
  MemoryStorage storage, {
  String build = build,
}) async {
  final store = await openCloudStore(MemoryEngine(storage), build: build);
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
      final store = await openedAndPaged(MemoryStorage(disk));
      expect(await baseOf(store), isA<BaseRereading>());
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
          'revision': 5,
        });
        final store = await openedAndPaged(MemoryStorage(disk));
        expect(await baseOf(store), isA<BaseRereading>());
      },
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
      'a page the queue holds with no stored row': (
        'page page-b is live in the queue and not here',
        (disk) => disk[area]!
          ..remove(pageName('page-b'))
          ..remove(settingsName('page-b')),
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
        expect((base as BaseRereading).build, build);
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

  group('a base that still disagrees after it was read again', () {
    test('is held: no second set-aside by the same build, pages are not '
        'shown, results are still taken', () async {
      final disk = await addedOnDisk();
      disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
      final storage = MemoryStorage(disk);
      var store = await openedAndPaged(storage);
      await arrive(store, headerReadOf(initialRows()));
      await arrive(store, pageReadOf(initialRows(), 'page-a'));
      await store.close();
      final planted = editable(storage.contents);
      planted[area]![elementName('page-a', 'stray')] = jsonEncode(
        element('stray').toJson(),
      );
      final held = MemoryStorage(planted);
      store = await openCloudStore(MemoryEngine(held));
      await recordAll(store, [const AppRestarted(build: build)]);
      await arrive(store, headerReadOf(initialRows()));
      await arrive(store, pageReadOf(initialRows(), 'page-a'));
      await arrive(store, pageReadOf(initialRows(), 'page-b'));
      final base = await baseOf(store);
      expect(base, isA<BaseDisagreesAfterRereading>());
      expect((base as BaseDisagreesAfterRereading).build, build);
      expect(
        (await store.readPage(strategyId, 'page-a') as Found<PageContent>)
            .value
            .content,
        const ContentNotRead(),
      );
      await store.close();

      store = await openedAndPaged(MemoryStorage(held.contents));
      expect(await baseOf(store), isA<BaseDisagreesAfterRereading>());
      expect((await syncOf(store)).queue.shown.rows, isNotEmpty);
      savedValue(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('held', x: 15, merge: FieldMerge(fields: ['position'])),
          seen: await seenIn(store),
        ),
      );
      await recordAll(store, [const ConnectionReturned()]);
      await arrive(store, headerReadOf(initialRows()));
      expect((await claimAll(store)).ops.map((op) => op.opId), ['held']);
      await store.close();

      final fixed = await openedAndPaged(
        MemoryStorage(held.contents),
        build: 'a later build',
      );
      final reread = await baseOf(fixed);
      expect(reread, isA<BaseRereading>());
      expect((reread as BaseRereading).build, 'a later build');
      await readAgain(fixed, initialRows());
      expect(await baseOf(fixed), isA<BaseAgrees>());
      await expectAgree(fixed);
    });
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

  test('a damaged row a full page result removes leaves no item index entry '
      'behind, so the item shows on another page later', () async {
    final first = editable(await addedOnDisk());
    first[area]![elementName('page-b', 'e3')] = '{"broken":true}';
    final rereading = MemoryStorage(first);
    var store = await openedAndPaged(rereading);
    expect(await baseOf(store), isA<BaseRereading>());
    await store.close();
    final planted = editable(rereading.contents);
    planted[area]![elementName('page-a', 'x9')] = '{"broken":true}';
    store = await openCloudStore(MemoryEngine(MemoryStorage(planted)));
    await recordAll(store, [const AppRestarted(build: build)]);
    expect(await baseOf(store), isA<BaseRereading>());
    await arrive(store, headerReadOf(initialRows()));
    await arrive(store, pageReadOf(initialRows(), 'page-a'));
    expect(
      (await store.readPage(strategyId, 'page-a') as Found<PageContent>)
          .value
          .unplaced,
      isEmpty,
    );
    final onB = initialRows().withRows([element('x9', pageId: 'page-b')]);
    await arrive(store, pageReadOf(onB, 'page-b'));
    expect([
      for (final row
          in (await store.readPage(strategyId, 'page-b') as Found<PageContent>)
              .value
              .elements)
        row.publicId,
    ], contains('x9'));
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

  test('a page list removes a stored page it does not list, even one the '
      'queue does not know, while the base is read again', () async {
    final first = editable(await addedOnDisk());
    first[area]![elementName('page-b', 'e3')] = '{"broken":true}';
    final rereading = MemoryStorage(first);
    var store = await openedAndPaged(rereading);
    await store.close();
    final planted = editable(rereading.contents);
    planted[area]![pageName('page-z')] = jsonEncode({
      ...json(planted[area]![pageName('page-b')]!),
      'publicId': 'page-z',
      'sortIndex': 5,
    });
    planted[area]![elementName('page-z', 'z1')] = '{"broken":true}';
    final storage = MemoryStorage(planted);
    store = await openCloudStore(MemoryEngine(storage));
    await recordAll(store, [const AppRestarted(build: build)]);
    expect(await baseOf(store), isA<BaseRereading>());
    await arrive(store, headerReadOf(initialRows()));
    expect(storage.contents[area]!.containsKey(pageName('page-z')), isFalse);
    expect(
      storage.contents[area]!.containsKey(elementName('page-z', 'z1')),
      isFalse,
    );
  });
}
