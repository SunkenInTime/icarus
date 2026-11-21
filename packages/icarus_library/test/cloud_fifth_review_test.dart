import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/fold.dart';
import 'package:icarus_library/src/field_merge.dart'
    show elementMergeBase, lineupMergeBase;
import 'package:icarus_library/src/store/layout.dart'
    show PendingName, strategyArea;
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

Map<String, Object?> link(String id, String notes) => {
  'id': id,
  'originId': 'o0',
  'landingId': 'l0',
  'notes': notes,
};

LineupGroupPayload lineup(List<Map<String, Object?>> links) =>
    LineupGroupPayload(
      payloadVersion: 1,
      data: {
        'id': 'g0',
        'origins': [
          {'id': 'o0', 'agent': <String, Object?>{}},
        ],
        'landings': [
          {'id': 'l0', 'ability': <String, Object?>{}},
        ],
        'links': links,
      },
    );

LiveLineupGroup noteGroup(String notes, {int revision = 1}) => LiveLineupGroup(
  strategyPublicId: strategyId,
  publicId: 'g0',
  pagePublicId: 'page-a',
  payload: lineup([link('k1', notes)]),
  sortIndex: 0,
  revision: revision,
);

StrategyRowSet withGroup() => strategyRows(
  elements: initialRows().elements.toList(),
  lineupGroups: [noteGroup('')],
);

String notesOf(StrategyRowSet rows) {
  final row = rows.lineupGroup('g0')! as LiveLineupGroup;
  final links = row.payload.data.toJson()['links']! as List<Object?>;
  return (links.single! as Map<String, Object?>)['notes']! as String;
}

ElementAddOp putBackOf(String opId, StrategyRows rows, String id) {
  final row = rows.element(id)! as LiveElement;
  return ElementAddOp(
    opId: opId,
    elementPublicId: id,
    pagePublicId: row.pagePublicId,
    payload: row.payload,
    sortIndex: row.sortIndex,
    expectedElementRevision: row.revision + 1,
  );
}

List<StrategyOp> sendAll(Client client, Server server) {
  final ids = [
    for (final entry in client.queue.entries)
      if (client.view(entry.id).sendable) entry.id,
  ];
  if (ids.isEmpty) return const [];
  final attempt = client.claim(ids);
  final sent = client.lastSent();
  for (final op in sent) {
    client.must(OpAnswered(attempt, server.apply(clientId, op)));
  }
  return sent;
}

void main() {
  group('rules review', () {
    test('a lineup note edited twice before sending reaches the server as '
        'the last note', () {
      final server = Server()..rows = withGroup();
      final client = Client(base: withGroup())
        ..must(const ConnectionReturned());
      client.read(withGroup());
      for (final (id, notes) in [('n1', 'jump'), ('n2', 'jump throw')]) {
        client.edit(
          LineupGroupPatchOp(
            opId: id,
            lineupPublicId: 'g0',
            expectedLineupRevision: 1,
            payload: lineup([link('k1', notes)]),
            sortIndex: 0,
            merge: FieldMerge(fields: ['links/k1']),
          ),
        );
      }
      sendAll(client, server);
      expect(notesOf(server.rows), 'jump throw');
    });

    test('a lineup note edited online and held through a disconnect is not a '
        'conflict nobody caused', () {
      final server = Server()..rows = withGroup();
      final client = Client(base: withGroup())
        ..must(const ConnectionReturned());
      client.read(withGroup());
      client.edit(
        lineupEditOp(
          opId: 'note',
          base: noteGroup(''),
          drawn: const DrawnAt(1),
          payload: lineup([link('k1', 'jump')]),
          sortIndex: 0,
          connection: Connection.live,
        ),
      );
      expect(notesOf(client.visible), 'jump');
      client.must(const ConnectionLost());
      client.must(const ConnectionReturned());
      client.read(withGroup());
      expect(notesOf(client.visible), 'jump');
      final sent = sendAll(client, server);
      expect(sent, hasLength(1));
      expect(notesOf(server.rows), 'jump');
    });

    test('a page-gone read started before a restart does not settle a lost '
        'page delete', () {
      final client = Client();
      client.read(initialRows());
      client.edit(pageDelete('drop', 'page-b'));
      final attempt = client.claim(['drop']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      final early = client.startRead();
      client.must(const AppRestarted(build: build));
      client.arrive(const PageGone('page-b'), read: early);
      expect(client.queue.entry('drop'), isNotNull);
    });

    test('a claim still open when day 30 passes is recorded as forgotten and '
        'never replayed after the clock moves back', () {
      final client = Client()..must(const ConnectionReturned());
      client.read(initialRows());
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      client.claim(['drag']);
      client.clock = now.add(const Duration(days: 30));
      client.must(const ConnectionLost());
      client.clock = now.add(const Duration(hours: 1));
      client.must(const AppRestarted(build: build));
      client.clock = now.add(const Duration(hours: 2));
      client.must(const ConnectionReturned());
      expect(
        (client.queue.entry('drag')! as PendingOp).memory,
        isA<Forgotten>(),
      );
      expect(client.view('drag').sendable, isFalse);
    });

    test('two people deleting the same element settles without asking', () {
      final client = Client();
      client.read(initialRows());
      client.edit(elementDelete('mine'));
      final server = withOp(initialRows(), elementDelete('theirs'));
      client.must(const ConnectionReturned());
      client.read(server);
      expect(client.queue.entry('mine'), isNull);
    });

    test('an applied move settles only when a read shows the item on its '
        'destination page, not when its source page goes', () {
      final client = Client()..must(const ConnectionReturned());
      client.read(initialRows());
      final move = movePatch('move', pageId: 'page-b');
      client.edit(move);
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(attempt, const AppliedAnswer('move', revision: 2)),
      );
      final moved = withOp(initialRows(), move);
      final sourceGone = withOp(moved, pageDelete('t', 'page-a'));
      client.arrive(headerReadOf(sourceGone));
      expect(client.queue.entry('move'), isNotNull);
      expect(client.visible.element('e1'), isA<LiveElement>());
      client.arrive(pageReadOf(sourceGone, 'page-b'));
      expect(client.queue.entry('move'), isNull);
    });

    test('a put-back waits for a read started after both the delete\'s '
        'answer and the latest reconnect', () {
      final client = Client()..must(const ConnectionReturned());
      client.read(initialRows());
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      client.edit(putBackOf('back', drawn, 'e1'));
      final attempt = client.claim(['del']);
      client.must(OpAnswered(attempt, const AppliedAnswer('del', revision: 2)));
      final between = client.startRead();
      client.must(const ConnectionLost());
      client.must(const ConnectionReturned());
      client.arrive(
        pageReadOf(withOp(initialRows(), elementDelete('del')), 'page-a'),
        read: between,
      );
      expect(client.view('back').sendable, isFalse);
    });

    test('a field edit over a row whose payload version changed is held for '
        'the user even when the drawn content is equal', () {
      final client = Client();
      client.read(initialRows());
      client.edit(
        movePatch('move', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      final e1 = initialRows().element('e1')! as LiveElement;
      final newer = LiveElement(
        publicId: 'e1',
        pagePublicId: 'page-a',
        payload: ElementPayload(
          kind: e1.payload.kind,
          payloadVersion: 2,
          data: e1.payload.data.toJson(),
        ),
        sortIndex: e1.sortIndex,
        revision: 2,
      );
      final rows = StrategyRowSet(
        strategy: initialRows().strategy,
        pages: initialRows().pages,
        settings: initialRows().settings,
        elements: [
          for (final row in initialRows().elements)
            if (row.publicId == 'e1') newer else row,
        ],
      );
      client.must(const ConnectionReturned());
      client.read(rows);
      expect(client.view('move').go, isA<NeedsUser>());
    });

    test('an entry waiting for a read is not counted as unsent, and the reads '
        'needed cover an accepted op waiting to be confirmed', () {
      final client = Client();
      client.read(initialRows());
      client.edit(elementDelete('drop', elementId: 'e2'));
      client.must(const AppRestarted(build: build));
      expect(
        Tally.of(client.queue, now).waiting.containsKey(Waiting.unsent),
        isFalse,
      );
      client.must(const ConnectionReturned());
      client.read(initialRows());
      final attempt = client.claim(['drop']);
      client.must(
        OpAnswered(attempt, const AppliedAnswer('drop', revision: 2)),
      );
      expect(
        readsNeeded(client.queue, now),
        contains(const PageNeed('page-a')),
      );
    });
  });

  group('storage review', () {
    Future<LibraryStore> reopened(MemoryStorage storage) async =>
        openCloudStore(MemoryEngine(MemoryStorage(storage.contents)));

    test('a late page-gone does not delete a page that newer reads '
        'confirmed', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final early = await startRead(store);
      await readServer(store, initialRows());
      await recordAll(store, [
        BaseArrived(const PageGone('page-b'), read: early),
      ]);
      expect(
        elementOn(pageOf(await store.readPage(strategyId, 'page-b')), 'e3'),
        isNotNull,
      );
      final again = await reopened(storage);
      expect(
        elementOn(pageOf(await again.readPage(strategyId, 'page-b')), 'e3'),
        isNotNull,
      );
    });

    test('an older header does not bring back a page a newer read found '
        'gone', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final older = await startRead(store);
      final newer = await startRead(store);
      await recordAll(store, [
        BaseArrived(const PageGone('page-b'), read: newer),
      ]);
      await recordAll(store, [
        BaseArrived(headerReadOf(initialRows()), read: older),
      ]);
      expect(
        await store.readPage(strategyId, 'page-b'),
        isA<NotFound<PageContent>>(),
      );
      final again = await reopened(storage);
      expect(
        await again.readPage(strategyId, 'page-b'),
        isA<NotFound<PageContent>>(),
      );
    });

    test('one call with a late page-gone, a fresh header and fresh content '
        'keeps the element on disk as in memory', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final early = await startRead(store);
      final header = await startRead(store);
      final content = await startRead(store);
      await recordAll(store, [
        BaseArrived(const PageGone('page-b'), read: early),
        BaseArrived(headerReadOf(initialRows()), read: header),
        BaseArrived(pageReadOf(initialRows(), 'page-b'), read: content),
      ]);
      expect(
        elementOn(pageOf(await store.readPage(strategyId, 'page-b')), 'e3'),
        isNotNull,
      );
      final again = await reopened(storage);
      expect(
        elementOn(pageOf(await again.readPage(strategyId, 'page-b')), 'e3'),
        isNotNull,
      );
    });

    test('a read started before a strategy is removed and added again '
        'cannot overwrite the new copy', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final old = await startRead(store);
      expect(
        await store.editLibrary([const RemoveStrategy(strategyId)]),
        isA<Saved<LibraryEdited, LibraryRefusal>>(),
      );
      final changed = withOp(initialRows(), movePatch('t', x: 90));
      await addCloud(store, changed);
      final fresh = await startRead(store);
      expect(fresh, greaterThan(old));
      await recordAll(store, [
        BaseArrived(pageReadOf(changed, 'page-a'), read: fresh),
      ]);
      await store.record(strategyId, [
        BaseArrived(pageReadOf(initialRows(), 'page-a'), read: old),
      ]);
      final again = await reopened(storage);
      expect(
        elementOn(pageOf(await again.readPage(strategyId, 'page-a')), 'e1'),
        changed.element('e1'),
      );
    });

    test('an attempt number is never issued again after a strategy is '
        'removed and added again', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('move', x: 40)));
      final sent = await claimAll(store);
      final first = withOp(initialRows(), sent.ops.single);
      await recordAll(store, [
        OpAnswered(sent.attempt, const AppliedAnswer('move', revision: 2)),
      ]);
      await readServer(store, first);
      expect(
        await store.editLibrary([const RemoveStrategy(strategyId)]),
        isA<Saved<LibraryEdited, LibraryRefusal>>(),
      );
      await addCloud(store, first);
      savedValue(
        await store.commit(strategyId, movePatch('next', x: 5, expected: 2)),
      );
      expect((await claimAll(store)).attempt, greaterThan(sent.attempt));
    });

    Future<MemoryStorage> withNewerRow() async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      final contents = editable(storage.contents);
      contents[strategyArea(strategyId)]![PendingName(1 << 40).name] =
          '{"version":99}';
      return MemoryStorage(contents);
    }

    test('a strategy found held is shown held by the library list after a '
        'reopen, before its queue is read again', () async {
      final storage = await withNewerRow();
      final store = await openCloudStore(MemoryEngine(storage));
      await store.readStrategy(strategyId);
      await store.close();
      final again = await openCloudStore(MemoryEngine(storage));
      expect(
        listOf(again).strategies.single.sync,
        isA<KeptInCloud>().having(
          (sync) => sync.tally.unreadable,
          'unreadable',
          greaterThan(0),
        ),
      );
    });

    test('removing a strategy whose area holds a queue row this build cannot '
        'read is refused even when its summary is clean', () async {
      final storage = await withNewerRow();
      final store = await openCloudStore(MemoryEngine(storage));
      final result = await store.editLibrary([
        const RemoveStrategy(strategyId),
      ]);
      expect(result, isA<Refused<LibraryEdited, LibraryRefusal>>());
      expect(storage.contents[strategyArea(strategyId)], isNotNull);
    });

    test('removing an unreadable strategy is refused while its area holds '
        'only cloud facts, counters or evidence', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      final contents = editable(storage.contents);
      final area = contents[strategyArea(strategyId)]!;
      for (final key in [...area.keys]) {
        if (key.startsWith('pending/') || key.startsWith('attempt/')) {
          area.remove(key);
        }
      }
      area['strategy'] = '{not json';
      final library = contents['library']!;
      for (final key in [...library.keys]) {
        if (key.startsWith('summary/')) library[key] = '{}';
      }
      final damaged = MemoryStorage(contents);
      final again = await openCloudStore(MemoryEngine(damaged));
      final listing = listOf(again).unreadableStrategies.single;
      final result = await again.editLibrary([
        RemoveUnreadableStrategy(listing.ref),
      ]);
      expect(result, isA<Refused<LibraryEdited, LibraryRefusal>>());
    });

    test('discarding a pending rename after the strategy was deleted on the '
        'server puts the base name back in the list', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final baseName = listOf(store).strategies.single.name;
      savedValue(
        await store.commit(
          strategyId,
          const StrategyPatchOp(
            opId: 'rename',
            expectedStrategyRevision: 1,
            name: 'Renamed',
          ),
        ),
      );
      final read = await startRead(store);
      await recordAll(store, [BaseArrived(const StrategyGone(), read: read)]);
      await recordAll(store, [const UserDiscarded('rename')]);
      expect(listOf(store).strategies.single.name, baseName);
      final again = await reopened(storage);
      expect(listOf(again).strategies.single.name, baseName);
    });

    test('a claim made at a time finer than the stored precision is '
        'saved', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('move', x: 40)));
      await recordAll(store, [const ConnectionReturned()]);
      await readServer(store, initialRows());
      final result = await store.record(strategyId, [
        BatchClaimed(
          clientId: clientId,
          opIds: const ['move'],
          at: fixedClock().add(const Duration(microseconds: 1)),
        ),
      ]);
      expect(result, isA<Saved<Recorded, CommitRefusal>>());
    });
  });

  group('every field name form the field merge accepts', () {
    LineupGroupPayload full(String tag) => LineupGroupPayload(
      payloadVersion: 1,
      data: {
        'id': 'g0',
        'origins': [
          {'id': 'o0', 'agent': <String, Object?>{}, 'tag': tag},
        ],
        'landings': [
          {'id': 'l0', 'ability': <String, Object?>{}, 'tag': tag},
        ],
        'links': [
          {'id': 'k1', 'originId': 'o0', 'landingId': 'l0', 'notes': tag},
        ],
      },
    );
    final stored = LiveLineupGroup(
      strategyPublicId: strategyId,
      publicId: 'g0',
      pagePublicId: 'page-a',
      payload: full('stored'),
      sortIndex: 0,
      revision: 1,
    );
    final rows = strategyRows(
      elements: initialRows().elements.toList(),
      lineupGroups: [stored],
    );

    for (final name in ['origins/o0', 'landings/l0', 'links/k1']) {
      test('the lineup item $name', () {
        LineupGroupPatchOp edit(String id, String tag) => LineupGroupPatchOp(
          opId: id,
          lineupPublicId: 'g0',
          expectedLineupRevision: 1,
          payload: full(tag),
          sortIndex: 0,
          merge: FieldMerge(fields: [name]),
        );
        final based = withFieldBase(rows, edit('first', 'one'));
        final item = lineupMergeBase(stored.payload, 0, [name]);
        expect((based as LineupGroupPatchOp).merge!.base!.toJson(), item);
        expect(item[name], isNotNull);
        final folded = fold(edit('first', 'one'), edit('then', 'two'));
        final payload =
            ((folded as FoldedOp).op as LineupGroupPatchOp).payload!;
        expect(lineupMergeBase(payload, 0, [name]), {
          name: lineupMergeBase(full('two'), 0, [name])[name],
        });
      });
    }

    final e1 = initialRows().element('e1')! as LiveElement;
    for (final fields in [
      ['position'],
      ['rotation', 'length'],
      [placeField],
    ]) {
      test('the element fields $fields', () {
        ElementPatchOp edit(String id, int value) => ElementPatchOp(
          opId: id,
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          payload: agentPayload('e1', {
            ...e1.payload.data.toJson(),
            'position': {'dx': value, 'dy': value},
            'rotation': value,
            'length': value,
          }),
          sortIndex: value,
          merge: FieldMerge(fields: fields),
        );
        final based = withFieldBase(initialRows(), edit('first', 1));
        expect(
          (based as ElementPatchOp).merge!.base!.toJson(),
          elementMergeBase(e1.payload, e1.sortIndex, fields),
        );
        final folded = fold(edit('first', 1), edit('then', 2));
        final op = (folded as FoldedOp).op as ElementPatchOp;
        final want = edit('then', 2);
        expect(
          elementMergeBase(op.payload!, op.sortIndex!, fields),
          elementMergeBase(want.payload!, want.sortIndex!, fields),
        );
      });
    }
  });
}
