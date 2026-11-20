import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

List<String> generatedIds() {
  final random = Random(642);
  String any(int length) => String.fromCharCodes([
    for (var i = 0; i < length; i++)
      switch (random.nextInt(6)) {
        0 => 0xd800 + random.nextInt(0x800),
        1 => 0x20 + random.nextInt(0x5f),
        2 => 0x80 + random.nextInt(0x780),
        3 => 0xfeff,
        4 => [0x25, 0x2f, 0x7e, 0x2e][random.nextInt(4)],
        _ => 0x4e00 + random.nextInt(0x100),
      },
  ]);
  return [
    '﻿jett',
    '﻿',
    '\ud800',
    'a\udc00b',
    '😀',
    '%',
    '%73trategy-1',
    '%%',
    '%2',
    '/',
    'a/b',
    '',
    ' ',
    '\u0000',
    'Säge',
    'UPPER-lower_~.',
    '..',
    'x' * 100,
    'x' * 300,
    for (var i = 0; i < 40; i++) any(1 + random.nextInt(12)),
  ];
}

bool _refusedForTheId<S>(Saving<S, Object?> result) =>
    result is Refused<S, Object?> && result.reason is IdNotStorable;

void main() {
  late Contents seeded;

  setUpAll(() async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
    await store.close();
    seeded = storage.contents;
  });

  for (final (index, id) in generatedIds().indexed) {
    test(
      'id $index (${id.runes.take(12).toList()}) is refused or comes back the same',
      () async {
        final disk = MemoryStorage(seeded);
        final store = await openStore(MemoryEngine(disk, maxKeyLength: 255));
        final tries = <String, Saving<Object?, Object?>>{
          'element': await store.commit(
            strategyId,
            ElementAddOp(
              opId: 'add-element',
              elementPublicId: id,
              pagePublicId: 'page-a',
              payload: agent(id).payload,
              sortIndex: 9,
            ),
          ),
          'page': await store.commit(
            strategyId,
            PageAddOp(
              opId: 'add-page',
              pagePublicId: id,
              sortIndex: 3,
              expectedStrategyRevision: 1,
              settings: defaultSettings,
            ),
          ),
          'lineup': await store.commit(
            strategyId,
            LineupGroupAddOp(
              opId: 'add-lineup',
              lineupPublicId: id,
              pagePublicId: 'page-b',
              payload: lineupPayload(id),
              sortIndex: 0,
            ),
          ),
          'strategy and folder': await store.editLibrary([
            PutFolder(ReadableFolder(publicId: id, name: 'F')),
            AddStrategy(
              StrategyRowSet(
                strategy: strategyRow(publicId: id),
                pages: [
                  LivePage(
                    publicId: 'only',
                    strategyPublicId: id,
                    name: 'Page 1',
                    sortIndex: 0,
                    isAttack: true,
                    revision: 1,
                  ),
                ],
                settings: [settings('only')],
              ),
            ),
          ]),
        };
        await store.close();
        final reopened = await openOn(disk.contents);
        for (final MapEntry(key: what, value: result) in tries.entries) {
          if (_refusedForTheId(result)) continue;
          expect(
            result,
            isA<Saved<Object?, Object?>>(),
            reason: '$what: ${describeSaving(result)}',
          );
          switch (what) {
            case 'element':
              final page = pageOf(
                await reopened.readPage(strategyId, 'page-a'),
              );
              expect(page.elements.map((row) => row.publicId), contains(id));
              expect(page.foreignKeys, isEmpty);
            case 'page':
              final content = strategyOf(
                await reopened.readStrategy(strategyId),
              );
              expect(content.pages.map((row) => row.publicId), contains(id));
              expect(content.foreignKeys, isEmpty);
            case 'lineup':
              final page = pageOf(
                await reopened.readPage(strategyId, 'page-b'),
              );
              expect(
                page.lineupGroups.map((row) => row.publicId),
                contains(id),
              );
            case _:
              final list = listOf(reopened);
              expect(list.folders.map((row) => row.publicId), contains(id));
              expect(list.strategies.map((row) => row.publicId), contains(id));
              expect(
                headerOf(strategyOf(await reopened.readStrategy(id))).publicId,
                id,
              );
          }
        }
      },
    );
  }

  test(
    'a key that spells an id another way is foreign, never that row',
    () async {
      final area = {...seeded[sampleArea]!};
      final jett = area['content/page-a/element/jett']!;
      final opening = await LibraryStore.open(
        MemoryEngine(
          MemoryStorage({
            ...seeded,
            sampleArea: {
              ...area,
              'content/page-a/element/%6Aett': jett,
              'content/page-a/element/%zz': jett,
              'page/%70age-a': area['page/page-a']!,
            },
            'library': {
              ...seeded['library']!,
              'summary/%73trategy-1':
                  seeded['library']!['summary/$strategyId']!,
              'summary/%': '{}',
              'folder/%2': '{}',
            },
          }),
        ),
        canRead: readsKnownKinds,
      );
      final (store, foreign) = switch (opening) {
        StoreOpened(:final store, :final foreignKeys) => (store, foreignKeys),
        StoreNotOpened(:final problem) => fail('$problem'),
      };
      expect(
        foreign.map((key) => key.key),
        unorderedEquals(['summary/%73trategy-1', 'summary/%', 'folder/%2']),
      );
      expect(listOf(store).strategies, hasLength(1));
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(
        page.elements.where((row) => row.publicId == 'jett'),
        hasLength(1),
      );
      expect(
        page.foreignKeys.map((key) => key.key),
        unorderedEquals([
          'content/page-a/element/%6Aett',
          'content/page-a/element/%zz',
        ]),
      );
      final content = strategyOf(await store.readStrategy(strategyId));
      expect(content.pages, hasLength(3));
      expect(
        content.foreignKeys.map((key) => key.key),
        contains('page/%70age-a'),
      );
      expect(
        await store.commit(
          strategyId,
          ElementAddOp(
            opId: 'take-jett',
            elementPublicId: 'jett',
            pagePublicId: 'page-b',
            payload: agent('jett').payload,
            sortIndex: 0,
          ),
        ),
        isA<Refused<Committed, CommitRefusal>>(),
      );
      final disk = MemoryStorage({
        ...seeded,
        sampleArea: {...area, 'content/page-a/element/%6Aett': jett},
      });
      final removing = await openStore(MemoryEngine(disk));
      savedValue(
        await removing.editLibrary([const RemoveStrategy(strategyId)]),
      );
      expect(disk.contents[sampleArea], isNull);
    },
  );

  test(
    'a long op id on an engine that holds 255-character keys never locks the library',
    () async {
      final disk = MemoryStorage(seeded);
      final engine = MemoryEngine(disk, maxKeyLength: 255);
      final store = await openStore(crashing(engine, Cut(1)));
      final result = await store.commit(
        strategyId,
        ElementReorderOp(
          opId: 'o' * 255,
          elementPublicId: 'line',
          pagePublicId: 'page-a',
          sortIndex: 4,
          expectedElementRevision: 1,
        ),
      );
      expect(result, isA<Saved<Committed, CommitRefusal>>());
      await engine.close();
      for (var open = 0; open < 2; open++) {
        final reopened = await openStore(MemoryEngine(disk, maxKeyLength: 255));
        final line = elementOn(
          pageOf(await reopened.readPage(strategyId, 'page-a')),
          'line',
        );
        expect((line as LiveElement).sortIndex, 4);
        await reopened.close();
      }
      expect(disk.contents['journal']?['edit'], isNull);
    },
  );
}
