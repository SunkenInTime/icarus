import 'dart:convert';

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
    expect((await syncOf(store)).queue.session.number, 0);
    await recordAll(store, [const AppRestarted(build: build)]);
    final after = await syncOf(store);
    expect(after.queue.entries.map((entry) => entry.id), ['add']);
    expect(after.queue.landed.single.op.opId, 'move');
    expect(after.views['add']!.state, isA<Unanswered>());
    expect(after.queue.nextAttempt, before.queue.nextAttempt);
    expect(after.queue.session.number, before.queue.nextSession);
    expect(after.queue.shown, before.queue.shown.inNewSession());
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

    test('an edit writes its own entry row and the summary, and opening the '
        'store writes nothing', () async {
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
      counts.reset();
      savedValue(
        await store.commit(strategyId, movePatch('again', x: 9, expected: 2)),
      );
      expect(
        counts.written,
        unorderedEquals([
          (area, 'pending/${(201).toString().padLeft(16, '0')}'),
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

    test('an answer deletes the answered entry and writes its landed work, '
        'the facts row when it is the first answer from its attempt, deletes '
        'the attempt once every op in it is answered, and writes the '
        'summary', () async {
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
          'landed/${(1).toString().padLeft(16, '0')}/${(0).toString().padLeft(16, '0')}',
          'cloud',
          summaryName(strategyId),
        ]),
      );
      expect(
        counts.deleted.map((delete) => delete.$2),
        unorderedEquals([
          'pending/${(7).toString().padLeft(16, '0')}',
          'attempt/${(1).toString().padLeft(16, '0')}',
        ]),
      );
    });

    test('an unchanged page read writes nothing', () async {
      final (store, counts) = await opened();
      await recordAll(store, [const ConnectionLost()]);
      final session = await sessionOf(store);
      counts.reset();
      await recordAll(store, [
        BaseArrived(pageReadOf(initialRows(), 'page-a'), session: session),
      ]);
      expect(counts.commits, 0);
      expect(counts.written, isEmpty);
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
      final session = await sessionOf(store);
      await recordAll(store, [
        BaseArrived(pageReadOf(renamed, 'page-a'), session: session),
      ]);
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      expect((page.page as LivePage).name, 'Renamed');
      expect(elementOn(page, 'e1'), renamed.element('e1'));
    });

    test('a page missing from a strategy read is gone', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final session = await sessionOf(store);
      final rows = initialRows();
      await recordAll(store, [
        BaseArrived(
          HeaderRead(
            strategy: rows.strategy,
            pages: [rows.page('page-a')!],
            settings: [rows.settingsOf('page-a')!],
          ),
          session: session,
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
        await store.record(strategyId, [const ConnectionLost()]),
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
      ('a negative session number', {'authoredIn': -1}),
      (
        'an unreadable refusal',
        {
          'refusal': {'rejected': 'not_a_reason'},
        },
      ),
      ('an unreadable window', {'windowPassed': 'soon'}),
    ]) {
      test(label, () => withEntryText(entryText(changes)));
    }

    test('the template entry itself reads', () async {
      final (store, _, _) = await withRow(PendingName(5).name, entryText({}));
      expect((await syncOf(store)).queue.entries.map((entry) => entry.id), [
        'good',
        'other',
      ]);
    });

    test('an attempt whose failure time is out of range', () async {
      await expectHeld(
        AttemptName(9).name,
        canonicalJson({
          'version': 1,
          'clientId': clientId,
          'build': build,
          'at': 0,
          'ops': [movePatch('late', elementId: 'e2').toJson()],
          'outcome': {'failed': 'network', 'at': 9e15},
        }),
      );
    });

    test('queue rows with the cloud facts row missing', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('good')));
      await store.close();
      final contents = editable(storage.contents);
      contents[area]!.remove('cloud');
      final disk = MemoryStorage(contents);
      store = await openCloudStore(MemoryEngine(disk));
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>().having(
          (held) => held.rows.map((row) => row.ref.name),
          'rows',
          ['cloud'],
        ),
      );
      expect(
        await store.editLibrary([const RemoveStrategy(strategyId)]),
        isA<Refused<LibraryEdited, LibraryRefusal>>(),
      );
      expect(
        disk.contents[area]!.keys.where((key) => key.startsWith('pending/')),
        hasLength(1),
      );
    });

    test('an op id another entry holds', () async {
      await withEntryText(entryText({'op': movePatch('good').toJson()}));
    });

    test('an attempt, the facts or evidence it cannot read', () async {
      for (final name in [
        AttemptName(1).name,
        'cloud',
        'read/header',
        'landed/${(1).toString().padLeft(16, '0')}/${(0).toString().padLeft(16, '0')}',
      ]) {
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

  test('adding a cloud strategy takes each page row from its page read, which '
      'is newer than the header', () async {
    final store = await openCloudStore(MemoryEngine(MemoryStorage()));
    final rows = initialRows();
    final renamed = withOp(
      rows,
      PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-a',
        expectedPageRevision: 1,
        name: 'Renamed',
      ),
    );
    savedValue(
      await store.addCloudStrategy(headerReadOf(rows), pageReadsOf(renamed)),
    );
    final page = pageOf(await store.readPage(strategyId, 'page-a'));
    expect((page.page as LivePage).name, 'Renamed');
    expect(
      strategyOf(
        await store.readStrategy(strategyId),
      ).pages.map((page) => (page as LivePage).name),
      contains('Renamed'),
    );
  });

  test('a damaged numbers row holds every cloud queue and refuses import, and '
      'local strategies are untouched', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    savedValue(await store.commit(strategyId, movePatch('move')));
    await claimAll(store);
    await store.close();
    final contents = editable(storage.contents);
    contents['library']!['numbers'] = '{"version":2}';
    final disk = MemoryStorage(contents);
    store = await openCloudStore(MemoryEngine(disk));
    expect(
      strategyOf(await store.readStrategy(strategyId)).sync,
      isA<CloudHeld>().having(
        (held) => held.rows.map((row) => row.ref.name),
        'rows',
        ['numbers'],
      ),
    );
    expect(
      await store.record(strategyId, [const AppRestarted(build: build)]),
      isA<Refused<Recorded, CommitRefusal>>(),
    );
    StrategyRowSet bare(String id) => StrategyRowSet(
      strategy: strategyRow(publicId: id),
      pages: const [],
      settings: const [],
      elements: const [],
      lineupGroups: const [],
    );
    final other = bare('strategy-2');
    expect(
      await store.addCloudStrategy(headerReadOf(other), pageReadsOf(other)),
      isA<Refused<StrategySummary, LibraryRefusal>>().having(
        (refused) => refused.reason,
        'reason',
        const NumbersUnreadable(),
      ),
    );
    savedValue(await store.putStrategy(bare('local-1')));
    expect(disk.contents['library']!['numbers'], '{"version":2}');
  });

  test('a read never writes, and a record call writes a passed resend '
      'window down', () async {
    final storage = MemoryStorage();
    var clock = fixedClock();
    final (engine, counts) = counting(MemoryEngine(storage));
    var store = await openCloudStore(engine, clock: () => clock);
    await addCloud(store, initialRows());
    savedValue(await store.commit(strategyId, movePatch('move')));
    final sent = await claimAll(store);
    await recordAll(store, [
      TransportFailed(sent.attempt, TransportFailure.network, at: clock),
    ]);
    clock = clock.add(resendWindow);
    counts.reset();
    await store.readStrategy(strategyId);
    await store.readPage(strategyId, 'page-a');
    expect(counts.commits, 0);
    expect((await syncOf(store)).views['move']!.state, isA<Unanswered>());
    await recordAll(store, const []);
    expect(
      (await syncOf(store)).views['move']!.state,
      const NeedsUser(WrittenLongAgo()),
    );
    await store.close();
    clock = fixedClock();
    store = await openCloudStore(MemoryEngine(storage), clock: () => clock);
    expect(
      (await syncOf(store)).views['move']!.state,
      const NeedsUser(WrittenLongAgo()),
    );
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
    final session = await sessionOf(store);
    await store.close();
    store = await openCloudStore(MemoryEngine(storage));
    await recordAll(store, [const AppRestarted(build: build)]);
    final cloud = await syncOf(store);
    expect(standingOf(cloud.queue), Standing.editAccessLost);
    expect(cloud.queue.session.number, greaterThan(session));
    expect(cloud.queue.nextAttempt, sent.attempt + 1);
  });

  test('opening a cloud strategy reads its queue in four listings and one '
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
        (area, 'landed/'),
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

  group('storage review', () {
    LiveElement e1At(String page, {required int revision, double x = 0}) {
      final row = initialRows().element('e1')! as LiveElement;
      return LiveElement(
        publicId: 'e1',
        pagePublicId: page,
        payload: agentPayload('e1', {
          ...row.payload.data.toJson(),
          'position': {'dx': x, 'dy': 0},
        }),
        sortIndex: row.sortIndex,
        revision: revision,
      );
    }

    test('import keeps the newest placement when results arrive out of '
        'order, and a second result for a page replaces the first', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      final rows = initialRows();
      final moved = rows.withRows([e1At('page-b', revision: 2)]);
      final withoutE2 = withOp(rows, elementDelete('gone', elementId: 'e2'));
      savedValue(
        await store.addCloudStrategy(headerReadOf(rows), [
          pageReadOf(moved, 'page-b') as PageRead,
          pageReadOf(rows, 'page-a') as PageRead,
          pageReadOf(withoutE2, 'page-a') as PageRead,
        ]),
      );
      final a = pageOf(await store.readPage(strategyId, 'page-a'));
      final b = pageOf(await store.readPage(strategyId, 'page-b'));
      expect(b.elements.map((row) => row.publicId), contains('e1'));
      expect(
        a.elements.whereType<LiveElement>().map((row) => row.publicId),
        isEmpty,
      );
    });

    test('opening the store and reading a held queue commit nothing', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      final contents = editable(storage.contents);
      contents[area]![PendingName(5).name] = '{"version":2}';
      final (engine, counts) = counting(MemoryEngine(MemoryStorage(contents)));
      store = await openCloudStore(engine);
      counts.reset();
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>(),
      );
      expect(counts.commits, 0);
    });

    test('a session is only handed out once it is written, so a reopen never '
        'hands it out again', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      final session = await sessionOf(store);
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      final before = storage.contents;
      final late = await recordAll(store, [
        BaseArrived(
          pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
          session: session,
        ),
      ]);
      expect(late.outcomes.single, isA<ReportNotApplicable>());
      expect(sameContents(before, storage.contents), isTrue);
      await recordAll(store, [const AppRestarted(build: build)]);
      expect(await sessionOf(store), greaterThan(session));
    });

    test('a result from a removed copy of a strategy changes nothing in the '
        'copy added again', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final old = await sessionOf(store);
      savedValue(await store.editLibrary([const RemoveStrategy(strategyId)]));
      await addCloud(store, initialRows());
      expect(await sessionOf(store), greaterThan(old));
      final late = await recordAll(store, [
        BaseArrived(
          pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
          session: old,
        ),
      ]);
      expect(late.outcomes.single, isA<ReportNotApplicable>());
    });

    test('an area with stored results and no cloud row is a held cloud '
        'strategy: never overwritten as local, and discard works', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      final contents = editable(storage.contents);
      contents[area]!.remove('cloud');
      final disk = MemoryStorage(contents);
      store = await openCloudStore(MemoryEngine(disk));
      expect(
        await store.putStrategy(initialRows()),
        isA<Refused<LibraryEdited, LibraryRefusal>>(),
      );
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>(),
      );
      expect(
        await store.discardUnreadableQueue(
          strategyId,
          const DiscardsUnsentWork(),
        ),
        isA<Saved<StrategySummary, CommitRefusal>>(),
      );
    });

    test('a discard whose summary write is refused changes nothing', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('move')));
      await store.close();
      final contents = editable(storage.contents);
      contents[area]![PendingName(5).name] = '{"version":2}';
      final disk = MemoryStorage(contents);
      var refuse = false;
      store = await openCloudStore(
        WrappingEngine(
          MemoryEngine(disk),
          (lease) => RefusingLease(
            lease,
            (changes) =>
                refuse &&
                changes.any(
                  (change) =>
                      change is Put && change.key.startsWith('summary/'),
                ),
          ),
        ),
      );
      await store.readStrategy(strategyId);
      final before = disk.contents;
      refuse = true;
      expect(
        await store.discardUnreadableQueue(
          strategyId,
          const DiscardsUnsentWork(),
        ),
        isA<NotSaved<StrategySummary, CommitRefusal>>(),
      );
      expect(sameContents(before, disk.contents), isTrue);
    });

    test('a result that moves an item to another page updates both pages\' '
        'counts', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      final moved = initialRows().withRows([e1At('page-b', revision: 2)]);
      await recordAll(store, [
        BaseArrived(
          pageReadOf(moved, 'page-b'),
          session: await sessionOf(store),
        ),
      ]);
      int items(LibraryStore store) =>
          listOf(store).strategies.single.itemCount;
      expect(items(store), 3);
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      expect(items(store), 3);
    });

    test('a fresh result that repairs a damaged row clears its warning at '
        'once', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      final contents = editable(storage.contents);
      contents[area]![elementName('page-a', 'e1')] = '{"broken":true}';
      store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
      await recordAll(store, [const AppRestarted(build: build)]);
      expect(
        pageOf(await store.readPage(strategyId, 'page-a')).unplaced,
        isNotEmpty,
      );
      await recordAll(store, [
        BaseArrived(
          pageReadOf(initialRows(), 'page-a'),
          session: await sessionOf(store),
        ),
      ]);
      expect(
        pageOf(await store.readPage(strategyId, 'page-a')).unplaced,
        isEmpty,
      );
    });

    test(
      'copying a page whose content no result has shown is refused',
      () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        savedValue(
          await store.addCloudStrategy(headerReadOf(initialRows()), const []),
        );
        expect(
          await store.commit(
            strategyId,
            pageAdd('copy', 'page-c', copyFrom: 'page-a', sortIndex: 2),
          ),
          isA<Refused<Committed, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            const CopyNeedsContent('page-a'),
          ),
        );
      },
    );
  });

  group('second storage review', () {
    StrategyRowSet threePages() => strategyRows(
      pages: [
        page('page-a', sortIndex: 0),
        page('page-b', sortIndex: 1),
        page('page-c', sortIndex: 2),
      ],
      elements: [
        element('e1'),
        element('e2'),
        element('e3', pageId: 'page-b'),
      ],
    );

    Future<Map<String, List<String>>> drawn(LibraryStore store) async {
      final content = strategyOf(await store.readStrategy(strategyId));
      return {
        for (final page in content.pages)
          page.publicId: [
            for (final row in pageOf(
              await store.readPage(strategyId, page.publicId),
            ).elements)
              if (row is LiveElement) row.publicId,
          ],
      };
    }

    Future<void> expectListMatchesPages(LibraryStore store) async {
      final pages = await drawn(store);
      final summary = listOf(store).strategies.single;
      expect(
        {
          for (final page in pages.keys)
            page: summary.tallies[page]?.items ?? 0,
        },
        {for (final MapEntry(:key, :value) in pages.entries) key: value.length},
      );
    }

    Future<void> answer(LibraryStore store, String opId, int revision) async {
      final sent = await claimAll(store);
      await recordAll(store, [
        OpAnswered(sent.attempt, AppliedAnswer(opId, revision: revision)),
      ]);
    }

    test('two accepted moves of one row draw it once, where the second '
        'put it, warm and after a reopen', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, threePages());
      savedValue(
        await store.commit(strategyId, movePatch('ab', pageId: 'page-b')),
      );
      await answer(store, 'ab', 2);
      savedValue(
        await store.commit(
          strategyId,
          movePatch('bc', pageId: 'page-c', expected: 2),
        ),
      );
      await answer(store, 'bc', 3);
      Future<void> check() async {
        final pages = await drawn(store);
        expect(pages['page-a'], ['e2']);
        expect(pages['page-b'], ['e3']);
        expect(pages['page-c'], ['e1']);
        await expectListMatchesPages(store);
      }

      await check();
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      await check();
    });

    test('an element that exists only as accepted work can be dragged on its '
        'page and to another page', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      savedValue(
        await store.commit(
          strategyId,
          elementAdd('add', elementId: 'e9', pageId: 'page-b'),
        ),
      );
      await answer(store, 'add', 1);
      savedValue(
        await store.commit(
          strategyId,
          movePatch('drag', elementId: 'e9', x: 5),
        ),
      );
      savedValue(
        await store.commit(
          strategyId,
          movePatch('away', elementId: 'e9', expected: 2, pageId: 'page-a'),
        ),
      );
      final pages = await drawn(store);
      expect(pages['page-a'], containsAll(['e9']));
      expect(pages['page-b'], isNot(contains('e9')));
      await expectListMatchesPages(store);
    });

    test('a commit that was not stored leaves memory as it was: the same '
        'result applies when delivered again, and a refused edit does not end '
        'the session', () async {
      final storage = MemoryStorage();
      var refuse = false;
      final store = await openCloudStore(
        WrappingEngine(
          MemoryEngine(storage),
          (lease) => RefusingLease(lease, (_) => refuse),
        ),
      );
      await addCloud(store, initialRows());
      final session = await sessionOf(store);
      final server = withOp(initialRows(), movePatch('t', x: 9));
      final result = BaseArrived(
        pageReadOf(server, 'page-a'),
        session: session,
      );
      refuse = true;
      expect(
        await store.record(strategyId, [result]),
        isA<NotSaved<Recorded, CommitRefusal>>(),
      );
      expect(
        await store.commit(strategyId, movePatch('mine', elementId: 'e2')),
        isA<NotSaved<Committed, CommitRefusal>>(),
      );
      refuse = false;
      expect(await sessionOf(store), session);
      expect(
        (await recordAll(store, [result])).outcomes.single,
        isA<ReportApplied>(),
      );
      expect(
        elementOn(pageOf(await store.readPage(strategyId, 'page-a')), 'e1'),
        server.element('e1'),
      );
    });

    test('a queued move whose source page a result removes is counted where '
        'it is drawn', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(
        await store.commit(strategyId, movePatch('m', pageId: 'page-b')),
      );
      await recordAll(store, [
        BaseArrived(const PageGone('page-a'), session: await sessionOf(store)),
      ]);
      await expectListMatchesPages(store);
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      await expectListMatchesPages(store);
    });

    test('a held queue: the list counts what the held page draws, and a page '
        'whose content never arrived still reads as not read', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      savedValue(
        await store.addCloudStrategy(headerReadOf(initialRows()), [
          pageReadOf(initialRows(), 'page-a') as PageRead,
        ]),
      );
      savedValue(await store.commit(strategyId, elementAdd('add')));
      await store.close();
      final contents = editable(storage.contents);
      contents[area]![PendingName(5).name] = '{"version":2}';
      store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>(),
      );
      await expectListMatchesPages(store);
      expect(
        pageOf(await store.readPage(strategyId, 'page-b')).content,
        isA<ContentNotRead>(),
      );
    });

    test('no result applies before a session is opened after a reopen, not '
        'even one labelled with session 0', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      final before = storage.contents;
      final late = await recordAll(store, [
        BaseArrived(
          pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
          session: 0,
        ),
      ]);
      expect(late.outcomes.single, isA<ReportNotApplicable>());
      expect(sameContents(before, storage.contents), isTrue);
    });

    test('a missing numbers row beside a cloud strategy holds it and refuses '
        'import, as an unreadable one does', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      final contents = editable(storage.contents);
      contents['library']!.remove('numbers');
      store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>().having(
          (held) => held.rows.map((row) => row.ref.name),
          'rows',
          ['numbers'],
        ),
      );
      final other = strategyRows(elements: [element('x1')]);
      expect(
        await store.addCloudStrategy(
          HeaderRead(
            strategy: strategyRow(publicId: 'other'),
            pages: other.pages.toList(),
            settings: other.settings.toList(),
          ),
          const [],
        ),
        isA<Refused<StrategySummary, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          const NumbersUnreadable(),
        ),
      );
    });

    test('a name under a cloud prefix that this build cannot decode makes the '
        'strategy a held cloud one, which removal does not erase', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, elementAdd('add')));
      await store.close();
      final contents = editable(storage.contents);
      final rows = contents[area]!;
      final pending = rows.keys.singleWhere(
        (key) => key.startsWith('pending/'),
      );
      rows['pending/by-id'] = rows.remove(pending)!;
      rows.removeWhere((key, _) => key == 'cloud' || key.startsWith('read/'));
      store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>(),
      );
      expect(
        await store.editLibrary([const RemoveStrategy(strategyId)]),
        isA<Refused<LibraryEdited, LibraryRefusal>>(),
      );
    });

    test('an accepted page add shown first by its page\'s result still '
        'raises the strategy revision a later page edit names', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, pageAdd('add', 'page-c')));
      await answer(store, 'add', 2);
      final server = withOp(initialRows(), pageAdd('add', 'page-c'));
      await recordAll(store, [
        BaseArrived(
          pageReadOf(server, 'page-c'),
          session: await sessionOf(store),
        ),
      ]);
      expect(
        (strategyOf(await store.readStrategy(strategyId)).strategy
                as ReadableStrategy)
            .revision,
        2,
      );
    });

    test('deleting a page after moving an element off it asks nothing once '
        'the destination\'s result shows the element', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final move = movePatch('m', pageId: 'page-b');
      savedValue(await store.commit(strategyId, move));
      await answer(store, 'm', 2);
      await recordAll(store, [
        BaseArrived(
          pageReadOf(withOp(initialRows(), move), 'page-b'),
          session: await sessionOf(store),
        ),
      ]);
      savedValue(await store.commit(strategyId, pageDelete('del', 'page-a')));
      expect(
        (await syncOf(store)).views['del']!.state,
        isNot(isA<NeedsUser>()),
      );
    });

    test(
      'an element added and moved by accepted work onto a page a result shows '
      'deleted is drawn in one place',
      () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, threePages());
        savedValue(
          await store.commit(
            strategyId,
            elementAdd('add', elementId: 'e9', pageId: 'page-c'),
          ),
        );
        await answer(store, 'add', 1);
        savedValue(
          await store.commit(
            strategyId,
            movePatch('move', elementId: 'e9', pageId: 'page-a'),
          ),
        );
        await answer(store, 'move', 2);
        final server = withOp(threePages(), pageDelete('del', 'page-a'));
        await recordAll(store, [
          BaseArrived(headerReadOf(server), session: await sessionOf(store)),
        ]);
        final pages = await drawn(store);
        expect([
          for (final MapEntry(:key, :value) in pages.entries)
            if (value.contains('e9')) key,
        ], hasLength(lessThan(2)));
      },
    );

    test('an accepted move whose source page\'s result arrives first is '
        'drawn at the revision it was answered at', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final move = movePatch('m', pageId: 'page-b');
      savedValue(await store.commit(strategyId, move));
      await answer(store, 'm', 2);
      await recordAll(store, [
        BaseArrived(
          pageReadOf(withOp(initialRows(), move), 'page-a'),
          session: await sessionOf(store),
        ),
      ]);
      expect(
        elementOn(pageOf(await store.readPage(strategyId, 'page-b')), 'e1'),
        isA<LiveElement>().having((row) => row.revision, 'revision', 2),
      );
    });

    test('a listing that fails once ends a removal as not saved, and the '
        'queued add survives', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, elementAdd('add')));
      await store.close();
      var armed = false;
      store = await openCloudStore(
        WrappingEngine(
          MemoryEngine(storage),
          (lease) => ListingFailsOnceLease(lease, (at) => armed && at == area),
        ),
      );
      armed = true;
      expect(
        await store.editLibrary([const RemoveStrategy(strategyId)]),
        isA<NotSaved<LibraryEdited, LibraryRefusal>>(),
      );
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      expect((await syncOf(store)).queue.entries.map((entry) => entry.id), [
        'add',
      ]);
    });

    test(
      'a stored pending summary that turns out held sends a refresh',
      () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        savedValue(await store.commit(strategyId, elementAdd('add')));
        await store.close();
        final contents = editable(storage.contents);
        contents[area]![PendingName(5).name] = '{"version":99}';
        store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
        final refreshed = <StoreChange>[];
        final listening = store.changes.listen(refreshed.add);
        await store.readStrategy(strategyId);
        await Future<void>.delayed(Duration.zero);
        await listening.cancel();
        expect(
          refreshed.whereType<StrategyRefreshed>().map(
            (change) => change.summary.sync,
          ),
          [
            isA<KeptInCloud>().having(
              (sync) => sync.tally.standing,
              'standing',
              Standing.held,
            ),
          ],
        );
      },
    );

    test('discarding a queue while the numbers row is missing still answers '
        'held', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      final contents = editable(storage.contents);
      contents['library']!.remove('numbers');
      store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
      expect(
        savedValue(
          await store.discardUnreadableQueue(
            strategyId,
            const DiscardsUnsentWork(),
          ),
        ).sync,
        isA<KeptInCloud>().having(
          (sync) => sync.tally.standing,
          'standing',
          Standing.held,
        ),
      );
    });

    test('an unverified list entry is not equal to the same summary kept '
        'here', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      final listed = listOf(store).strategies.single;
      expect(listed.sync, isA<CloudUnverified>());
      expect(listed == listed.withSync(const KeptHere()), isFalse);
    });

    group('a move whose source page\'s result arrives first', () {
      StrategyRowSet seventeen() => strategyRows(
        elements: [
          element('e1', sortIndex: 17),
          element('e2'),
          element('e3', pageId: 'page-b'),
        ],
      );

      for (final (label, op, answered) in <(String, ElementPatchOp, bool)>[
        (
          'changing only the page, answered',
          const ElementPatchOp(
            opId: 'move',
            elementPublicId: 'e1',
            expectedElementRevision: 1,
            pagePublicId: 'page-b',
          ),
          true,
        ),
        (
          'with a payload and no sort index, answered',
          ElementPatchOp(
            opId: 'move',
            elementPublicId: 'e1',
            expectedElementRevision: 1,
            pagePublicId: 'page-b',
            payload: agentPayload('e1', const {
              'position': {'dx': 5, 'dy': 0},
            }),
          ),
          true,
        ),
        (
          'a complete patch, before its answer',
          ElementPatchOp(
            opId: 'move',
            elementPublicId: 'e1',
            expectedElementRevision: 1,
            pagePublicId: 'page-b',
            payload: agentPayload('e1', const {
              'position': {'dx': 5, 'dy': 0},
            }),
            sortIndex: 17,
          ),
          false,
        ),
      ]) {
        test('$label: drawn on its destination at its own place, warm and '
            'after a reopen', () async {
          final storage = MemoryStorage();
          var store = await openCloudStore(MemoryEngine(storage));
          await addCloud(store, seventeen());
          savedValue(await store.commit(strategyId, op));
          final sent = await claimAll(store);
          final server = withOp(seventeen(), sent.ops.single);
          if (answered) {
            await recordAll(store, [
              OpAnswered(
                sent.attempt,
                const AppliedAnswer('move', revision: 2),
              ),
            ]);
          }
          await recordAll(store, [
            BaseArrived(
              pageReadOf(server, 'page-a'),
              session: await sessionOf(store),
            ),
          ]);
          Future<void> check() async {
            final b = pageOf(await store.readPage(strategyId, 'page-b'));
            final drawn = elementOn(b, 'e1');
            expect(drawn, isA<LiveElement>());
            expect(
              (drawn as LiveElement).sortIndex,
              (server.element('e1')! as LiveElement).sortIndex,
            );
          }

          await check();
          await store.close();
          store = await openCloudStore(MemoryEngine(storage));
          await recordAll(store, [const AppRestarted(build: build)]);
          await check();
        });
      }
    });

    test('a page delete after a teammate added to the page is held, even when '
        'no page list has shown the page yet', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, pageAdd('add', 'page-c')));
      await answer(store, 'add', 2);
      var server = withOp(initialRows(), pageAdd('add', 'page-c'));
      await recordAll(store, [
        BaseArrived(
          pageReadOf(server, 'page-c'),
          session: await sessionOf(store),
        ),
      ]);
      savedValue(
        await store.commit(
          strategyId,
          pageDelete('del', 'page-c', expected: 2),
        ),
      );
      server = withOp(
        server,
        elementAdd('t', elementId: 'theirs', pageId: 'page-c'),
      );
      await recordAll(store, [
        BaseArrived(
          pageReadOf(server, 'page-c'),
          session: await sessionOf(store),
        ),
      ]);
      expect((await syncOf(store)).views['del']!.sendable, isFalse);
    });

    test('a page that a newer reader can now read brings the list in line '
        'with the page', () async {
      final storage = MemoryStorage();
      final first = await openCloudStore(MemoryEngine(storage));
      await addCloud(first, initialRows());
      await first.close();
      final blind = switch (await LibraryStore.open(
        MemoryEngine(storage),
        canRead: CanRead(element: (_) => false, lineupGroup: (_) => true),
        clock: fixedClock,
        build: build,
      )) {
        StoreOpened(:final store) => store,
        StoreNotOpened(:final problem) => fail('$problem'),
      };
      savedValue(await blind.rebuildSummary(strategyId));
      expect(listOf(blind).strategies.single.tallies['page-a']!.newer, 2);
      await blind.close();
      final store = await openCloudStore(MemoryEngine(storage));
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      final listed = listOf(store).strategies.single.tallies['page-a']!;
      expect(listed.newer, 0);
      expect(listed.items, page.elements.whereType<LiveElement>().length);
    });

    test('unloading a strategy keeps its session: results issued under it '
        'still apply when it is loaded again', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final session = await sessionOf(store);
      expect(await store.unload(strategyId), isA<Unloaded>());
      final server = withOp(
        initialRows(),
        elementAdd('t', elementId: 'theirs', pageId: 'page-a'),
      );
      final applied = await recordAll(store, [
        BaseArrived(pageReadOf(server, 'page-a'), session: session),
        BaseArrived(const StrategyGone(), session: session),
      ]);
      expect(applied.outcomes, everyElement(isA<ReportApplied>()));
      expect(
        elementOn(pageOf(await store.readPage(strategyId, 'page-a')), 'theirs'),
        isNotNull,
      );
      expect((await syncOf(store)).tally.standing, Standing.deletedOnServer);
    });

    test('a refused discard of a healthy queue keeps its session', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final session = await sessionOf(store);
      await store.discardUnreadableQueue(
        strategyId,
        const DiscardsUnsentWork(),
      );
      expect(await sessionOf(store), session);
    });

    test('unloading and reloading a strategy in the same session keeps a '
        'ready page delete ready', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, pageDelete('del', 'page-b')));
      expect((await syncOf(store)).views['del']!.sendable, isTrue);
      expect(await store.unload(strategyId), isA<Unloaded>());
      expect((await syncOf(store)).views['del']!.sendable, isTrue);
      final sent = await claimAll(store);
      expect(sent.ops.map((op) => op.opId), ['del']);
    });

    test('the unreadable-queue discard refuses a healthy queue and changes '
        'nothing', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      savedValue(await store.commit(strategyId, movePatch('drag')));
      final before = storage.contents;
      expect(
        await store.discardUnreadableQueue(
          strategyId,
          const DiscardsUnsentWork(),
        ),
        isA<Refused<StrategySummary, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<QueueNotHeld>(),
        ),
      );
      expect(sameContents(before, storage.contents), isTrue);
      expect((await syncOf(store)).queue.entries.map((e) => e.id), ['drag']);
    });

    test(
      'a row rebuilt from a stored move goes through the reader\'s check',
      () async {
        final storage = MemoryStorage();
        final first = await openCloudStore(MemoryEngine(storage));
        await addCloud(first, initialRows());
        const move = ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
        );
        savedValue(await first.commit(strategyId, move));
        await recordAll(first, [
          BaseArrived(
            pageReadOf(withOp(initialRows(), move), 'page-a'),
            session: await sessionOf(first),
          ),
        ]);
        await first.close();
        final blind = switch (await LibraryStore.open(
          MemoryEngine(storage),
          canRead: CanRead(element: (_) => false, lineupGroup: (_) => true),
          clock: fixedClock,
          build: build,
        )) {
          StoreOpened(:final store) => store,
          StoreNotOpened(:final problem) => fail('$problem'),
        };
        final page = pageOf(await blind.readPage(strategyId, 'page-b'));
        expect(
          page.elements.where((row) => row.publicId == 'e1'),
          everyElement(isA<UnreadableElement>()),
        );
        expect(
          listOf(blind).strategies.single.tallies['page-b']!.newer,
          page.elements.whereType<UnreadableElement>().length,
        );
        expect(page.elements.whereType<UnreadableElement>(), hasLength(2));
      },
    );

    group('the review bot', () {
      LiveElement onPage(String id, String page) => LiveElement(
        publicId: id,
        pagePublicId: page,
        payload: agentPayload(id, const {}),
        sortIndex: 0,
        revision: 1,
      );

      test('a page result carrying a row of another page is refused, and '
          'memory and disk stay as they were', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await store.close();
        store = await openCloudStore(MemoryEngine(storage));
        await recordAll(store, [const AppRestarted(build: build)]);
        final before = storage.contents;
        final result = await store.record(strategyId, [
          BaseArrived(
            PageRead(
              page: initialRows().page('page-a')!,
              elements: [onPage('stray', 'page-b')],
              lineupGroups: const [],
            ),
            session: await sessionOf(store),
          ),
        ]);
        expect(
          result,
          isA<Refused<Recorded, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<ResultOutOfPlace>(),
          ),
        );
        expect(sameContents(before, storage.contents), isTrue);
        final a = pageOf(await store.readPage(strategyId, 'page-a'));
        expect(a.elements.map((row) => row.publicId), ['e1', 'e2']);
      });

      test('a page list with settings for a page it does not list is '
          'refused, never thrown', () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, initialRows());
        final rows = initialRows();
        expect(
          await store.record(strategyId, [
            BaseArrived(
              HeaderRead(
                strategy: rows.strategy,
                pages: [rows.page('page-a')!],
                settings: rows.settings.toList(),
              ),
              session: await sessionOf(store),
            ),
          ]),
          isA<Refused<Recorded, CommitRefusal>>(),
        );
      });

      for (final (label, damage) in <(String, void Function(Contents))>[
        (
          'its summary is also missing',
          (contents) => contents['library']!.remove(summaryName(strategyId)),
        ),
        (
          'it is listed as unreadable',
          (contents) => contents[area]!['strategy'] = '{"broken":true}',
        ),
      ]) {
        test('with the numbers row missing, import is refused while a cloud '
            'strategy exists and $label', () async {
          final storage = MemoryStorage();
          var store = await openCloudStore(MemoryEngine(storage));
          await addCloud(store, initialRows());
          await store.close();
          final contents = editable(storage.contents);
          contents['library']!.remove('numbers');
          damage(contents);
          store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
          final other = strategyRows(elements: [element('x1')]);
          expect(
            await store.addCloudStrategy(
              HeaderRead(
                strategy: strategyRow(publicId: 'other'),
                pages: other.pages.toList(),
                settings: other.settings.toList(),
              ),
              const [],
            ),
            isA<Refused<StrategySummary, LibraryRefusal>>().having(
              (refused) => refused.reason,
              'reason',
              const NumbersUnreadable(),
            ),
          );
        });
      }

      test('the list counts the unplaced rows a page reports', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await store.close();
        final contents = editable(storage.contents);
        contents[area]![elementName('page-a', 'e1')] = '{"broken":true}';
        store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
        final page = pageOf(await store.readPage(strategyId, 'page-a'));
        expect(page.unplaced, hasLength(1));
        expect(
          listOf(store).strategies.single.tallies['page-a']!.damaged,
          page.unplaced.length,
        );
      });

      test(
        'a page that goes takes its unreadable settings row with it',
        () async {
          final storage = MemoryStorage();
          var store = await openCloudStore(MemoryEngine(storage));
          await addCloud(store, initialRows());
          await store.close();
          final contents = editable(storage.contents);
          final settingsKey = contents[area]!.keys.singleWhere(
            (key) =>
                key.startsWith('settings/') &&
                contents[area]![key]!.contains('page-b'),
          );
          contents[area]![settingsKey] = '{"broken":true}';
          final disk = MemoryStorage(contents);
          store = await openCloudStore(MemoryEngine(disk));
          await recordAll(store, [const AppRestarted(build: build)]);
          await recordAll(store, [
            BaseArrived(
              const PageGone('page-b'),
              session: await sessionOf(store),
            ),
          ]);
          expect(disk.contents[area]!.containsKey(settingsKey), isFalse);
        },
      );

      test('a full page result removes an unplaced row the server no longer '
          'has', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await store.close();
        final contents = editable(storage.contents);
        final key = elementName('page-a', 'gone');
        contents[area]![key] = '{"broken":true}';
        final disk = MemoryStorage(contents);
        store = await openCloudStore(MemoryEngine(disk));
        await recordAll(store, [const AppRestarted(build: build)]);
        await recordAll(store, [
          BaseArrived(
            pageReadOf(initialRows(), 'page-a'),
            session: await sessionOf(store),
          ),
        ]);
        expect(
          pageOf(await store.readPage(strategyId, 'page-a')).unplaced,
          isEmpty,
        );
        expect(disk.contents[area]!.containsKey(key), isFalse);
      });

      test('a shown row stored in two page groups holds the queue', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await store.close();
        final contents = editable(storage.contents);
        final groups = <String, Map<String, Object?>>{
          for (final key in contents[area]!.keys)
            if (key.startsWith('read/page/'))
              key: jsonDecode(contents[area]![key]!) as Map<String, Object?>,
        };
        final a = groups.values.firstWhere((g) => g['page'] == 'page-a');
        final bKey = groups.keys.firstWhere(
          (k) => groups[k]!['page'] == 'page-b',
        );
        final b = groups[bKey]!;
        final e1 = (a['rows']! as List<Object?>)
            .cast<List<Object?>>()
            .firstWhere((row) => row[0] == 'element:e1');
        b['rows'] = [
          ...b['rows']! as List<Object?>,
          ['element:e1', 'page-b', e1[2], e1[3]],
        ];
        contents[area]![bKey] = canonicalJson(b);
        store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
        expect(
          strategyOf(await store.readStrategy(strategyId)).sync,
          isA<CloudHeld>(),
        );
      });

      test(
        'a successful discard of an unreadable queue sends a change',
        () async {
          final storage = MemoryStorage();
          var store = await openCloudStore(MemoryEngine(storage));
          await addCloud(store, initialRows());
          await store.close();
          final contents = editable(storage.contents);
          contents[area]![PendingName(5).name] = '{"version":99}';
          store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
          final changes = <StoreChange>[];
          final listening = store.changes.listen(changes.add);
          savedValue(
            await store.discardUnreadableQueue(
              strategyId,
              const DiscardsUnsentWork(),
            ),
          );
          await Future<void>.delayed(Duration.zero);
          await listening.cancel();
          expect(changes.whereType<LibraryEdited>(), isNotEmpty);
        },
      );
    });

    group('the hold\'s edges', () {
      Future<(LibraryStore, MemoryStorage)> withAttempt(
        String name,
        Object? outcomeAt,
      ) async {
        final storage = MemoryStorage();
        final store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await store.close();
        final contents = editable(storage.contents);
        contents[area]![name] = canonicalJson({
          'version': 1,
          'clientId': clientId,
          'build': build,
          'at': 0,
          'ops': [movePatch('late', elementId: 'e2').toJson()],
          'outcome': {'failed': 'network', 'at': outcomeAt},
        });
        final disk = MemoryStorage(contents);
        return (await openCloudStore(MemoryEngine(disk)), disk);
      }

      test('an attempt failed at the last moment a date can hold', () async {
        final (store, _) = await withAttempt(
          AttemptName(9).name,
          8640000000000000,
        );
        expect(
          strategyOf(await store.readStrategy(strategyId)).sync,
          isA<CloudHeld>(),
        );
      });

      test('an attempt number too large to be a safe integer', () async {
        final (store, _) = await withAttempt('attempt/9999999999999999', 0);
        expect(
          strategyOf(await store.readStrategy(strategyId)).sync,
          isA<CloudHeld>(),
        );
      });

      test(
        'rebuilding the summary of a held strategy writes nothing',
        () async {
          final (store, disk) = await withAttempt(
            AttemptName(9).name,
            8640000000000000,
          );
          final before = disk.contents;
          expect(
            await store.rebuildSummary(strategyId),
            isA<Refused<StrategySummary, CommitRefusal>>(),
          );
          expect(sameContents(before, disk.contents), isTrue);
        },
      );

      test('a cloud strategy whose stored summary lacks its cloud field is '
          'still not filed into a folder', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await store.close();
        final contents = editable(storage.contents);
        final name = summaryName(strategyId);
        final json =
            (jsonDecode(contents['library']![name]!) as Map<String, Object?>)
              ..remove('cloud');
        contents['library']![name] = canonicalJson(json);
        final disk = MemoryStorage(contents);
        store = await openCloudStore(MemoryEngine(disk));
        savedValue(
          await store.editLibrary([
            PutFolder(ReadableFolder(publicId: 'f1', name: 'f1')),
          ]),
        );
        final before = disk.contents;
        expect(
          await store.editLibrary([const MoveStrategy(strategyId, 'f1')]),
          isA<Refused<LibraryEdited, LibraryRefusal>>(),
        );
        expect(sameContents(before, disk.contents), isTrue);
      });
    });

    test('import takes a page read the header does not list, as a later '
        'record does', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      final rows = initialRows();
      final more = strategyRows(
        pages: [...rows.pages, page('page-z', sortIndex: 2)],
        elements: [
          ...rows.elements,
          element('z1', pageId: 'page-z'),
        ],
      );
      expect(
        await store.addCloudStrategy(headerReadOf(rows), [
          ...pageReadsOf(rows),
          pageReadOf(more, 'page-z') as PageRead,
        ]),
        isA<Saved<StrategySummary, LibraryRefusal>>(),
      );
    });

    group('the list before a queue is opened', () {
      test('a clean stored cloud summary is unverified until its queue is '
          'opened, then it is good', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await store.close();
        store = await openCloudStore(MemoryEngine(storage));
        expect(listOf(store).strategies.single.sync, isA<CloudUnverified>());
        await store.readStrategy(strategyId);
        expect(
          listOf(store).strategies.single.sync,
          isA<KeptInCloud>().having(
            (sync) => sync.tally.standing,
            'standing',
            Standing.good,
          ),
        );
      });

      test('stored pending work shows at once', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        savedValue(await store.commit(strategyId, movePatch('m')));
        await store.close();
        store = await openCloudStore(MemoryEngine(storage));
        expect(
          listOf(store).strategies.single.sync,
          isA<KeptInCloud>().having((sync) => sync.tally.total, 'total', 1),
        );
      });

      test('a clean summary over a queue row from a newer build goes from '
          'unverified to held, never to good', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await store.close();
        final contents = editable(storage.contents);
        contents[area]![PendingName(5).name] = '{"version":99}';
        store = await openCloudStore(MemoryEngine(MemoryStorage(contents)));
        expect(listOf(store).strategies.single.sync, isA<CloudUnverified>());
        await store.readStrategy(strategyId);
        expect(
          listOf(store).strategies.single.sync,
          isA<KeptInCloud>().having(
            (sync) => sync.tally.standing,
            'standing',
            Standing.held,
          ),
        );
      });
    });
  });
}

Map<String, Object?> entryJson() => {
  'version': 1,
  'kind': 'op',
  'op': movePatch('other', elementId: 'e2').toJson(),
  'scope': {'page': 'page-a'},
  'authored': {'noRow': true},
  'authoredIn': 1,
  'authoredAt': 0,
  'retriedAfter': 0,
  'work': 'op',
  'refusal': null,
};

final class ListingFailsOnceLease extends ForwardingLease {
  ListingFailsOnceLease(super.inner, this.armed);

  final bool Function(String area) armed;
  bool failed = false;

  bool _failNow(String area) {
    if (failed || !armed(area)) return false;
    failed = true;
    return true;
  }

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      _failNow(area)
      ? const StorageFailed(DeviceFailure('the listing timed out'))
      : super.keys(area, prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async =>
      _failNow(area)
      ? const StorageFailed(DeviceFailure('the listing timed out'))
      : super.entries(area, prefix);
}

final class RefusingLease extends ForwardingLease {
  RefusingLease(super.inner, this.refuse);

  final bool Function(List<Change> changes) refuse;

  @override
  Future<Committing> commit(List<Change> changes) async => refuse(changes)
      ? const CommitRefused(DeviceFailure('the disk is full'))
      : super.commit(changes);
}
