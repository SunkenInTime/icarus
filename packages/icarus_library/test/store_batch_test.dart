import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/strategy_diff_check.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'strategy_diff_support.dart' show Generator, withUnknownFields;
import 'support.dart';

Future<StrategyRowSet> storedRows(LibraryStore store, String id) async {
  final content = strategyOf(await store.readStrategy(id));
  final pages = [
    for (final page in content.pages)
      pageOf(await store.readPage(id, page.publicId)),
  ];
  return StrategyRowSet(
    strategy: headerOf(content),
    pages: content.pages,
    settings: content.settings.values,
    elements: [for (final page in pages) ...page.elements],
    lineupGroups: [for (final page in pages) ...page.lineupGroups],
  );
}

StrategyRowSet readableOnly(StrategyRowSet rows) => StrategyRowSet(
  strategy: rows.strategy,
  pages: rows.pages,
  settings: rows.settings,
  elements: rows.elements.where((row) => row is! UnreadableElement),
  lineupGroups: rows.lineupGroups,
);

List<StrategyOp> diffOps(StrategyRowSet stored, StrategyRowSet target) =>
    switch (diffStrategy(stored, target, editId: 'handover')) {
      DiffOps(:final ops) => ops,
      DiffRefused(:final refusal) => fail('refused: $refusal'),
    };

Future<(Contents, StrategyRowSet)> seeded(StrategyRowSet strategy) async {
  final storage = MemoryStorage();
  final store = await openStore(MemoryEngine(storage));
  savedValue(await store.editLibrary([AddStrategy(strategy)]));
  final rows = await storedRows(store, strategy.strategy.publicId);
  await store.close();
  return (storage.contents, rows);
}

ElementPatchOp moved(String id, int x, {required int revision}) =>
    ElementPatchOp(
      opId: 'move-$id-$x',
      elementPublicId: id,
      expectedElementRevision: revision,
      payload: agentPayload(id, {
        'type': 'jett',
        'position': {'dx': x, 'dy': 0},
      }),
    );

void main() {
  test('a batch saves what committing its ops one by one saves', () async {
    var batches = 0;
    for (var seed = 0; seed < 60; seed++) {
      final generator = Generator(seed);
      final plain = readableOnly(generator.strategy());
      final (disk, stored) = await seeded(
        seed.isEven ? withUnknownFields(plain) : plain,
      );
      final target = generator.mutated(plain);
      final ops = diffOps(stored, target);
      if (ops.isEmpty) continue;
      batches++;

      final batched = MemoryStorage(disk);
      final batchStore = await openStore(MemoryEngine(batched));
      final batchEvents = <StoreChange>[];
      batchStore.changes.listen(batchEvents.add);
      final committed = savedValue(await batchStore.commitAll(strategyId, ops));

      final oneByOne = MemoryStorage(disk);
      final singleStore = await openStore(MemoryEngine(oneByOne));
      final singleEvents = <StoreChange>[];
      singleStore.changes.listen(singleEvents.add);
      for (final op in ops) {
        savedValue(await singleStore.commit(strategyId, op));
      }

      expect(
        sameContents(batched.contents, oneByOne.contents),
        isTrue,
        reason: 'seed $seed',
      );
      expect(
        [for (final each in committed) each.change.opId],
        [for (final op in ops) op.opId],
      );
      await pumpEventQueue();
      expect(
        [for (final event in batchEvents) (event as StrategyEdited).summary],
        [for (final event in singleEvents) (event as StrategyEdited).summary],
      );
      final reached = await storedRows(batchStore, strategyId);
      expect(
        switch (checkReached(stored, target, reached)) {
          DiffReached() => 'reached',
          DiffMissed(:final what) => what,
        },
        'reached',
        reason: 'seed $seed',
      );
      expect(
        await batchStore.rebuildSummary(strategyId),
        isA<NothingToSave<StrategySummary, CommitRefusal>>(),
        reason: 'seed $seed: the saved summary is what a rebuild gives',
      );
      await batchStore.close();
      await singleStore.close();
    }
    expect(batches, greaterThan(50));
  });

  group('The summary a batch saves equals a rebuild', () {
    Future<void> expectRebuildAgrees(
      Contents disk,
      List<StrategyOp> ops,
    ) async {
      final store = await openStore(MemoryEngine(MemoryStorage(disk)));
      savedValue(await store.commitAll(strategyId, ops));
      expect(
        await store.rebuildSummary(strategyId),
        isA<NothingToSave<StrategySummary, CommitRefusal>>(),
      );
      await store.close();
    }

    test('when the stored summary counted a row that is gone', () async {
      final disk = await seededClean();
      final stale = {
        ...disk,
        sampleArea: {...disk[sampleArea]!}
          ..remove(elementName('page-b', 'omen')),
      };
      await expectRebuildAgrees(stale, [
        const StrategyPatchOp(
          opId: 'rename',
          expectedStrategyRevision: 1,
          name: 'Renamed',
        ),
        ElementAddOp(
          opId: 'add',
          elementPublicId: 'neon',
          pagePublicId: 'page-b',
          payload: agentPayload('neon', {'type': 'neon'}),
          sortIndex: 3,
        ),
      ]);
    });

    test('when the only item on a page moves off it', () async {
      final disk = await seededClean();
      final store = await openOn(disk);
      final kayo =
          elementOn(pageOf(await store.readPage(strategyId, 'page-c')), 'kayo')
              as LiveElement;
      await store.close();
      await expectRebuildAgrees(disk, [
        ElementPatchOp(
          opId: 'move-kayo',
          elementPublicId: 'kayo',
          pagePublicId: 'page-b',
          payload: kayo.payload,
          sortIndex: 5,
          expectedElementRevision: kayo.revision,
        ),
      ]);
    });
  });

  test('a batch with a refused op saves none of it', () async {
    final disk = await seededClean();
    final storage = MemoryStorage(disk);
    final store = await openStore(MemoryEngine(storage));
    final result = await store.commitAll(strategyId, [
      moved('jett', 1, revision: 1),
      moved('sova', 2, revision: 1),
      moved('jett', 3, revision: 1),
    ]);
    expect(
      result,
      isA<Refused<List<Committed>, CommitRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<OpRefusal>(),
      ),
    );
    expect(sameContents(storage.contents, disk), isTrue);
    final page = pageOf(await store.readPage(strategyId, 'page-a'));
    expect(
      (elementOn(page, 'jett') as LiveElement).payload.data.toJson(),
      agent('jett').payload.data.toJson(),
    );
    savedValue(await store.commit(strategyId, moved('jett', 4, revision: 1)));
    await store.close();
  });

  test('a batch the engine refuses changes nothing in memory either', () async {
    final disk = await seededClean();
    final storage = MemoryStorage(disk);
    final store = await openStore(
      flaky(MemoryEngine(storage), {0: Failing.refused}),
    );
    final ops = [moved('jett', 1, revision: 1), moved('sova', 2, revision: 1)];
    expect(
      await store.commitAll(strategyId, ops),
      isA<NotSaved<List<Committed>, CommitRefusal>>(),
    );
    expect(sameContents(storage.contents, disk), isTrue);
    expect(savedValue(await store.commitAll(strategyId, ops)), hasLength(2));
    await store.close();
  });

  test('a batch of ops that change nothing has nothing to save', () async {
    final store = await openOn(await seededClean());
    final page = pageOf(await store.readPage(strategyId, 'page-a'));
    final jett = elementOn(page, 'jett') as LiveElement;
    expect(
      await store.commitAll(strategyId, [
        ElementPatchOp(
          opId: 'same',
          elementPublicId: 'jett',
          expectedElementRevision: 1,
          payload: jett.payload,
          merge: FieldMerge(fields: ['position']),
        ),
      ]),
      isA<NothingToSave<List<Committed>, CommitRefusal>>(),
    );
    await store.close();
  });

  for (final count in [1, 5, 300]) {
    test('a batch of $count ops is one engine commit', () async {
      final strategy = StrategyRowSet(
        strategy: strategyRow(),
        pages: [page('page-a', sortIndex: 0)],
        settings: [settings('page-a')],
        elements: [
          for (var i = 0; i < count; i++)
            agent('agent-$i', pageId: 'page-a', sortIndex: i),
        ],
      );
      final (disk, _) = await seeded(strategy);
      final (engine, counts) = counting(MemoryEngine(MemoryStorage(disk)));
      final store = await openStore(engine);
      pageOf(await store.readPage(strategyId, 'page-a'));
      counts.reset();
      savedValue(
        await store.commitAll(strategyId, [
          for (var i = 0; i < count; i++)
            moved('agent-$i', 100 + i, revision: 1),
        ]),
      );
      expect(counts.commits, 1);
      expect(counts.keyWrites, count + 2);
      expect(counts.reads, isEmpty);
      expect(counts.entryListings, isEmpty);
      await store.close();
    });
  }
}
