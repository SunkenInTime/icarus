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
  BaseArrived(
    pageReadOf(server, page),
    session: await sessionOf(store),
    from: await readStartOf(store),
  ),
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
        expect(storeWork.resultGroupsEncoded, 2);
        shownWork.reset();
        storeWork.reset();
        await takePage(store, dense(round: 1, changed: changed));
        expect(shownWork.contentRowsDigested, 0);
        expect(storeWork.rowsEncoded, 0);
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
      final opened = await recordAll(store, const [
        AppRestarted(build: build),
        ConnectionReturned(),
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

  test('a page whose rows changed without a new revision fails the take '
      'loudly while takes are checked', () async {
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
    await expectLater(takePage(store, rewritten), throwsA(isA<TakesDiffer>()));
  });
}
