import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/json.dart' show canonicalJson;
import 'package:icarus_library/src/store/layout.dart'
    show AttemptName, PendingName;
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

String area = strategyArea(strategyId);

void main() {
  test('a cloud strategy round-trips: its edits, attempts, answers, reads '
      'and counters survive a reopen', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    expect(
      listOf(store).strategies.single.sync,
      isA<KeptInCloud>().having((sync) => sync.tally.total, 'total', 0),
    );
    savedValue(await store.commit(strategyId, movePatch('move', x: 40)));
    savedValue(
      await store.commit(strategyId, elementAdd('add', pageId: 'page-b')),
    );
    final sent = await claimAll(store);
    expect(sent.ops.map((op) => op.opId), ['move', 'add']);
    await recordAll(store, [
      OpAnswered(sent.attempt, const AppliedAnswer('move', revision: 2)),
    ]);
    final before = await syncOf(store);
    await store.close();
    store = await openCloudStore(MemoryEngine(storage));
    final after = await syncOf(store);
    expect(after.queue.entries.map((entry) => entry.id), ['move', 'add']);
    expect(after.views['move']!.state, isA<Accepted>());
    expect(after.views['add']!.state, isA<AnswerUnknown>());
    expect(after.queue.nextAttempt, before.queue.nextAttempt);
    expect(after.queue.nextRead, before.queue.nextRead);
    expect(after.queue.base, before.queue.base);
    expect(
      listOf(store).strategies.single.sync,
      isA<KeptInCloud>().having(
        (sync) => sync.tally,
        'tally',
        Tally.of(after.queue, fixedClock()),
      ),
    );
  });

  test(
    'a read settles accepted work and the page shows the server rows',
    () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('move', x: 40)));
      final sent = await claimAll(store);
      final server = withOp(initialRows(), sent.ops.single);
      await recordAll(store, [
        OpAnswered(sent.attempt, const AppliedAnswer('move', revision: 2)),
      ]);
      await readServer(store, server, pages: ['page-a']);
      expect((await syncOf(store)).queue.entries, isEmpty);
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(elementOn(page, 'e1'), server.element('e1'));
      expect(
        listOf(store).strategies.single.sync,
        isA<KeptInCloud>().having((sync) => sync.tally.total, 'total', 0),
      );
      expect(
        storage.contents[area]!.keys.where((key) => key.startsWith('attempt/')),
        hasLength(1),
        reason: 'the highest attempt row is kept so its number is never reused',
      );
    },
  );

  group('what is rewritten per event', () {
    late Contents disk;

    setUpAll(() async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      for (var i = 0; i < 200; i++) {
        savedValue(
          await store.commit(
            strategyId,
            elementAdd('add$i', elementId: 'n$i', pageId: 'page-b'),
          ),
        );
      }
      await store.close();
      disk = storage.contents;
    });

    Future<(LibraryStore, Counts)> opened() async {
      final (engine, counts) = counting(MemoryEngine(MemoryStorage(disk)));
      final store = await openCloudStore(engine);
      await syncOf(store);
      counts.reset();
      return (store, counts);
    }

    test('an edit writes its own entry row and the summary', () async {
      final (store, counts) = await opened();
      savedValue(await store.commit(strategyId, movePatch('move', x: 7)));
      expect(counts.commits, 1);
      expect(
        counts.written,
        unorderedEquals([
          (area, 'pending/${(200).toString().padLeft(16, '0')}'),
          ('library', summaryName(strategyId)),
        ]),
      );
      expect(counts.deleted, isEmpty);
    });

    test('a claim writes its attempt, the counters and the summary', () async {
      final (store, counts) = await opened();
      await recordAll(store, [
        BatchClaimed(clientId: clientId, opIds: ['add7'], at: fixedClock()),
      ]);
      expect(
        counts.written.map((write) => write.$2),
        unorderedEquals([
          'attempt/${(1).toString().padLeft(16, '0')}',
          'counters',
          summaryName(strategyId),
        ]),
      );
    });

    test('an answer writes the answered entry, and the summary only when '
        'the sync state changed', () async {
      final (store, counts) = await opened();
      final sent = (await recordAll(store, [
        BatchClaimed(clientId: clientId, opIds: ['add7'], at: fixedClock()),
      ])).outcomes;
      expect(sent, isNotEmpty);
      counts.reset();
      await recordAll(store, [
        const OpAnswered(1, AppliedAnswer('add7', revision: 1)),
      ]);
      expect(
        counts.written.map((write) => write.$2),
        unorderedEquals([
          'pending/${(7).toString().padLeft(16, '0')}',
          summaryName(strategyId),
        ]),
      );
      expect(counts.deleted, isEmpty);
    });

    test('an unchanged page read writes its evidence row in one commit and '
        'nothing else', () async {
      final (store, counts) = await opened();
      final read = await startRead(store);
      counts.reset();
      await recordAll(store, [
        BaseArrived(
          pageReadOf(initialRows(), 'page-a'),
          read: read,
          startedAt: fixedClock(),
        ),
      ]);
      expect(counts.commits, 1);
      expect(counts.written.map((write) => write.$2), [
        'read/page/${digestOf('page-a')}',
      ]);
      expect(counts.deleted, isEmpty);
      expect(counts.commits, 1, reason: '${counts.written}');
    });
  });

  group('store rules', () {
    test('a page read supplies content only', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final renamed = withOp(
        withOp(
          initialRows(),
          PagePatchOp(
            opId: 'rename',
            pagePublicId: 'page-a',
            expectedPageRevision: 1,
            name: 'Renamed',
          ),
        ),
        movePatch('theirs', x: 30),
      );
      final read = await startRead(store);
      await recordAll(store, [
        BaseArrived(
          pageReadOf(renamed, 'page-a'),
          read: read,
          startedAt: fixedClock(),
        ),
      ]);
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      expect((page.page as LivePage).name, 'Page 1');
      expect(elementOn(page, 'e1'), renamed.element('e1'));
    });

    test('a page missing from a strategy read is gone', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final read = await startRead(store);
      final rows = initialRows();
      await recordAll(store, [
        BaseArrived(
          HeaderRead(
            strategy: rows.strategy,
            pages: [rows.page('page-a')!],
            settings: [rows.settingsOf('page-a')!],
          ),
          read: read,
          startedAt: fixedClock(),
        ),
      ]);
      final names = storage.contents[area]!.keys;
      expect(names, isNot(contains(pageName('page-b'))));
      expect(names, isNot(contains(settingsName('page-b'))));
      expect(names, isNot(contains(elementName('page-b', 'e3'))));
      expect(
        strategyOf(
          await store.readStrategy(strategyId),
        ).pages.map((page) => page.publicId),
        ['page-a'],
      );
    });

    test('a page delete is checked against the page as the user saw it, '
        'own pending edits included', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('move', x: 40)));
      savedValue(await store.commit(strategyId, pageDelete('drop', 'page-a')));
      final queue = (await syncOf(store)).queue;
      final delete = queue.entry('drop')! as PendingOp;
      final seen = (delete.work as CheckedDelete).seen.content as ContentSeen;
      final drawn = withOp(initialRows(), movePatch('move', x: 40));
      expect(
        seen.digests[const SeenElement('e1')],
        rowDigest(drawn.element('e1')!),
      );
    });

    test('after copying a page online, the copy shows from the local preview '
        'and work on the new page waits for one read of it', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await recordAll(store, [const ConnectionReturned()]);
      savedValue(
        await store.commit(
          strategyId,
          pageAdd('copy', 'page-c', copyFrom: 'page-a'),
        ),
      );
      final sent = await claimAll(store);
      final copied = withOp(initialRows(), sent.ops.single);
      final serverIds = {
        for (final row in copied.elementsOn('page-c'))
          row.publicId: 'server-${row.publicId.hashCode.abs()}',
      };
      final server = StrategyRowSet(
        strategy: copied.strategy,
        pages: copied.pages,
        settings: copied.settings,
        elements: [
          for (final row in copied.elements)
            if (row case LiveElement(pagePublicId: 'page-c'))
              LiveElement(
                publicId: serverIds[row.publicId]!,
                pagePublicId: 'page-c',
                payload: row.payload,
                sortIndex: row.sortIndex,
                revision: row.revision,
              )
            else
              row,
        ],
      );
      await recordAll(store, [
        OpAnswered(
          sent.attempt,
          AppliedAnswer('copy', revision: server.strategy.revision),
        ),
      ]);
      await readServer(store, server, pages: const []);
      final preview = pageOf(await store.readPage(strategyId, 'page-c'));
      expect(
        preview.elements.map((row) => row.publicId).toSet(),
        serverIds.keys.toSet(),
      );
      savedValue(
        await store.commit(strategyId, elementAdd('new', pageId: 'page-c')),
      );
      final previewItem = preview.elements.first;
      savedValue(
        await store.commit(
          strategyId,
          elementDelete(
            'drop',
            elementId: previewItem.publicId,
            pageId: 'page-c',
          ),
        ),
      );
      final waiting = await syncOf(store);
      expect(waiting.views['new']!.holds, [
        const AwaitingBase(PageTarget('page-c')),
      ]);
      expect(waiting.views['drop']!.holds, [
        const AwaitingBase(PageTarget('page-c')),
      ]);
      await readServer(store, server, pages: ['page-c']);
      final after = await syncOf(store);
      expect(after.queue.entry('copy'), isNull);
      expect(after.views['new']!.holds, isEmpty);
      expect(after.views['new']!.go, isA<Free>());
      expect(
        after.views['drop']!.go,
        isA<NeedsUser>().having(
          (go) => go.reason,
          'reason',
          isA<ChangedUnseen>(),
        ),
        reason: 'the server gave the copies its own ids',
      );
      final page = pageOf(await store.readPage(strategyId, 'page-c'));
      expect(page.elements.map((row) => row.publicId).toSet(), {
        ...serverIds.values,
        'e9',
      });
    });
  });

  group('the decoder refuses what this build would never write', () {
    Future<CloudStrategy> withEntryText(String text) async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('good')));
      await store.close();
      final contents = editable(storage.contents);
      contents[area]![PendingName(5).name] = text;
      store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
      return syncOf(store);
    }

    String entryText(Map<String, Object?> changes) =>
        canonicalJson({...entryJson(), ...changes});

    for (final (label, changes) in <(String, Map<String, Object?>)>[
      ('a newer version', {'version': 2}),
      (
        'a checked delete of an element op',
        {
          'work': {
            'checkedDelete': {
              'pageDigest': 'x',
              'pageRevision': 1,
              'content': null,
            },
          },
        },
      ),
      (
        'a scope that does not fit its op',
        {
          'scope': {'strategy': true},
        },
      ),
      (
        'a merge without its field base',
        {
          'op': movePatch(
            'bare',
            merge: FieldMerge(fields: ['position']),
          ).toJson(),
        },
      ),
      (
        'a negative read number',
        {
          'answer': {'applied': 2, 'by': 'thisClient', 'afterRead': -1},
        },
      ),
    ]) {
      test(label, () async {
        final cloud = await withEntryText(entryText(changes));
        expect(cloud.queue.entries.map((entry) => entry.id), [
          'good',
          'unreadable/5',
        ]);
        expect(cloud.tally.unreadable, 1);
      });
    }

    test('an op id another entry holds', () async {
      final cloud = await withEntryText(
        entryText({'op': movePatch('good').toJson()}),
      );
      expect(cloud.queue.entries.last, isA<UnreadableEntry>());
    });

    test('an attempt it cannot read stops the strategy instead of '
        'resending', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('move')));
      await claimAll(store);
      await store.close();
      final contents = editable(storage.contents);
      contents[area]![AttemptName(1).name] = '{"version":1}';
      store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
      expect(
        await store.readStrategy(strategyId),
        isA<InUnreadableStrategy<StrategyContent>>(),
      );
      expect(
        await store.commit(strategyId, movePatch('next', expected: 1)),
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<CloudStateNotReadable>(),
        ),
      );
    });
  });

  test('the standing and both counters survive a reopen', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    savedValue(await store.commit(strategyId, movePatch('move')));
    final sent = await claimAll(store);
    await recordAll(store, [
      BatchRefused(sent.attempt, BatchRefusal.editAccessRemoved),
    ]);
    final read = await startRead(store);
    await store.close();
    store = await openCloudStore(MemoryEngine(storage));
    final cloud = await syncOf(store);
    expect(standingOf(cloud.queue), Standing.editAccessLost);
    expect(cloud.queue.nextRead, read + 1);
    expect(cloud.queue.nextAttempt, sent.attempt + 1);
  });

  test('a summary whose queued rows disagree with the queue is rebuilt when '
      'the store opens', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    final stale = storage.contents['library']![summaryName(strategyId)]!;
    savedValue(await store.commit(strategyId, movePatch('move')));
    await store.close();
    final contents = editable(storage.contents);
    contents['library']![summaryName(strategyId)] = stale;
    store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
    expect(
      listOf(store).strategies.single.sync,
      isA<KeptInCloud>()
          .having((sync) => sync.tally.waiting[Waiting.unsent], 'unsent', 1)
          .having((sync) => sync.queued.count, 'queued', 1),
    );
  });

  test('opening a cloud strategy reads its queue in three listings and two '
      'reads besides the strategy itself', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    savedValue(await store.commit(strategyId, movePatch('move')));
    await store.close();
    final (engine, counts) = counting(MemoryEngine(storage));
    store = await openCloudStore(engine);
    counts.reset();
    strategyOf(await store.readStrategy(strategyId));
    expect(
      counts.reads,
      unorderedEquals([
        (area, 'strategy'),
        (area, 'cloud'),
        (area, 'counters'),
      ]),
    );
    expect(counts.keyListings, [(area, '')]);
    expect(
      counts.entryListings,
      unorderedEquals([
        (area, 'page/'),
        (area, 'settings/'),
        (area, 'pending/'),
        (area, 'attempt/'),
        (area, 'read/'),
      ]),
    );
    expect(counts.commits, 0);
  });
}

Contents editable(Contents contents) => {
  for (final MapEntry(:key, :value) in contents.entries) key: {...value},
};

Map<String, Object?> entryJson() => {
  'version': 1,
  'kind': 'op',
  'op': movePatch('other', elementId: 'e2').toJson(),
  'scope': {'page': 'page-a'},
  'authored': {'noRow': true},
  'policy': 'checked',
  'retriedAfter': 0,
  'work': 'op',
  'answer': null,
};
