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

Map<String, Object?> json(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String movedTo(String stored, String page) =>
    jsonEncode({...json(stored), 'pagePublicId': page});

String revised(String stored, int revision) =>
    jsonEncode({...json(stored), 'revision': revision});

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

final class Opened {
  Opened._(this.store, this.counts) {
    _changes = store.changes.listen((change) {
      if (change is StrategyRefused) _refusals.add(change);
    });
  }

  static Future<Opened> over(MemoryStorage storage) async {
    final (engine, counts) = counting(MemoryEngine(storage));
    return Opened._(await openCloudStore(engine), counts);
  }

  final LibraryStore store;
  final Counts counts;
  late final StreamSubscription<StoreChange> _changes;
  final _refusals = <StrategyRefused>[];

  Future<List<String>> refusalsReported() async {
    await pumpEventQueue();
    return [for (final refusal in _refusals) refusal.refusal.reason];
  }

  Future<void> close() async {
    await _changes.cancel();
    await store.close();
  }
}

Future<RecordResult> arriving(LibraryStore store, ArrivedBase base) async =>
    store.record(testAccount, strategyId, [
      BaseArrived(
        base,
        session: await sessionOf(store),
        from: await beganIn(store),
      ),
    ]);

Future<void> readEveryPage(LibraryStore store) async {
  for (final page in ['page-a', 'page-b']) {
    await store.readPage(strategyId, page);
  }
}

Future<void> expectRefused(LibraryStore store, String reason) async {
  expect(await refusedFor(store), contains(reason));
  expect(
    await store.readPage(strategyId, 'page-a'),
    isA<InUnreadableStrategy<PageContent>>(),
  );
  expect(
    await store.record(testAccount, strategyId, const [ConnectionReturned()]),
    isA<Refused<Recorded, CommitRefusal>>().having(
      (refused) => refused.reason,
      'reason',
      isA<StoredRowsDisagree>(),
    ),
  );
}

final seeds = <String, (String, void Function(Contents disk))>{
  'the strategy row at another version': (
    'the strategy row is at',
    (disk) => disk[area]!['strategy'] = revised(disk[area]!['strategy']!, 9),
  ),
  'a damaged page row': (
    'a page or settings row is damaged here',
    (disk) => disk[area]![pageName('page-b')] = '{"broken":true}',
  ),
  'a page trashed here with only deleted changed': (
    'page page-b is live in the queue and not here',
    (disk) => disk[area]![pageName('page-b')] = jsonEncode({
      ...json(disk[area]![pageName('page-b')]!),
      'deleted': true,
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
  'the only copy of an item on another page': (
    'on another page than in the queue, or on more than one',
    (disk) {
      final stored = disk[area]!.remove(elementName('page-a', 'e1'))!;
      disk[area]![elementName('page-b', 'e1')] = movedTo(stored, 'page-b');
    },
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
  'a placed item whose revision cannot be read': (
    'ElementTarget(e1) is at null',
    (disk) => disk[area]![elementName('page-a', 'e1')] = jsonEncode({
      for (final MapEntry(:key, :value) in json(
        disk[area]![elementName('page-a', 'e1')]!,
      ).entries)
        if (key != 'revision') key: value,
    }),
  ),
  'a settings row on the wrong page with the count unchanged': (
    'the settings of page page-a are at null here',
    (disk) {
      disk[area]!.remove(settingsName('page-b'));
      dropFromHeader(disk, 'page-b', ['settings']);
      final moved = disk[area]!.remove(settingsName('page-a'))!;
      disk[area]![settingsName('page-b')] = jsonEncode({
        ...json(moved),
        'pagePublicId': 'page-b',
      });
    },
  ),
};

void main() {
  group('the line between agreeing and disagreeing', () {
    test('a store that agrees opens, pages through and takes a result with '
        'no refusal and no commit but the result', () async {
      final opened = await Opened.over(MemoryStorage(await addedOnDisk()));
      await readEveryPage(opened.store);
      expect(opened.counts.commits, 0);
      expect(await refusedFor(opened.store), isNull);
      await recordAll(opened.store, [const AppRestarted(build: build)]);
      expect(
        await arriving(opened.store, pageReadOf(initialRows(), 'page-a')),
        isA<Saved<Recorded, CommitRefusal>>(),
      );
      expect(await opened.refusalsReported(), isEmpty);
      await expectAgree(opened.store);
    });

    test('a row this build cannot read agrees when its name and version '
        'match', () async {
      final rows = initialRows().withRows([fromANewerBuild('e9')]);
      final opened = await Opened.over(MemoryStorage(await addedOnDisk(rows)));
      await readEveryPage(opened.store);
      expect(await refusedFor(opened.store), isNull);
      await expectAgree(opened.store);
    });

    test('a row of a kind this build does not know is left out', () async {
      final disk = await addedOnDisk();
      disk[area]!['content/${digestOf('page-a')}/z/${digestOf('x')}'] =
          '{"kind":"from a newer build"}';
      final opened = await Opened.over(MemoryStorage(disk));
      await readEveryPage(opened.store);
      expect(await refusedFor(opened.store), isNull);
    });

    test('the strategy row is compared by version only', () async {
      final renamed = await addedOnDisk();
      renamed[area]!['strategy'] = jsonEncode({
        ...json(renamed[area]!['strategy']!),
        'name': 'Renamed here',
      });
      final opened = await Opened.over(MemoryStorage(renamed));
      await readEveryPage(opened.store);
      expect(await refusedFor(opened.store), isNull);
    });
  });

  group('each disagreement, seeded alone, refuses the strategy: nothing is '
      'written, a result is not taken, and it is reported once', () {
    for (final MapEntry(key: what, value: (reason, seed)) in seeds.entries) {
      test(what, () async {
        final disk = await addedOnDisk(
          strategyRows(
            pageSettings: [settings('page-a'), settings('page-b')],
            elements: initialRows().elements.toList(),
          ),
        );
        seed(disk);
        final storage = MemoryStorage(disk);
        final opened = await Opened.over(storage);
        await opened.store.record(testAccount, strategyId, const [
          AppRestarted(build: build),
        ]);
        final before = editable(storage.contents);
        await readEveryPage(opened.store);
        await expectRefused(opened.store, reason);
        expect(
          await opened.store.record(testAccount, strategyId, [
            BaseArrived(
              pageReadOf(initialRows(), 'page-b'),
              session: 1,
              from: const LiveResult(),
            ),
          ]),
          isA<Refused<Recorded, CommitRefusal>>(),
        );
        expect(storage.contents, before);
        expect(await opened.refusalsReported(), [contains(reason)]);
        await opened.close();

        final again = await Opened.over(MemoryStorage(storage.contents));
        await readEveryPage(again.store);
        await expectRefused(again.store, reason);
        expect(await again.refusalsReported(), [contains(reason)]);
      });
    }
  });

  test('in checked builds, an item with other contents here at the version '
      'the queue holds refuses the strategy when a result the queue finds '
      'unchanged arrives for it, and nothing is written', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = jsonEncode({
      ...json(disk[area]![elementName('page-a', 'e1')]!),
      'sortIndex': 99,
    });
    final storage = MemoryStorage(disk);
    final opened = await Opened.over(storage);
    await recordAll(opened.store, [const AppRestarted(build: build)]);
    final before = editable(storage.contents);
    expect(
      await arriving(opened.store, pageReadOf(initialRows(), 'page-a')),
      isA<Refused<Recorded, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<StoredRowsDisagree>(),
      ),
    );
    expect(storage.contents, before);
    await expectRefused(opened.store, 'holds other contents here');
    expect(await opened.refusalsReported(), hasLength(1));
  });

  test('a result from a source this mode does not take loads no page, even '
      'one that would disagree', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final opened = await Opened.over(MemoryStorage(disk));
    await recordAll(opened.store, [const AppRestarted(build: build)]);
    final session = await sessionOf(opened.store);
    final listingsBefore = [...opened.counts.entryListings];
    final recorded = await opened.store.record(testAccount, strategyId, [
      BaseArrived(
        pageReadOf(initialRows(), 'page-a'),
        session: session,
        from: const LiveResult(),
      ),
    ]);
    final contentListed = [
      for (final (_, prefix) in opened.counts.entryListings.skip(
        listingsBefore.length,
      ))
        if (prefix.startsWith('content/')) prefix,
    ];
    expect(contentListed, isEmpty);
    expect(
      savedValue(recorded).outcomes.single,
      isA<ReportNotApplicable>().having(
        (outcome) => outcome.why,
        'why',
        isA<NotThisModesResults>(),
      ),
    );
    expect(await opened.refusalsReported(), isEmpty);
  });

  test('work the user queued stays on disk as it was and is not sent, and '
      'new work is refused', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    final seen = await seenIn(store);
    savedValue(
      await store.commitAs(
        testAccount,
        strategyId,
        movePatch('kept', x: 90, merge: FieldMerge(fields: ['position'])),
        seen: seen,
      ),
    );
    await store.close();
    final disk = editable(storage.contents);
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final damaged = MemoryStorage(disk);
    store = await openCloudStore(MemoryEngine(damaged));
    await readEveryPage(store);
    final before = editable(damaged.contents);
    expect(
      await store.record(testAccount, strategyId, [
        BatchClaimed(clientId: clientId, opIds: ['kept'], at: fixedClock()),
      ]),
      isA<Refused<Recorded, CommitRefusal>>(),
    );
    expect(
      await store.commitAs(
        testAccount,
        strategyId,
        movePatch('more', x: 10),
        seen: seen,
      ),
      isA<Refused<Committed, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<StoredRowsDisagree>(),
      ),
    );
    expect(damaged.contents, before);
    expect([
      for (final key in damaged.contents[area]!.keys)
        if (key.startsWith('pending/')) key,
    ], isNotEmpty);
  });

  group('a disagreement found at a page load in the middle of a session', () {
    Future<(Opened, MemoryStorage)> damagedOnA() async {
      final disk = await addedOnDisk();
      disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
      final storage = MemoryStorage(disk);
      final opened = await Opened.over(storage);
      await recordAll(opened.store, [const AppRestarted(build: build)]);
      expect(await refusedFor(opened.store), isNull);
      return (opened, storage);
    }

    test('by the reader refuses the strategy from then on, and a result '
        'begun before it is not taken', () async {
      final (opened, storage) = await damagedOnA();
      final store = opened.store;
      final session = await sessionOf(store);
      final began = await beganIn(store);
      expect(
        await store.readPage(strategyId, 'page-b'),
        isA<Found<PageContent>>(),
      );
      expect(
        await store.readPage(strategyId, 'page-a'),
        isA<InUnreadableStrategy<PageContent>>(),
      );
      final before = editable(storage.contents);
      expect(
        await store.record(testAccount, strategyId, [
          BaseArrived(
            pageReadOf(initialRows(), 'page-b'),
            session: session,
            from: began,
          ),
        ]),
        isA<Refused<Recorded, CommitRefusal>>(),
      );
      expect(storage.contents, before);
      await expectRefused(store, 'a row on page page-a is damaged here');
      expect(await store.unload(strategyId), isA<Unloaded>());
      await expectRefused(store, 'a row on page page-a is damaged here');
      expect(await opened.refusalsReported(), hasLength(1));
    });

    final throughDecisions = <String, ArrivedBase Function()>{
      'a page result for the page': () => pageReadOf(initialRows(), 'page-a'),
      'a page result that moves an item from the page': () => pageReadOf(
        withOp(initialRows(), movePatch('to-b', pageId: 'page-b', x: 40)),
        'page-b',
      ),
      'a page list that no longer lists the page': () => headerReadOf(
        StrategyRowSet(
          strategy: initialRows().strategy,
          pages: [initialRows().page('page-b')!],
          settings: [
            for (final row in initialRows().settings)
              if (row.pagePublicId != 'page-a') row,
          ],
        ),
      ),
      'the page gone': () => const PageGone('page-a'),
      'a page list of a later strategy life': () => headerReadOf(
        StrategyRowSet(
          strategy: strategyRow(
            createdAt: strategyCreatedAt.add(const Duration(seconds: 1)),
          ),
          pages: initialRows().pages,
          settings: initialRows().settings,
        ),
      ),
    };
    for (final MapEntry(key: what, value: base) in throughDecisions.entries) {
      test('by $what is not taken, and nothing is written', () async {
        final (opened, storage) = await damagedOnA();
        final before = editable(storage.contents);
        expect(
          await arriving(opened.store, base()),
          isA<Refused<Recorded, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<StoredRowsDisagree>(),
          ),
        );
        expect(storage.contents, before);
        await expectRefused(opened.store, 'a row on page page-a is damaged');
      });
    }

    test('by a summary rebuild lists it held, counting nothing it did not '
        'check', () async {
      final (opened, storage) = await damagedOnA();
      final before = editable(storage.contents);
      await opened.store.rebuildSummary(strategyId);
      final listed = listOf(opened.store).strategies.single;
      expect(listed.sync, isA<KeptInCloud>());
      expect(await refusedFor(opened.store), contains('page-a'));
      expect(
        [
          for (final key in storage.contents[area]!.keys)
            if (!key.startsWith('summary')) key,
        ],
        [
          for (final key in before[area]!.keys)
            if (!key.startsWith('summary')) key,
        ],
      );
    });
  });

  test('after a restart the open passes the queue-load check, and the '
      'strategy is refused again when a result first loads the bad page, with '
      'nothing written', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final storage = MemoryStorage(disk);
    final first = await Opened.over(storage);
    await readEveryPage(first.store);
    expect(await refusedFor(first.store), isNotNull);
    await first.close();

    final again = await Opened.over(MemoryStorage(storage.contents));
    await recordAll(again.store, [const AppRestarted(build: build)]);
    expect(await refusedFor(again.store), isNull);
    final session = await sessionOf(again.store);
    final from = await beganIn(again.store);
    final commits = again.counts.commits;
    expect(
      await again.store.record(testAccount, strategyId, [
        BaseArrived(
          pageReadOf(initialRows(), 'page-a'),
          session: session,
          from: from,
        ),
      ]),
      isA<Refused<Recorded, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<StoredRowsDisagree>(),
      ),
    );
    expect(again.counts.commits, commits);
    expect(
      await refusedFor(again.store),
      'a row on page page-a is damaged here',
    );
    expect(await again.refusalsReported(), hasLength(1));
  });

  test('a strategy refused this session, removed and added again is not '
      'refused', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final opened = await Opened.over(MemoryStorage(disk));
    await readEveryPage(opened.store);
    expect(await refusedFor(opened.store), isNotNull);
    savedValue(
      await opened.store.editLibrary([const RemoveStrategy(strategyId)]),
    );
    await addCloud(opened.store, initialRows());
    await readEveryPage(opened.store);
    expect(await refusedFor(opened.store), isNull);
    await expectAgree(opened.store);
  });

  test('a store an earlier head of this branch left reading the base again '
      'opens: its queue reads, and the strategy is refused', () async {
    final disk = await addedOnDisk();
    disk[area]!['cloud'] = jsonEncode({
      ...json(disk[area]!['cloud']!),
      'base': {
        'state': 'rereading',
        'reason': 'a row on page page-a is damaged here',
        'tried': ['5.2.1+112'],
      },
    });
    disk[area]!.removeWhere(
      (key, _) => key.startsWith('read/') || key.startsWith('content/'),
    );
    final opened = await Opened.over(MemoryStorage(disk));
    expect(
      await opened.store.readStrategy(strategyId),
      isA<InUnreadableStrategy<StrategyContent>>().having(
        (refused) => refused.listing.refused,
        'refused',
        isA<StoredRowsDisagree>(),
      ),
    );
  });
}
