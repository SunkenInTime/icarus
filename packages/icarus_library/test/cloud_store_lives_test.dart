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

void main() {
  test('a strategy deleted and uploaded again under the same id, read through '
      'the store: between the new page list and the page reads, nothing the '
      'old life held is drawn, before or after a reopen', () async {
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
    await recordAll(store, [
      BaseArrived(headerReadOf(after), session: await sessionOf(store)),
    ]);
    await store.close();
    store = await openCloudStore(MemoryEngine(storage));
    await recordAll(store, [
      const AppRestarted(build: build),
      const ConnectionReturned(),
    ]);
    final strategy = strategyOf(await store.readStrategy(strategyId));
    expect(strategy.pages.map((page) => page.publicId), ['page-a']);
    final between = pageOf(await store.readPage(strategyId, 'page-a'));
    expect(between.elements, isEmpty);
    expect(between.content, isA<ContentNotRead>());
    expect(
      await store.readPage(strategyId, 'page-b'),
      isA<NotFound<PageContent>>(),
    );
    expect(
      (await syncOf(
        store,
      )).queue.entries.whereType<PendingOp>().map((entry) => entry.id),
      ['move'],
    );
    await recordAll(store, [
      BaseArrived(pageReadOf(after, 'page-a'), session: await sessionOf(store)),
    ]);
    final read = pageOf(await store.readPage(strategyId, 'page-a'));
    expect(
      {for (final row in read.elements) row.publicId: createdAtOf(row)},
      {'e1': newLife, 'e5': newLife},
    );
    final sent = await claimAll(store);
    expect(sent.lives, {'move': oldLife});
  });

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

    test(
      'is held, says so, and its owner can discard it and start again',
      () async {
        final store = await openCloudStore(
          MemoryEngine(await writtenBeforeLives()),
        );
        final held = strategyOf(await store.readStrategy(strategyId)).sync;
        expect(
          held,
          isA<CloudHeld>().having(
            (held) => held.writtenBeforeLives,
            'written before lives',
            isTrue,
          ),
        );
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
      },
    );

    test(
      'a row damaged another way makes it held for that reason too',
      () async {
        final store = await openCloudStore(
          MemoryEngine(await writtenBeforeLives(damaged: 'pending/zz')),
        );
        final held = strategyOf(await store.readStrategy(strategyId)).sync;
        expect(
          held,
          isA<CloudHeld>().having(
            (held) => held.writtenBeforeLives,
            'written before lives',
            isFalse,
          ),
        );
      },
    );
  });
}
