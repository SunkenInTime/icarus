import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import '../tool/parity_scenarios.dart' as parity;
import 'store_support.dart';
import 'support.dart';

Future<Contents> seeded(StrategyRowSet strategy) async {
  final storage = MemoryStorage();
  final store = await openStore(MemoryEngine(storage));
  savedValue(await store.editLibrary([AddStrategy(strategy)]));
  await store.close();
  return storage.contents;
}

const scenarioStrategy = 's1';

late final List<Map<String, Object?>> scenarios;

T read<T>(Decoded<T> decoded) => switch (decoded) {
  Read(:final value) => value,
  CouldNotRead(:final problem) => fail(problem),
};

List<Object?> listOf(Object? value) =>
    value is List<Object?> ? value : const [];

List<StrategyOp> opsOf(Map<String, Object?> scenario) => [
  for (final json in listOf(scenario['ops']))
    if (StrategyOp.decode(json) case Read(:final value)) value,
];
Future<Contents> seededWith(Map<String, Object?> initial) async {
  final rows = StrategyRowSet(
    strategy: read(
      StrategyRow.decode({
        'createdAt': 0,
        'updatedAt': 0,
        ...initial['strategy']! as Map<String, Object?>,
      }),
    ),
    pages: [
      for (final row in listOf(initial['pages'])) read(PageRow.decode(row)),
    ],
    settings: [
      for (final row in listOf(initial['settings']))
        read(PageSettingsRow.decode(row)),
    ],
    elements: [
      for (final row in listOf(initial['elements']))
        read(ElementRow.decode(row, canRead: (_) => true)),
    ],
    lineupGroups: [
      for (final row in listOf(initial['lineupGroups']))
        read(LineupGroupRow.decode(row, canRead: (_) => true)),
    ],
  );
  final storage = MemoryStorage();
  final store = await openStore(MemoryEngine(storage));
  savedValue(
    await store.editLibrary([
      for (final row in listOf(initial['folders']))
        PutFolder(read(FolderRow.decode(row))),
      AddStrategy(rows),
    ]),
  );
  await store.close();
  return storage.contents;
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
  setUpAll(() async {
    final folder = await Directory.systemTemp.createTemp('icarus-batch-');
    final out = '${folder.path}/scenarios.json';
    parity.main([
      'generate',
      '../../tool/library_parity/samples.json',
      '0',
      '12',
      '150',
      out,
    ]);
    scenarios = [
      for (final scenario in jsonDecode(File(out).readAsStringSync()) as List)
        scenario as Map<String, Object?>,
    ];
    await folder.delete(recursive: true);
  });

  test(
    'batches of generated ops save what the same ops save one by one',
    () async {
      var batches = 0;
      var refusedWhole = 0;
      for (final scenario in scenarios) {
        final seed = scenario['seed']! as int;
        final random = Random(seed);
        final disk = await seededWith(
          scenario['initial']! as Map<String, Object?>,
        );
        final single = MemoryStorage(disk);
        final batched = MemoryStorage(disk);
        final one = await openStore(MemoryEngine(single));
        final many = await openStore(MemoryEngine(batched));
        final oneEvents = <StrategyEdited>[];
        final manyEvents = <StrategyEdited>[];
        one.changes.listen((change) {
          if (change is StrategyEdited) oneEvents.add(change);
        });
        many.changes.listen((change) {
          if (change is StrategyEdited) manyEvents.add(change);
        });
        final ops = opsOf(scenario);
        for (var at = 0; at < ops.length;) {
          final chunk = ops.skip(at).take(1 + random.nextInt(8)).toList();
          at += chunk.length;
          final applied = <StrategyOp>[];
          final refused = <StrategyOp>[];
          for (final op in chunk) {
            switch (await one.commit(scenarioStrategy, op)) {
              case Saved():
                applied.add(op);
              case Refused():
                refused.add(op);
              case _:
                break;
            }
          }
          if (applied.isEmpty) continue;
          if (refused.isNotEmpty && random.nextBool()) {
            final before = batched.contents;
            final mixed = [
              for (final op in chunk)
                if (applied.contains(op) || identical(op, refused.first)) op,
            ];
            expect(
              await many.commitAll(scenarioStrategy, mixed),
              isA<Refused<List<Committed>, CommitRefusal>>(),
              reason: 'seed $seed op $at',
            );
            expect(sameContents(batched.contents, before), isTrue);
            refusedWhole++;
          }
          final committed = savedValue(
            await many.commitAll(scenarioStrategy, applied),
          );
          batches++;
          expect(committed, hasLength(applied.length));
          expect(
            sameContents(batched.contents, single.contents),
            isTrue,
            reason: 'seed $seed op $at',
          );
          expect(
            await many.rebuildSummary(scenarioStrategy),
            isA<NothingToSave<StrategySummary, CommitRefusal>>(),
            reason: 'seed $seed op $at: the summary is what a rebuild gives',
          );
        }
        await pumpEventQueue();
        expect(
          [for (final event in manyEvents) (event.opId, event.summary)],
          [for (final event in oneEvents) (event.opId, event.summary)],
          reason: 'seed $seed',
        );
        await one.close();
        await many.close();
      }
      expect(batches, greaterThan(150));
      expect(refusedWhole, greaterThan(20));
    },
  );

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
      final disk = await seeded(strategy);
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
