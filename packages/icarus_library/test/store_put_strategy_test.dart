import 'package:icarus_library/icarus_library.dart';
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
      final store = await openStore(MemoryEngine(storage));
      final result = await store.putStrategy(sampleStrategy());
      expect(
        result,
        isA<Refused<LibraryEdited, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          refusal,
        ),
      );
      await store.close();
      expect(sameContents(storage.contents, disk), isTrue);
    }

    test('a tombstone', () async {
      final sample = sampleStrategy();
      await expectRefused(
        await imageOf(
          withElements(sample, [...sample.elements, deletedElement('gone')]),
        ),
        isA<PutWouldDrop>().having(
          (refusal) => refusal.dropped,
          'dropped',
          Dropped.tombstone,
        ),
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
        isA<PutWouldDrop>().having(
          (refusal) => refusal.dropped,
          'dropped',
          Dropped.trashedPage,
        ),
      );
    });

    test('a row this build cannot read, or a kind it does not know', () async {
      await expectRefused(
        await seededContents(),
        anyOf(
          isA<UnreadableRowInTheWay>(),
          isA<UnplacedRowInTheWay>(),
          isA<PutWouldDrop>().having(
            (refusal) => refusal.dropped,
            'dropped',
            Dropped.unknownKind,
          ),
        ),
      );
    });

    test('names this build does not know, as a cloud strategy holds', () async {
      final disk = await seededClean();
      await expectRefused(
        {
          ...disk,
          sampleArea: {...disk[sampleArea]!, 'cloud': '{"base":1}'},
        },
        isA<PutWouldDrop>().having(
          (refusal) => refusal.dropped,
          'dropped',
          Dropped.foreignName,
        ),
      );
    });
  });

  test(
    'a row naming another strategy is refused before anything is read',
    () async {
      final sample = sampleStrategy();
      final storage = MemoryStorage(await seededClean());
      final store = await openStore(MemoryEngine(storage));
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
      await store.close();
    },
  );
}
