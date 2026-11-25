import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/store/store.dart' show storeWork;
import 'package:icarus_library/src/cloud/op_facts.dart'
    show liveContentOn, rowDigest;
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

const _items = 300;

StrategyRowSet dense({int round = 0, int changed = 0}) => strategyRows(
  pages: [page('page-a', sortIndex: 0)],
  elements: [
    for (var i = 0; i < _items; i++)
      element(
        'e$i',
        sortIndex: i,
        revision: i < changed ? round + 1 : 1,
        fields: {
          'type': 'jett',
          'position': {'dx': i < changed ? 1000.5 + round : i * 1.5, 'dy': 20},
        },
      ),
  ],
);

StrategyRowSet threePages({int round = 0, int changed = 0}) => strategyRows(
  pages: [
    for (final (index, id) in const ['page-a', 'page-b', 'page-c'].indexed)
      page(id, sortIndex: index),
  ],
  elements: [
    for (final id in const ['page-a', 'page-b', 'page-c'])
      for (var i = 0; i < 100; i++)
        element(
          '$id-e$i',
          pageId: id,
          sortIndex: i,
          revision: id == 'page-b' && i < changed ? round + 1 : 1,
          fields: {
            'position': {
              'dx': id == 'page-b' && i < changed ? 1000.5 + round : i * 1.5,
              'dy': 20,
            },
          },
        ),
  ],
);

Future<void> takePage(
  LibraryStore store,
  StrategyRowSet server, [
  String page = 'page-a',
]) async => recordAll(store, [
  await arrivalIn(store, pageReadOf(server, page)),
]);

Future<Shown> shownIn(LibraryStore store) async =>
    (await syncOf(store)).queue.shown;

Contents olderBuildDigests(Contents contents) {
  String older(String digest) => digest.split('').reversed.join();
  Object? rewritten(Object? group) => switch (group) {
    {'rows': final List<Object?> rows, 'content': final List<Object?>? content}
        when group is Map<String, Object?> =>
      {
        ...group,
        'rows': [
          for (final row in rows)
            if (row case [
              final key,
              final page,
              final revision,
              final String d,
            ])
              [key, page, revision, older(d)]
            else
              row,
        ],
        'content': content == null
            ? null
            : [
                for (final part in content)
                  if (part case [final key, final String d])
                    [key, older(d)]
                  else
                    part,
              ],
      },
    _ => group,
  };
  return {
    for (final MapEntry(key: area, value: keys) in contents.entries)
      area: {
        for (final MapEntry(:key, :value) in keys.entries)
          key: key.contains('read/page/')
              ? jsonEncode(rewritten(jsonDecode(value)))
              : value,
      },
  };
}

Future<LibraryStore> reopened(MemoryStorage storage) async {
  final store = await openCloudStore(MemoryEngine(storage));
  final opened = await recordAll(store, [
    const AppRestarted(build: build),
    reconnected(),
  ]);
  expect(opened.outcomes, everyElement(isA<ReportApplied>()));
  return store;
}

Future<List<Object?>> storedRows(LibraryStore store, String page) async => [
  for (final row in pageOf(await store.readPage(strategyId, page)).elements)
    row.toJson(),
];

Future<List<Object?>> rowsOnDisk(MemoryStorage storage, String page) async {
  final copy = await openCloudStore(
    MemoryEngine(MemoryStorage(editable(storage.contents))),
  );
  final rows = await storedRows(copy, page);
  await copy.close();
  return rows;
}

Contents withOwedReads(Contents contents, Set<String> groups) => {
  for (final MapEntry(key: area, value: keys) in contents.entries)
    area: {
      for (final MapEntry(:key, :value) in keys.entries)
        key: groups.contains(key)
            ? jsonEncode({
                ...(jsonDecode(value) as Map<String, Object?>),
                'read': 'owed',
              })
            : value,
    },
};

String? storedGroup(Contents contents, String group) =>
    [for (final keys in contents.values) ?keys[group]].firstOrNull;

final class RefusingLease extends ForwardingLease {
  RefusingLease(super.inner, this.refusing);

  final bool Function() refusing;

  @override
  Future<Committing> commit(List<Change> changes) async => refusing()
      ? const CommitRefused(DeviceFailure('the write is refused for this test'))
      : super.commit(changes);
}

void main() {
  late bool checked;
  setUp(() => checked = shownTakesChecked);
  tearDown(() => shownTakesChecked = checked);

  group('a page result', () {
    for (final changed in const [1, 10, _items]) {
      test('with $changed of $_items items changed digests and writes '
          '$changed rows', () async {
        shownTakesChecked = false;
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, dense());
        await takePage(store, dense());
        shownWork.reset();
        storeWork.reset();
        await takePage(store, dense(round: 1, changed: changed));
        expect(shownWork.contentRowsDigested, changed);
        expect(storeWork.rowsEncoded, changed);
        expect(storeWork.rowsCompared, changed + 1);
        expect(storeWork.resultGroupsEncoded, 2);
        shownWork.reset();
        storeWork.reset();
        await takePage(store, dense(round: 1, changed: changed));
        expect(shownWork.contentRowsDigested, 0);
        expect(storeWork.rowsEncoded, 0);
        expect(storeWork.rowsCompared, 1);
        expect(storeWork.resultGroupsEncoded, 0);
      });
    }

    test('on one page of three encodes the page list\'s results and that '
        'page\'s, and leaves the other pages\' as stored', () async {
      shownTakesChecked = false;
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, threePages());
      for (final page in const ['page-a', 'page-b', 'page-c']) {
        await takePage(store, threePages(), page);
      }
      shownWork.reset();
      storeWork.reset();
      await takePage(store, threePages(round: 1, changed: 1), 'page-b');
      expect(shownWork.contentRowsDigested, 1);
      expect(storeWork.rowsEncoded, 1);
      expect(storeWork.rowsCompared, 2);
      expect(storeWork.resultGroupsEncoded, 2);
    });
  });

  group('digests stored by an older build', () {
    Future<LibraryStore> reopenedOnOlderDigests() async {
      final storage = MemoryStorage();
      final first = await openCloudStore(MemoryEngine(storage));
      await addCloud(first, initialRows());
      await first.close();
      final older = olderBuildDigests(storage.contents);
      expect(sameContents(older, storage.contents), isFalse);
      final store = await openCloudStore(MemoryEngine(MemoryStorage(older)));
      final opened = await recordAll(store, [
        const AppRestarted(build: build),
        reconnected(),
      ]);
      expect(opened.outcomes, everyElement(isA<ReportApplied>()));
      return store;
    }

    test('are digested again by this run when the same rows arrive', () async {
      final store = await reopenedOnOlderDigests();
      final stored = await shownIn(store);
      expect(stored.rows[const ElementTarget('e1')]!.digestedThisRun, isFalse);
      expect(
        stored.rows[const ElementTarget('e1')]!.digest,
        isNot(rowDigest(initialRows().element('e1')!)),
      );
      await readServer(store, initialRows());
      final shown = await shownIn(store);
      for (final row in initialRows().elements) {
        final held = shown.rows[ElementTarget(row.publicId)]!;
        expect(held.digest, rowDigest(row), reason: row.publicId);
        expect(held.digestedThisRun, isTrue, reason: row.publicId);
      }
      for (final page in const ['page-a', 'page-b']) {
        expect(
          shown.content[page],
          liveContentOn(initialRows().elementsOn(page), page),
          reason: page,
        );
      }
    });

    test('do not hold a page delete or a move the user made on what they '
        'saw', () async {
      final store = await reopenedOnOlderDigests();
      await readServer(store, initialRows());
      savedValue(
        await store.commitAs(
          testAccount,
          strategyId,
          pageDelete('del', 'page-a'),
          seen: await seenIn(store),
        ),
      );
      savedValue(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('move', elementId: 'e3', x: 44),
          seen: await seenIn(store),
        ),
      );
      final views = (await syncOf(store)).views;
      expect(views['del']!.sendable, isTrue);
      expect(views['move']!.sendable, isTrue);
    });
  });

  test('a page whose rows changed without a new revision refuses the '
      'strategy while takes are checked', () async {
    shownTakesChecked = true;
    final store = await openCloudStore(MemoryEngine(MemoryStorage()));
    await addCloud(store, dense());
    final rewritten = dense().withRows([
      element(
        'e7',
        sortIndex: 7,
        fields: {
          'type': 'jett',
          'position': {'dx': -1.0, 'dy': 20},
        },
      ),
    ]);
    expect(
      await store.record(testAccount, strategyId, [
        await arrivalIn(store, pageReadOf(rewritten, 'page-a')),
      ]),
      isA<Refused<Recorded, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<StoredRowsDisagree>(),
      ),
    );
  });

  group('stored results in an older shape', () {
    final pageB = 'read/page/${digestOf('page-b')}';
    const pageList = 'read/header';

    test('are encoded again once when a result arrives after the store '
        'reopens, whichever group holds them', () async {
      final storage = MemoryStorage();
      final first = await openCloudStore(MemoryEngine(storage));
      await addCloud(first, initialRows());
      await first.close();
      final old = MemoryStorage(
        withOwedReads(storage.contents, {pageList, pageB}),
      );
      for (final group in [pageList, pageB]) {
        expect(storedGroup(old.contents, group), contains('"owed"'));
      }
      final store = await reopened(old);
      final taken = await recordAll(store, [
        await arrivalIn(store, pageReadOf(initialRows(), 'page-a')),
      ]);
      expect(taken.outcomes, everyElement(isA<ReportApplied>()));
      for (final group in [pageList, pageB]) {
        expect(storedGroup(old.contents, group), isNot(contains('"owed"')));
      }
      expect(
        await storedRows(store, 'page-a'),
        await rowsOnDisk(old, 'page-a'),
      );
    });

    test('on page B survive a local move saved before any read, and are '
        'encoded again by the first take on page A', () async {
      shownTakesChecked = true;
      final storage = MemoryStorage();
      final first = await openCloudStore(MemoryEngine(storage));
      await addCloud(first, initialRows());
      await first.close();
      final old = MemoryStorage(withOwedReads(storage.contents, {pageB}));
      final store = await openCloudStore(MemoryEngine(old));
      savedValue(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('local', x: 40),
          seen: await seenIn(store),
        ),
      );
      expect(storedGroup(old.contents, pageB), contains('"owed"'));
      final opened = await recordAll(store, [
        const AppRestarted(build: build),
        reconnected(),
      ]);
      expect(opened.outcomes, everyElement(isA<ReportApplied>()));
      await takePage(store, initialRows());
      expect(storedGroup(old.contents, pageB), isNot(contains('"owed"')));
      expect(
        await storedRows(store, 'page-a'),
        await rowsOnDisk(old, 'page-a'),
      );
    });

    test('on page B leave an update of page A taken, and are encoded only '
        'the first time', () async {
      final storage = MemoryStorage();
      final first = await openCloudStore(MemoryEngine(storage));
      await addCloud(first, initialRows());
      await first.close();
      final old = MemoryStorage(withOwedReads(storage.contents, {pageB}));
      final store = await reopened(old);
      await takePage(store, initialRows());
      expect(storedGroup(old.contents, pageB), isNot(contains('"owed"')));
      storeWork.reset();
      await takePage(store, withOp(initialRows(), movePatch('m', x: 40)));
      expect(storeWork.resultGroupsEncoded, 2);
      expect(
        await storedRows(store, 'page-a'),
        await rowsOnDisk(old, 'page-a'),
      );
    });
  });

  test('an item stored before this run is compared whole on the first result '
      'after the store reopens', () async {
    final storage = MemoryStorage();
    final first = await openCloudStore(MemoryEngine(storage));
    await addCloud(first, initialRows());
    await first.close();
    final store = await reopened(storage);
    final moved = initialRows().withRows([element('e1', sortIndex: 400)]);
    await takePage(store, moved);
    final e1 = elementOn(
      pageOf(await store.readPage(strategyId, 'page-a')),
      'e1',
    );
    expect((e1.toJson()! as Map)['sortIndex'], 400);
    expect(
      (await shownIn(store)).rows[const ElementTarget('e1')]!.digest,
      rowDigest(moved.element('e1')!),
    );
    expect(
      await storedRows(store, 'page-a'),
      await rowsOnDisk(storage, 'page-a'),
    );
  });

  group('a take that fails part of the way through', () {
    final moved = withOp(initialRows(), movePatch('m', x: 40));

    Future<void> nextIsTaken(LibraryStore store, MemoryStorage storage) async {
      await takePage(store, moved);
      final e1 = elementOn(
        pageOf(await store.readPage(strategyId, 'page-a')),
        'e1',
      );
      expect((e1.toJson()! as Map)['revision'], 2);
      expect(
        await storedRows(store, 'page-a'),
        await rowsOnDisk(storage, 'page-a'),
      );
    }

    test('because a row it finds unchanged differs from the stored copy '
        'refuses the strategy with the page as stored, and a reopen takes the '
        'next result', () async {
      shownTakesChecked = true;
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final odd = moved.withRows([
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
      expect(
        [for (final row in odd.elementsOn('page-a')) row.publicId],
        ['e1', 'e2'],
      );
      final before = editable(storage.contents);
      expect(
        await store.record(testAccount, strategyId, [
          await arrivalIn(store, pageReadOf(odd, 'page-a')),
        ]),
        isA<Refused<Recorded, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<StoredRowsDisagree>(),
        ),
      );
      expect(sameContents(storage.contents, before), isTrue);
      await store.close();
      final reopened = await openCloudStore(MemoryEngine(storage));
      await recordAll(reopened, const [AppRestarted(build: build)]);
      await nextIsTaken(reopened, storage);
    });

    test('because the write fails leaves the page as stored, and the next '
        'result is taken', () async {
      var refusing = false;
      final storage = MemoryStorage();
      final store = await openCloudStore(
        WrappingEngine(
          MemoryEngine(storage),
          (lease) => RefusingLease(lease, () => refusing),
        ),
      );
      await addCloud(store, initialRows());
      refusing = true;
      final result = await store.record(testAccount, strategyId, [
        await arrivalIn(store, pageReadOf(moved, 'page-a')),
      ]);
      refusing = false;
      expect(result, isA<NotSaved<Recorded, CommitRefusal>>());
      expect(
        await storedRows(store, 'page-a'),
        await rowsOnDisk(storage, 'page-a'),
      );
      await nextIsTaken(store, storage);
    });
  });
}
