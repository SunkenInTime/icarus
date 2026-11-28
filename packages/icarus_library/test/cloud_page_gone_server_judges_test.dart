import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

Map<String, Object?> withPageGoneCounted(Map<String, Object?> json) => {
  for (final MapEntry(:key, :value) in json.entries)
    key: switch (value) {
      final Map<String, Object?> tally when key == 'tally' => {
        ...tally,
        'standing': 'good',
        'attention': {'pageGone': 1},
      },
      final Map<String, Object?> inner => withPageGoneCounted(inner),
      final other => other,
    },
};

void main() {
  test(
    'a library summary written by a build that counted questions about '
    'a gone page still opens: the summary is rebuilt from the queue',
    () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      final name = summaryName(strategyId);
      final written =
          jsonDecode(storage.contents['library']![name]!)
              as Map<String, Object?>;
      final old = jsonEncode(withPageGoneCounted(written));
      expect(old, contains('"pageGone":1'));
      final contents = editable(storage.contents);
      contents['library']![name] = old;
      store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
      final strategy = listOf(store).strategies.single;
      expect(strategy.publicId, strategyId);
      expect(
        strategy.sync,
        isA<KeptInCloud>().having(
          (sync) => sync.tally.attention,
          'attention',
          isEmpty,
        ),
      );
      expect(
        await store.readStrategy(strategyId),
        isA<Found<StrategyContent>>(),
      );
      await store.close();
    },
  );

  test('an edit behind my own work whose page a teammate trashed is sent, '
      'not asked here, and comes back refused as its page deleted', () async {
    final store = await openCloudStore(MemoryEngine(MemoryStorage()));
    await addCloud(store, initialRows());
    final server = Server();
    savedValue(
      await store.commitAs(
        testAccount,
        strategyId,
        movePatch('first', elementId: 'e3', x: 40, pageId: 'page-b'),
        seen: await seenIn(store),
      ),
    );
    final first = await claimAll(store);
    await recordAll(store, [
      OpAnswered(
        first.attempt,
        server.apply(clientId, first.ops.single),
        point: tick(),
      ),
    ]);
    savedValue(
      await store.commitAs(
        testAccount,
        strategyId,
        movePatch(
          'second',
          elementId: 'e3',
          expected: 2,
          x: 60,
          pageId: 'page-b',
        ),
        seen: await seenIn(store),
      ),
    );
    server.rows = withOp(
      server.rows,
      pageDelete(
        'their-drop',
        'page-b',
        expected: server.rows.strategy.revision,
      ),
    );
    await recordAll(store, [await arrivalIn(store, headerReadOf(server.rows))]);
    final views = (await syncOf(store)).views;
    expect(views['second']!.state, isNot(isA<NeedsUser>()));
    expect(views['second']!.sendable, isTrue);
    final sent = await claimAll(store);
    await recordAll(store, [
      OpAnswered(
        sent.attempt,
        server.apply(clientId, sent.ops.single),
        point: tick(),
      ),
    ]);
    expect(
      (await syncOf(store)).views['second']!.state,
      const NeedsUser(RefusedAsPageDeleted()),
    );
  });
}
