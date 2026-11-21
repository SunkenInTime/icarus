import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

Future<Contents> imageOf(StrategyRowSet rows) async {
  final storage = MemoryStorage();
  final store = await openStore(MemoryEngine(storage));
  savedValue(await store.editLibrary([AddStrategy(rows)]));
  await store.close();
  return storage.contents;
}

StrategyRowSet withElements(StrategyRowSet rows, List<ElementRow> elements) =>
    StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: elements,
      lineupGroups: rows.lineupGroups,
    );

LiveElement movedJett() => element(
  'jett',
  fields: {
    'type': 'jett',
    'position': {'dx': 77, 'dy': 20},
  },
);

void main() {
  test(
    'over an empty store it writes exactly what adding the rows writes',
    () async {
      final storage = MemoryStorage();
      final store = await openStore(MemoryEngine(storage));
      savedValue(await store.putStrategy(sampleStrategy()));
      await store.close();
      expect(
        sameContents(storage.contents, await imageOf(sampleStrategy())),
        isTrue,
      );
    },
  );

  test('putting the same rows again writes nothing', () async {
    final (engine, counts) = counting(
      MemoryEngine(MemoryStorage(await seededClean())),
    );
    final store = await openStore(engine);
    counts.reset();
    expect(
      await store.putStrategy(sampleStrategy()),
      isA<NothingToSave<LibraryEdited, LibraryRefusal>>(),
    );
    expect(counts.commits, 0);
    await store.close();
  });

  test('a moved item is one commit of that row and the summary', () async {
    final storage = MemoryStorage(await seededClean());
    final (engine, counts) = counting(MemoryEngine(storage));
    final store = await openStore(engine);
    final moved = withElements(sampleStrategy(), [
      for (final row in sampleStrategy().elements)
        row.publicId == 'jett' ? movedJett() : row,
    ]);
    counts.reset();
    savedValue(await store.putStrategy(moved));
    expect(counts.commits, 1);
    expect(
      counts.written,
      unorderedEquals([
        (sampleArea, elementName('page-a', 'jett')),
        ('library', summaryName(strategyId)),
      ]),
    );
    expect(counts.deleted, isEmpty);
    await store.close();
    expect(sameContents(storage.contents, await imageOf(moved)), isTrue);
  });

  test('rows left out of the set are deleted, in the same commit', () async {
    final storage = MemoryStorage(await seededClean());
    final (engine, counts) = counting(MemoryEngine(storage));
    final store = await openStore(engine);
    final sample = sampleStrategy();
    final fewer = StrategyRowSet(
      strategy: sample.strategy,
      pages: [
        for (final page in sample.pages)
          if (page.publicId != 'page-c') page,
      ],
      settings: [
        for (final row in sample.settings)
          if (row.pagePublicId != 'page-c') row,
      ],
      elements: [
        for (final row in sample.elements)
          if (row.pagePublicId != 'page-c' && row.publicId != 'sova') row,
      ],
      lineupGroups: sample.lineupGroups,
    );
    counts.reset();
    savedValue(await store.putStrategy(fewer));
    expect(counts.commits, 1);
    expect(
      counts.deleted,
      unorderedEquals([
        (sampleArea, pageName('page-c')),
        (sampleArea, settingsName('page-c')),
        (sampleArea, elementName('page-c', 'kayo')),
        (sampleArea, elementName('page-a', 'sova')),
      ]),
    );
    final page = pageOf(await store.readPage(strategyId, 'page-a'));
    expect([for (final row in page.elements) row.publicId]..sort(), [
      'jett',
      'line',
    ]);
    expect(
      await store.rebuildSummary(strategyId),
      isA<NothingToSave<StrategySummary, CommitRefusal>>(),
    );
    await store.close();
    expect(sameContents(storage.contents, await imageOf(fewer)), isTrue);
  });

  test(
    'what it saved is what the next read gives, without reading again',
    () async {
      final (engine, counts) = counting(
        MemoryEngine(MemoryStorage(await seededClean())),
      );
      final store = await openStore(engine);
      final moved = withElements(sampleStrategy(), [
        for (final row in sampleStrategy().elements)
          row.publicId == 'jett' ? movedJett() : row,
      ]);
      savedValue(await store.putStrategy(moved));
      counts.reset();
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(
        (elementOn(page, 'jett') as LiveElement).payload.data.toJson(),
        movedJett().payload.data.toJson(),
      );
      expect(counts.reads, isEmpty);
      expect(counts.entryListings, isEmpty);
      await store.close();
    },
  );

  group('A strategy holding what an image cannot carry is refused', () {
    Future<void> expectRefused(Contents disk, Matcher refusal) async {
      final storage = MemoryStorage(disk);
      final (engine, counts) = counting(MemoryEngine(storage));
      final store = await openStore(engine);
      counts.reset();
      final result = await store.putStrategy(sampleStrategy());
      expect(
        result,
        isA<Refused<LibraryEdited, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          refusal,
        ),
      );
      expect(counts.commits, 0);
      await store.close();
      expect(sameContents(storage.contents, disk), isTrue);
    }

    Matcher dropping(Dropped dropped) => isA<PutWouldDrop>().having(
      (refusal) => refusal.dropped,
      'dropped',
      dropped,
    );

    Future<Contents> withRaw(String name, String value) async {
      final disk = await seededClean();
      return {
        ...disk,
        sampleArea: {...disk[sampleArea]!, name: value},
      };
    }

    test('a tombstone', () async {
      final sample = sampleStrategy();
      await expectRefused(
        await imageOf(
          withElements(sample, [...sample.elements, deletedElement('gone')]),
        ),
        dropping(Dropped.tombstone),
      );
    });

    test('a page in the trash', () async {
      final sample = sampleStrategy();
      await expectRefused(
        await imageOf(
          StrategyRowSet(
            strategy: sample.strategy,
            pages: [
              ...sample.pages,
              page('page-gone', sortIndex: 3, deleted: true),
            ],
            settings: [...sample.settings, settings('page-gone')],
            elements: sample.elements,
            lineupGroups: sample.lineupGroups,
          ),
        ),
        dropping(Dropped.trashedPage),
      );
    });

    test('a row this build cannot read', () async {
      await expectRefused(
        await withRaw(elementName('page-a', 'smoke'), unreadableElementJson),
        isA<UnreadableRowInTheWay>(),
      );
    });

    test('a row of a kind this build does not know', () async {
      await expectRefused(
        await withRaw(pinName, unknownRowJson),
        dropping(Dropped.unknownKind),
      );
    });

    test('a row with no id', () async {
      await expectRefused(
        await withRaw(elementName('page-a', 'garbled'), garbledJson),
        isA<UnplacedRowInTheWay>(),
      );
    });

    test('names this build does not know, as a cloud strategy holds', () async {
      await expectRefused(
        await withRaw('cloud', '{"base":1}'),
        dropping(Dropped.foreignName),
      );
    });

    test('a field this build does not know, on a row', () async {
      final sample = sampleStrategy();
      await expectRefused(
        await imageOf(
          StrategyRowSet(
            strategy: strategyRow(unknownFields: {'fromALaterBuild': 1}),
            pages: sample.pages,
            settings: sample.settings,
            elements: sample.elements,
            lineupGroups: sample.lineupGroups,
          ),
        ),
        dropping(Dropped.unknownField),
      );
    });

    test('a field this build does not know, on a payload', () async {
      final sample = sampleStrategy();
      await expectRefused(
        await imageOf(
          withElements(sample, [
            for (final row in sample.elements)
              if (row case LiveElement(publicId: 'jett', :final payload))
                LiveElement(
                  publicId: row.publicId,
                  pagePublicId: row.pagePublicId,
                  payload: ElementPayload(
                    kind: payload.kind,
                    payloadVersion: payload.payloadVersion,
                    data: payload.data.toMap(),
                    unknownFields: {'fromALaterBuild': true},
                  ),
                  sortIndex: row.sortIndex,
                  revision: row.revision,
                )
              else
                row,
          ]),
        ),
        dropping(Dropped.unknownField),
      );
    });

    test('two rows with one id on different pages', () async {
      final disk = await seededClean();
      final jett = disk[sampleArea]![elementName('page-a', 'jett')]!;
      await expectRefused(
        await withRaw(
          elementName('page-b', 'jett'),
          jett.replaceFirst(
            '"pagePublicId":"page-a"',
            '"pagePublicId":"page-b"',
          ),
        ),
        dropping(Dropped.duplicateRow),
      );
    });
  });

  test(
    'a row naming another strategy is refused before anything is read',
    () async {
      final sample = sampleStrategy();
      final (engine, counts) = counting(
        MemoryEngine(MemoryStorage(await seededClean())),
      );
      final store = await openStore(engine);
      counts.reset();
      expect(
        await store.putStrategy(
          StrategyRowSet(
            strategy: sample.strategy,
            pages: sample.pages,
            settings: sample.settings,
            elements: [
              ...sample.elements,
              element('stray', pageId: 'nowhere'),
            ],
          ),
        ),
        isA<Refused<LibraryEdited, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<RowOutsideStrategy>(),
        ),
      );
      expect(counts.reads, isEmpty);
      expect(counts.keyListings, isEmpty);
      expect(counts.entryListings, isEmpty);
      expect(counts.commits, 0);
      await store.close();
    },
  );

  for (final engine in ['memory', 'SQLite']) {
    group('On $engine, a page renamed before its content is read', () {
      late Directory folder;

      setUp(() async {
        folder = await Directory.systemTemp.createTemp('icarus-put-rename-');
      });

      tearDown(() => folder.delete(recursive: true));

      Future<LibraryStore> renamedBeforeRead(
        StorageEngine Function() open,
      ) async {
        final adding = await openStore(open());
        savedValue(await adding.editLibrary([AddStrategy(sampleStrategy())]));
        await adding.close();
        final store = await openStore(open());
        savedValue(
          await store.commit(
            strategyId,
            const PagePatchOp(
              opId: 'rename',
              pagePublicId: 'page-a',
              name: 'Entry',
              expectedPageRevision: 1,
            ),
          ),
        );
        return store;
      }

      test('still has its content', () async {
        final path = '${folder.path}/library.sqlite';
        final storage = MemoryStorage();
        StorageEngine open() =>
            engine == 'memory' ? MemoryEngine(storage) : SqliteEngine(path);
        final store = await renamedBeforeRead(open);
        final page = pageOf(await store.readPage(strategyId, 'page-a'));
        expect([for (final row in page.elements) row.publicId]..sort(), [
          'jett',
          'line',
          'sova',
        ]);
        await store.close();
      });

      test('then saved whole without an item drops that item', () async {
        final path = '${folder.path}/library.sqlite';
        final storage = MemoryStorage();
        StorageEngine open() =>
            engine == 'memory' ? MemoryEngine(storage) : SqliteEngine(path);
        final store = await renamedBeforeRead(open);
        final sample = sampleStrategy();
        final without = StrategyRowSet(
          strategy: sample.strategy,
          pages: [
            for (final page in sample.pages)
              page.publicId == 'page-a'
                  ? LivePage(
                      publicId: 'page-a',
                      strategyPublicId: strategyId,
                      name: 'Entry',
                      sortIndex: 0,
                      isAttack: true,
                      revision: 2,
                    )
                  : page,
          ],
          settings: sample.settings,
          elements: [
            for (final row in sample.elements)
              if (row.publicId != 'sova') row,
          ],
          lineupGroups: sample.lineupGroups,
        );
        savedValue(await store.putStrategy(without));
        await store.close();
        final reopened = await openStore(open());
        final page = pageOf(await reopened.readPage(strategyId, 'page-a'));
        expect([for (final row in page.elements) row.publicId]..sort(), [
          'jett',
          'line',
        ]);
        expect(
          await reopened.rebuildSummary(strategyId),
          isA<NothingToSave<StrategySummary, CommitRefusal>>(),
        );
        await reopened.close();
      });
    });
  }
}
