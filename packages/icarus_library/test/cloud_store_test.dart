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
        isEmpty,
      );
      await store.close();
      final reopened = await openCloudStore(MemoryEngine(storage));
      expect(
        (await syncOf(reopened)).queue.nextAttempt,
        sent.attempt + 1,
        reason: 'the counters row keeps attempt numbers from being reused',
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

    test('a claim writes its attempt, the library\'s numbers and the '
        'summary', () async {
      final (store, counts) = await opened();
      await recordAll(store, [
        BatchClaimed(clientId: clientId, opIds: ['add7'], at: fixedClock()),
      ]);
      expect(
        counts.written.map((write) => write.$2),
        unorderedEquals([
          'attempt/${(1).toString().padLeft(16, '0')}',
          'numbers',
          summaryName(strategyId),
        ]),
      );
    });

    test('an answer writes the answered entry, the facts row when it is the '
        'first answer from its attempt, deletes the attempt once every op in '
        'it is answered, and writes the summary only when the sync state '
        'changed', () async {
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
          'cloud',
          summaryName(strategyId),
        ]),
      );
      expect(counts.deleted.map((delete) => delete.$2), [
        'attempt/${(1).toString().padLeft(16, '0')}',
      ]);
    });

    test('an unchanged page read writes its evidence row in one commit and '
        'nothing else', () async {
      final (store, counts) = await opened();
      final read = await startRead(store);
      counts.reset();
      await recordAll(store, [
        BaseArrived(pageReadOf(initialRows(), 'page-a'), read: read),
      ]);
      expect(counts.commits, 1);
      expect(counts.written.map((write) => write.$2), [
        'read/page/${digestOf('page-a')}',
      ]);
      expect(counts.deleted, isEmpty);
    });
  });

  group('store rules', () {
    test('a local strategy is never put over a cloud strategy', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final before = storage.contents;
      expect(
        await store.putStrategy(initialRows()),
        isA<Refused<LibraryEdited, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<KeptInTheCloud>(),
        ),
      );
      expect(sameContents(before, storage.contents), isTrue);
    });

    test('a page read supplies its page row and its content', () async {
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
        BaseArrived(pageReadOf(renamed, 'page-a'), read: read),
      ]);
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      expect((page.page as LivePage).name, 'Renamed');
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

    test('a page copied online reaches the queue as ordinary adds under ids '
        'made on this device, drawn at once and drained without the '
        'user', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await recordAll(store, [const ConnectionReturned()]);
      await readServer(store, initialRows());
      savedValue(
        await store.commit(
          strategyId,
          pageAdd('copy', 'page-c', copyFrom: 'page-a'),
        ),
      );
      final queued = (await syncOf(store)).queue.entries;
      expect(queued.whereType<PendingOp>().map((entry) => entry.op.type), [
        OpType.pageAdd,
        OpType.elementAdd,
        OpType.elementAdd,
      ]);
      final drawn = pageOf(await store.readPage(strategyId, 'page-c'));
      expect(drawn.elements, hasLength(2));
      final copiedId = drawn.elements.first.publicId;
      savedValue(
        await store.commit(
          strategyId,
          elementDelete('drop', elementId: copiedId, pageId: 'page-c'),
        ),
      );
      var server = initialRows();
      while ((await syncOf(store)).queue.entries.isNotEmpty) {
        final sent = await claimAll(store);
        final answers = <QueueEvent>[];
        for (final op in sent.ops) {
          server = withOp(server, op);
          answers.add(
            OpAnswered(
              sent.attempt,
              AppliedAnswer(op.opId, revision: visibleRevision(server, op)!),
            ),
          );
        }
        await recordAll(store, answers);
        await readServer(store, server);
      }
      final page = pageOf(await store.readPage(strategyId, 'page-c'));
      expect(page.elements.whereType<LiveElement>(), hasLength(1));
      expect(server.element(copiedId), isA<DeletedElement>());
    });
  });

  group('a queue row this build cannot read holds the whole strategy', () {
    Future<(LibraryStore, MemoryStorage, Contents)> withRow(
      String name,
      String text,
    ) async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('good')));
      await claimAll(store);
      await store.close();
      final contents = editable(storage.contents);
      contents[area]![name] = text;
      final disk = MemoryStorage(contents);
      return (await openCloudStore(MemoryEngine(disk)), disk, contents);
    }

    Future<void> expectHeld(String name, String text) async {
      final (store, disk, contents) = await withRow(name, text);
      final content = strategyOf(await store.readStrategy(strategyId));
      expect(
        content.sync,
        isA<CloudHeld>().having(
          (held) => held.rows.map((row) => row.ref.name),
          'rows',
          [name],
        ),
      );
      expect(
        await store.commit(strategyId, movePatch('next', elementId: 'e2')),
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<QueueHeld>(),
        ),
      );
      expect(
        await store.record(strategyId, [const ReadStarted()]),
        isA<Refused<Recorded, CommitRefusal>>(),
      );
      expect(
        sameContents({area: disk.contents[area]!}, {area: contents[area]!}),
        isTrue,
      );
      expect(
        listOf(store).strategies.single.sync,
        isA<KeptInCloud>().having(
          (sync) => sync.tally.unreadable,
          'unreadable',
          1,
        ),
      );
    }

    Future<void> withEntryText(String text) =>
        expectHeld(PendingName(5).name, text);

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
      test(label, () => withEntryText(entryText(changes)));
    }

    test('an op id another entry holds', () async {
      await withEntryText(entryText({'op': movePatch('good').toJson()}));
    });

    test('an attempt, the facts or evidence it cannot read', () async {
      for (final name in [AttemptName(1).name, 'cloud', 'read/header']) {
        await expectHeld(name, '{"version":2}');
      }
    });

    test('only an explicit discard of unsent work lets it go, and removing '
        'the area as unreadable is refused without one', () async {
      final (store, disk, _) = await withRow('cloud', '{"version":2}');
      await store.readStrategy(strategyId);
      final discarded = await store.discardUnreadableQueue(
        strategyId,
        const DiscardsUnsentWork(),
      );
      expect(discarded, isA<Saved<StrategySummary, CommitRefusal>>());
      expect(
        disk.contents[area]!.keys.where((key) => key.startsWith('pending/')),
        isEmpty,
      );
      final cloud = await syncOf(store);
      expect(cloud.queue.entries, isEmpty);
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

  test('opening a cloud strategy reads its queue in three listings and one '
      'read besides the strategy itself', () async {
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
      unorderedEquals([(area, 'strategy'), (area, 'cloud')]),
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

  test('a cloud strategy with work outstanding cannot be removed, and none '
      'can be filed into a folder', () async {
    final store = await openCloudStore(MemoryEngine(MemoryStorage()));
    await addCloud(store, initialRows());
    savedValue(await store.commit(strategyId, movePatch('move')));
    expect(
      await store.editLibrary([const RemoveStrategy(strategyId)]),
      isA<Refused<LibraryEdited, LibraryRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<CloudWorkOutstanding>(),
      ),
    );
    expect(
      await store.editLibrary([const MoveStrategy(strategyId, null)]),
      isA<Refused<LibraryEdited, LibraryRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        isA<KeptInTheCloud>(),
      ),
    );
  });
}

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
