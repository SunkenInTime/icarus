import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart' show livedRowVersion;
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

const oldLife = 1763600000000;
const newLife = 1763700000000;

StrategyRowSet bornAt(int life, Map<String, String> elements) {
  final pages = {...elements.values}.toList()..sort();
  Row born(Row row) => switch (row) {
    LivePage() => LivePage(
      publicId: row.publicId,
      strategyPublicId: row.strategyPublicId,
      name: row.name,
      sortIndex: row.sortIndex,
      isAttack: row.isAttack,
      revision: row.revision,
      unknownFields: jsonObject({'createdAt': life}),
    ),
    ReadablePageSettings() => ReadablePageSettings(
      pagePublicId: row.pagePublicId,
      settings: row.settings,
      revision: row.revision,
      unknownFields: jsonObject({'createdAt': life}),
    ),
    _ => row,
  };
  return StrategyRowSet(
    strategy: strategyRow(
      createdAt: DateTime.fromMillisecondsSinceEpoch(life, isUtc: true),
    ),
    pages: [
      for (final (at, id) in pages.indexed)
        born(page(id, sortIndex: at)) as PageRow,
    ],
    settings: [for (final id in pages) born(settings(id)) as PageSettingsRow],
    elements: [
      for (final MapEntry(key: id, value: pageId) in elements.entries)
        LiveElement(
          publicId: id,
          pagePublicId: pageId,
          payload: agentPayload(id, const {}),
          sortIndex: 0,
          revision: 1,
          unknownFields: jsonObject({'createdAt': life}),
        ),
    ],
    lineupGroups: const [],
  );
}

String diskOf(MemoryStorage storage) => jsonEncode(storage.contents);

Future<List<ReportOutcome>> arrive(
  LibraryStore store,
  ArrivedBase base, {
  ResultStart started = const StartedAsItArrived(),
}) async => (await recordAll(store, [
  BaseArrived(base, session: await sessionOf(store), started: started),
])).outcomes;

void main() {
  test(
    'a strategy deleted and made again, read through the store: the new '
    'page list drops every page of the earlier strategy and the queued move '
    'asks, before and after a reopen; the new pages read in after it',
    () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      final before = bornAt(oldLife, {
        'e1': 'page-a',
        'e2': 'page-a',
        'e3': 'page-b',
      });
      await addCloud(store, before);
      await recordAll(store, [const ConnectionReturned()]);
      await readServer(store, before);
      savedValue(
        await store.commitAs(testAccount, strategyId, movePatch('move', x: 40)),
      );
      final after = bornAt(newLife, {'e1': 'page-a', 'e5': 'page-a'});
      await arrive(store, headerReadOf(after));

      Future<void> expectBetween() async {
        final strategy = strategyOf(await store.readStrategy(strategyId));
        expect(strategy.pages.map((page) => page.publicId), ['page-a']);
        final between = pageOf(await store.readPage(strategyId, 'page-a'));
        expect(between.elements, isEmpty);
        expect(between.content, isA<ContentNotRead>());
        expect(
          await store.readPage(strategyId, 'page-b'),
          isA<NotFound<PageContent>>(),
        );
        final sync = await syncOf(store);
        expect(sync.views.keys, ['move']);
        expect(
          sync.views['move']!.state,
          const NeedsUser(MadeInAReplacedStrategy()),
        );
        expect(sync.views['move']!.sendable, isFalse);
      }

      await expectBetween();
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      await recordAll(store, [
        const AppRestarted(build: build),
        const ConnectionReturned(),
      ]);
      await expectBetween();
      await arrive(store, pageReadOf(after, 'page-a'));
      final read = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(
        {for (final row in read.elements) row.publicId: row.toJson()},
        {
          for (final row in after.elementsOn('page-a'))
            row.publicId: row.toJson(),
        },
      );
    },
  );

  test('a result the queue sets aside writes nothing to disk', () async {
    final storage = MemoryStorage();
    final store = await openCloudStore(MemoryEngine(storage));
    final before = bornAt(oldLife, {'e1': 'page-a'});
    await addCloud(store, before);
    await recordAll(store, [const ConnectionReturned()]);
    await readServer(store, before);
    final after = bornAt(newLife, {'e5': 'page-a'});
    await readServer(store, after);
    final disk = diskOf(storage);
    final outcomes = await arrive(store, pageReadOf(before, 'page-a'));
    expect(outcomes, [
      isA<ReportNotApplicable>().having(
        (outcome) => outcome.why,
        'why',
        isA<FromAnEarlierLife>(),
      ),
    ]);
    expect(diskOf(storage), disk);
  });

  test('a live page result stores the rows it holds and keeps a stored row it '
      'lacks', () async {
    final store = await openCloudStore(MemoryEngine(MemoryStorage()));
    final rows = bornAt(oldLife, {'e1': 'page-a', 'e2': 'page-a'});
    await addCloud(store, rows);
    await recordAll(store, [const ConnectionReturned()]);
    await readServer(store, rows);
    final live = bornAt(oldLife, {'e1': 'page-a', 'e7': 'page-a'});
    await arrive(
      store,
      pageReadOf(live, 'page-a'),
      started: const LiveResult(),
    );
    final page = pageOf(await store.readPage(strategyId, 'page-a'));
    expect(page.elements.map((row) => row.publicId).toSet(), {
      'e1',
      'e2',
      'e7',
    });
  });

  test(
    'a page list read started before a refusal that owes the list does not '
    'pay it, though the strategy was unloaded and loaded again between',
    () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      final rows = bornAt(oldLife, {'e1': 'page-a'});
      await addCloud(store, rows);
      await recordAll(store, [const ConnectionReturned()]);
      await readServer(store, rows);
      savedValue(
        await store.commitAs(testAccount, strategyId, movePatch('move', x: 40)),
      );
      final early = store.readStartsNow();
      final sent = await claimAll(store);
      await recordAll(store, [
        BatchRefused(sent.attempt, BatchRefusal.strategyReplaced),
      ]);
      expect(owedReads((await syncOf(store)).queue), {const PageListResult()});
      expect(await store.unload(strategyId), isA<Unloaded>());
      final outcomes = await arrive(
        store,
        headerReadOf(rows),
        started: StartedAt(early),
      );
      expect(outcomes, [
        isA<ReportNotApplicable>().having(
          (outcome) => outcome.why,
          'why',
          isA<StartedBeforeANewerResult>(),
        ),
      ]);
      expect(owedReads((await syncOf(store)).queue), {const PageListResult()});
      await arrive(
        store,
        headerReadOf(rows),
        started: StartedAt(store.readStartsNow()),
      );
      expect(owedReads((await syncOf(store)).queue), isEmpty);
    },
  );

  group('a store written before rows carried lives', () {
    Future<MemoryStorage> writtenBeforeLives({String? damaged}) async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await recordAll(store, [const ConnectionReturned()]);
      await readServer(store, initialRows());
      savedValue(
        await store.commitAs(testAccount, strategyId, movePatch('move')),
      );
      await store.close();
      final contents = editable(storage.contents);
      final area = contents[strategyArea(strategyId)]!;
      for (final entry in [...area.entries]) {
        if (jsonDecode(entry.value) case final Map<String, Object?> row
            when row['version'] == livedRowVersion) {
          area[entry.key] = jsonEncode({...row, 'version': 1});
        }
      }
      if (damaged != null) area[damaged] = '{"version": 2, "kind": "op"}';
      return MemoryStorage(contents);
    }

    test('is held with its rows as they were, and its owner can discard it '
        'and start again', () async {
      final storage = await writtenBeforeLives();
      final disk = diskOf(storage);
      final store = await openCloudStore(MemoryEngine(storage));
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>(),
      );
      expect(diskOf(storage), disk);
      savedValue(
        await store.discardUnreadableQueue(
          testAccount,
          strategyId,
          const DiscardsUnsentWork(),
        ),
      );
      final fresh = await syncOf(store);
      expect(fresh.queue.entries, isEmpty);
      expect(fresh.queue.shown.strategy, isNull);
    });

    test('a row damaged another way holds it too', () async {
      final store = await openCloudStore(
        MemoryEngine(await writtenBeforeLives(damaged: 'pending/zz')),
      );
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>(),
      );
    });
  });
}
