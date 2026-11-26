import 'dart:async';
import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/store/store.dart' show storeWork;
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

  Future<List<int>> serialsReported() async {
    await pumpEventQueue();
    return [for (final refusal in _refusals) refusal.refusal.serial];
  }

  Future<void> close() async {
    await _changes.cancel();
    await store.close();
  }
}

final class ServingAStrayItem extends ForwardingLease {
  ServingAStrayItem(super.inner, this.serving);

  final bool Function() serving;
  static final stray = elementName('page-b', 'stray');

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      switch (await super.keys(area, prefix)) {
        Done(:final value) when serving() && prefix.isEmpty => Done([
          ...value,
          stray,
        ]),
        final other => other,
      };
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
        final before = editable(disk);
        final storage = MemoryStorage(disk);
        final opened = await Opened.over(storage);
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
        expect(opened.counts.commits, 0);
        expect(storage.contents, before);
        expect(await opened.refusalsReported(), [contains(reason)]);
        await opened.close();

        final untouched = editable(storage.contents);
        final again = await Opened.over(MemoryStorage(untouched));
        await readEveryPage(again.store);
        await expectRefused(again.store, reason);
        expect(again.counts.commits, 0);
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
    final before = editable(disk);
    Map<String, String> queued(Contents contents) => {
      for (final MapEntry(:key, :value) in contents[area]!.entries)
        if (key.startsWith('pending/') || key.startsWith('landed/')) key: value,
    };
    expect(queued(before), isNotEmpty);
    final damaged = MemoryStorage(disk);
    final opened = await Opened.over(damaged);
    store = opened.store;
    await readEveryPage(store);
    expect(await refusedFor(store), isNotNull);
    expect(opened.counts.commits, 0);
    expect(queued(damaged.contents), queued(before));
    expect(
      await store.record(testAccount, strategyId, [
        BatchClaimed(clientId: clientId, opIds: ['kept'], at: fixedClock()),
      ]),
      isA<Refused<Recorded, CommitRefusal>>(),
    );
    expect(opened.counts.commits, 0);
    expect(queued(damaged.contents), queued(before));
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
    expect(opened.counts.commits, 0);
    expect(damaged.contents, before);
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

    test('by an explicit summary rebuild is refused, the saved summary is '
        'not rewritten, and it is reported once', () async {
      final (opened, storage) = await damagedOnA();
      final before = editable(storage.contents);
      final listed = listOf(opened.store).strategies.single.toJson();
      expect(
        await opened.store.rebuildSummary(strategyId),
        isA<Refused<StrategySummary, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<StoredRowsDisagree>(),
        ),
      );
      expect(storage.contents, before);
      expect(
        storage.contents['library']![summaryName(strategyId)],
        before['library']![summaryName(strategyId)],
      );
      expect(listOf(opened.store).strategies.single.toJson(), listed);
      expect(await opened.refusalsReported(), hasLength(1));
    });

    test('a batch with a result for a healthy page before one for the '
        'damaged page is refused whole, with nothing written', () async {
      final (opened, storage) = await damagedOnA();
      final session = await sessionOf(opened.store);
      final from = await beganIn(opened.store);
      final before = editable(storage.contents);
      final commits = opened.counts.commits;
      final changedB = initialRows().withRows([
        element('e3', pageId: 'page-b', revision: 2, sortIndex: 5),
      ]);
      expect(
        await opened.store.record(testAccount, strategyId, [
          BaseArrived(
            pageReadOf(changedB, 'page-b'),
            session: session,
            from: from,
          ),
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
      expect(opened.counts.commits, commits);
      expect(storage.contents, before);
    });

    test('a refused strategy shows nothing, not even a healthy page, and '
        'copying a healthy page is refused with nothing written', () async {
      final (opened, storage) = await damagedOnA();
      final seen = await seenIn(opened.store);
      expect(
        await opened.store.readPage(strategyId, 'page-b'),
        isA<Found<PageContent>>(),
      );
      expect(
        await opened.store.readPage(strategyId, 'page-a'),
        isA<InUnreadableStrategy<PageContent>>(),
      );
      expect(
        await opened.store.readPage(strategyId, 'page-b'),
        isA<InUnreadableStrategy<PageContent>>(),
      );
      final before = editable(storage.contents);
      final commits = opened.counts.commits;
      expect(
        await opened.store.commitAs(
          testAccount,
          strategyId,
          pageAdd('copy', 'page-c', copyFrom: 'page-b'),
          seen: seen,
        ),
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<StoredRowsDisagree>(),
        ),
      );
      expect(opened.counts.commits, commits);
      expect(storage.contents, before);
    });
  });

  test('in release builds a stored item with other contents at the version '
      'the queue holds is accepted when an unchanged result arrives: the '
      'stored copy stays and nothing is refused', () async {
    final checked = shownTakesChecked;
    shownTakesChecked = false;
    addTearDown(() => shownTakesChecked = checked);
    final disk = await addedOnDisk();
    final changed = jsonEncode({
      ...json(disk[area]![elementName('page-a', 'e1')]!),
      'sortIndex': 99,
    });
    disk[area]![elementName('page-a', 'e1')] = changed;
    final storage = MemoryStorage(disk);
    final opened = await Opened.over(storage);
    await recordAll(opened.store, [const AppRestarted(build: build)]);
    expect(
      await arriving(opened.store, pageReadOf(initialRows(), 'page-a')),
      isA<Saved<Recorded, CommitRefusal>>(),
    );
    expect(storage.contents[area]![elementName('page-a', 'e1')], changed);
    expect(await refusedFor(opened.store), isNull);
    expect(await opened.refusalsReported(), isEmpty);
  });

  test('a result older than one already taken for its page is dropped before '
      'the page is read again', () async {
    final storage = MemoryStorage(await addedOnDisk());
    final opened = await Opened.over(storage);
    await recordAll(opened.store, [const AppRestarted(build: build)]);
    final session = await sessionOf(opened.store);
    final older = await beganIn(opened.store);
    final newer = await beganIn(opened.store);
    await recordAll(opened.store, [
      BaseArrived(
        pageReadOf(initialRows(), 'page-a'),
        session: session,
        from: newer,
      ),
    ]);
    expect(await opened.store.unload(strategyId), isA<Unloaded>());
    final listings = opened.counts.entryListings.length;
    final commits = opened.counts.commits;
    final recorded = await opened.store.record(testAccount, strategyId, [
      BaseArrived(
        pageReadOf(initialRows(), 'page-a'),
        session: session,
        from: older,
      ),
    ]);
    expect([
      for (final (_, prefix) in opened.counts.entryListings.skip(listings))
        if (prefix.startsWith('content/')) prefix,
    ], isEmpty);
    expect(opened.counts.commits, commits);
    expect(
      savedValue(recorded).outcomes.single,
      isA<ReportNotApplicable>().having(
        (outcome) => outcome.why,
        'why',
        isA<OlderResult>(),
      ),
    );
  });

  test(
    'an item on a page that went is taken once when a later result '
    'carries it on a surviving page, and the live store equals a reopen',
    () async {
      final storage = MemoryStorage(await addedOnDisk());
      var store = await openCloudStore(MemoryEngine(storage));
      await recordAll(store, [const AppRestarted(build: build)]);
      await arrive(store, const PageGone('page-b'));
      final moved = initialRows().withRows([element('e3', revision: 2)]);
      await arrive(store, pageReadOf(moved, 'page-a'));
      List<String> onA(PageContent page) =>
          [for (final row in page.elements) row.publicId]..sort();
      final live = onA(pageOf(await store.readPage(strategyId, 'page-a')));
      expect(live.where((id) => id == 'e3'), hasLength(1));
      await expectAgree(store);
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      expect(onA(pageOf(await store.readPage(strategyId, 'page-a'))), live);
    },
  );

  test('an unknown-kind row on a cached page is gone from the next read and '
      'from disk once a full result for the page leaves it out', () async {
    final disk = await addedOnDisk();
    final key = 'content/${digestOf('page-a')}/z/${digestOf('x')}';
    disk[area]![key] = '{"kind":"from a newer build"}';
    final storage = MemoryStorage(disk);
    final store = await openCloudStore(MemoryEngine(storage));
    await recordAll(store, [const AppRestarted(build: build)]);
    expect(
      pageOf(await store.readPage(strategyId, 'page-a')).unknownKinds,
      isNotEmpty,
    );
    await arrive(store, pageReadOf(initialRows(), 'page-a'));
    expect(
      pageOf(await store.readPage(strategyId, 'page-a')).unknownKinds,
      isEmpty,
    );
    expect(storage.contents[area]!.containsKey(key), isFalse);
  });

  test('a page list leaving out a page the queue holds emits UnlistedLeft '
      'with exactly the pages it lists', () {
    final shown = Shown.nothing
        .taken(headerReadOf(initialRows()), started: ReadStart.beforeAnyRead)
        .shown;
    final taken = shown.taken(
      headerReadOf(
        StrategyRowSet(
          strategy: initialRows().strategy,
          pages: [initialRows().page('page-a')!],
          settings: [
            for (final row in initialRows().settings)
              if (row.pagePublicId == 'page-a') row,
          ],
        ),
      ),
      started: ReadStart.beforeAnyRead,
    );
    expect(
      taken.decisions.whereType<UnlistedLeft>().map((left) => left.listed),
      [
        {'page-a'},
      ],
    );
  });

  group('damaged rows main tolerated are now refused, and stay on disk', () {
    Future<(Opened, MemoryStorage, Contents)> withDamaged(
      void Function(Contents disk) damage,
    ) async {
      final disk = await addedOnDisk();
      damage(disk);
      final before = editable(disk);
      final storage = MemoryStorage(disk);
      return (await Opened.over(storage), storage, before);
    }

    LiveElement repairedE9() => LiveElement(
      publicId: 'e9',
      pagePublicId: 'page-a',
      payload: agentPayload('e9', const {}),
      sortIndex: 0,
      revision: 1,
      unknownFields: jsonObject({'createdAt': fixtureLife}),
    );

    test('a damaged extra item, repaired and then removed by two results in '
        'one call', () async {
      final key = elementName('page-a', 'e9');
      final (opened, storage, before) = await withDamaged(
        (disk) => disk[area]![key] = '{"broken":true}',
      );
      expect(
        await opened.store.record(testAccount, strategyId, [
          BaseArrived(
            pageReadOf(initialRows().withRows([repairedE9()]), 'page-a'),
            session: 1,
            from: const LiveResult(),
          ),
          BaseArrived(
            pageReadOf(initialRows(), 'page-a'),
            session: 1,
            from: const LiveResult(),
          ),
        ]),
        isA<Refused<Recorded, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<StoredRowsDisagree>(),
        ),
      );
      expect(opened.counts.commits, 0);
      expect(storage.contents, before);
      expect(storage.contents[area]![key], '{"broken":true}');
    });

    test('a damaged extra item that a full page result leaves out', () async {
      final key = elementName('page-a', 'e9');
      final (opened, storage, before) = await withDamaged(
        (disk) => disk[area]![key] = '{"broken":true}',
      );
      expect(
        await opened.store.record(testAccount, strategyId, [
          BaseArrived(
            pageReadOf(initialRows(), 'page-a'),
            session: 1,
            from: const LiveResult(),
          ),
        ]),
        isA<Refused<Recorded, CommitRefusal>>(),
      );
      expect(opened.counts.commits, 0);
      expect(storage.contents, before);
    });

    test('a page that goes, with an unreadable settings row', () async {
      final key = settingsName('page-b');
      final (opened, storage, before) = await withDamaged(
        (disk) => disk[area]![key] = '{"broken":true}',
      );
      expect(
        await opened.store.record(testAccount, strategyId, [
          const BaseArrived(PageGone('page-b'), session: 1, from: LiveResult()),
        ]),
        isA<Refused<Recorded, CommitRefusal>>(),
      );
      expect(
        await refusedFor(opened.store),
        'a page or settings row is damaged here',
      );
      expect(opened.counts.commits, 0);
      expect(storage.contents, before);
    });
  });

  test('once refused, a record is answered from the remembered refusal '
      'without touching disk', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
    final opened = await Opened.over(MemoryStorage(disk));
    await readEveryPage(opened.store);
    expect(await refusedFor(opened.store), isNotNull);
    final counts = opened.counts;
    final touched = (
      counts.reads.length,
      counts.keyListings.length,
      counts.entryListings.length,
      counts.commits,
    );
    expect(
      await opened.store.record(testAccount, strategyId, const [
        ConnectionReturned(),
      ]),
      isA<Refused<Recorded, CommitRefusal>>(),
    );
    expect((
      counts.reads.length,
      counts.keyListings.length,
      counts.entryListings.length,
      counts.commits,
    ), touched);
  });

  group('the store\'s own guards', () {
    test('a damaged page is never admitted to memory; the strategy and its '
        'queue leave memory when a batch fails part way', () async {
      final disk = await addedOnDisk();
      disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
      final store = await openCloudStore(MemoryEngine(MemoryStorage(disk)));
      await recordAll(store, [const AppRestarted(build: build)]);
      final session = await sessionOf(store);
      final from = await beganIn(store);
      storeWork.reset();
      expect(
        await store.readPage(strategyId, 'page-b'),
        isA<Found<PageContent>>(),
      );
      expect(storeWork.cloudPagesAdmitted, 1);
      expect(storeWork.strategiesInMemory(), contains(digestOf(strategyId)));
      expect(
        await store.record(testAccount, strategyId, [
          BaseArrived(
            pageReadOf(
              initialRows().withRows([
                element('e3', pageId: 'page-b', revision: 2),
              ]),
              'page-b',
            ),
            session: session,
            from: from,
          ),
          BaseArrived(
            pageReadOf(initialRows(), 'page-a'),
            session: session,
            from: from,
          ),
        ]),
        isA<Refused<Recorded, CommitRefusal>>(),
      );
      expect(storeWork.cloudPagesAdmitted, 1);
      expect(
        storeWork.strategiesInMemory(),
        isNot(contains(digestOf(strategyId))),
      );
      expect(storeWork.queuesInMemory(), isNot(contains(digestOf(strategyId))));
    });

    test('a refusal remembered for a page does not skip the queue-load '
        'check: a fault found there later is reported as its own', () async {
      final disk = await addedOnDisk();
      disk[area]![elementName('page-a', 'e1')] = '{"broken":true}';
      var stray = false;
      final store = await openCloudStore(
        WrappingEngine(
          MemoryEngine(MemoryStorage(disk)),
          (lease) => ServingAStrayItem(lease, () => stray),
        ),
      );
      final refusals = <StoredRowsDisagree>[];
      final listening = store.changes.listen((change) {
        if (change is StrategyRefused) refusals.add(change.refusal);
      });
      addTearDown(listening.cancel);
      await store.readPage(strategyId, 'page-a');
      stray = true;
      expect(
        await store.rebuildSummary(strategyId),
        isA<Refused<StrategySummary, CommitRefusal>>(),
      );
      await pumpEventQueue();
      expect(
        [for (final refusal in refusals) refusal.reason],
        [
          'a row on page page-a is damaged here',
          'an item is held here that the queue does not hold',
        ],
      );
      expect(refusals.first.serial, isNot(refusals.last.serial));
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

  test('a fault found at queue load refuses an explicit summary rebuild, '
      'rewrites nothing and is reported once', () async {
    final disk = await addedOnDisk();
    disk[area]!.remove(settingsName('page-a'));
    final storage = MemoryStorage(disk);
    final opened = await Opened.over(storage);
    final before = editable(storage.contents);
    expect(
      await opened.store.rebuildSummary(strategyId),
      isA<Refused<StrategySummary, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<StoredRowsDisagree>(),
      ),
    );
    expect(storage.contents, before);
    expect(await opened.refusalsReported(), hasLength(1));
  });

  test('a strategy refused, removed, added again and refused again for the '
      'same reason is reported again', () async {
    final odd = initialRows().withRows([
      LiveElement(
        publicId: 'e2',
        pagePublicId: 'page-a',
        payload: agentPayload('e2', const {}),
        sortIndex: 0,
        revision: 1,
        unknownFields: jsonObject(const {
          'createdAt': fixtureLife,
          'note': 'not what the store holds',
        }),
      ),
    ]);
    final opened = await Opened.over(MemoryStorage());
    for (var round = 0; round < 2; round++) {
      await addCloud(opened.store, initialRows());
      await recordAll(opened.store, [const AppRestarted(build: build)]);
      expect(
        await arriving(opened.store, pageReadOf(odd, 'page-a')),
        isA<Refused<Recorded, CommitRefusal>>(),
      );
      savedValue(
        await opened.store.editLibrary([const RemoveStrategy(strategyId)]),
      );
    }
    final reasons = await opened.refusalsReported();
    expect(reasons, hasLength(2));
    expect(reasons.toSet(), hasLength(1));
    final serials = await opened.serialsReported();
    expect(serials.toSet(), hasLength(2));
    expect(serials.first, lessThan(serials.last));
  });

  test('a strategy whose queue cannot be read shows its rows unchecked and '
      'held, and makes no decision: no result is taken and no work is '
      'committed', () async {
    final disk = await addedOnDisk();
    disk[area]![elementName('page-a', 'e1')] = revised(
      disk[area]![elementName('page-a', 'e1')]!,
      4,
    );
    disk[area]!['pending/999'] = 'not a queue row';
    final storage = MemoryStorage(disk);
    final store = await openCloudStore(MemoryEngine(storage));
    final page = await store.readPage(strategyId, 'page-a');
    expect(
      page,
      isA<Found<PageContent>>().having(
        (found) => found.value.sync,
        'sync',
        isA<CloudHeld>(),
      ),
    );
    final seen = await seenIn(store);
    final before = editable(storage.contents);
    expect(
      await store.record(testAccount, strategyId, [
        BaseArrived(
          pageReadOf(initialRows(), 'page-a'),
          session: 1,
          from: const LiveResult(),
        ),
      ]),
      isA<Refused<Recorded, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<QueueHeld>(),
      ),
    );
    expect(
      await store.commitAs(
        testAccount,
        strategyId,
        movePatch('held', x: 10),
        seen: seen,
      ),
      isA<Refused<Committed, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<QueueHeld>(),
      ),
    );
    expect(storage.contents, before);
  });

  test('in checked builds, a result whose item differs at the same version '
      'from what this run digested refuses the strategy instead of throwing, '
      'and nothing is written', () async {
    final storage = MemoryStorage();
    final opened = await Opened.over(storage);
    await addCloud(opened.store, initialRows());
    await recordAll(opened.store, [const AppRestarted(build: build)]);
    final session = await sessionOf(opened.store);
    final from = await beganIn(opened.store);
    final before = editable(storage.contents);
    final odd = initialRows().withRows([
      LiveElement(
        publicId: 'e2',
        pagePublicId: 'page-a',
        payload: agentPayload('e2', const {
          'position': {'dx': 7, 'dy': 0},
        }),
        sortIndex: 0,
        revision: (initialRows().element('e2')! as LiveElement).revision,
        unknownFields: jsonObject(const {'createdAt': fixtureLife}),
      ),
    ]);
    expect(
      await opened.store.record(testAccount, strategyId, [
        BaseArrived(pageReadOf(odd, 'page-a'), session: session, from: from),
      ]),
      isA<Refused<Recorded, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<StoredRowsDisagree>(),
      ),
    );
    expect(storage.contents, before);
    expect(await opened.refusalsReported(), [
      contains('carries other contents than this run digested'),
    ]);
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
