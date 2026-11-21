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
      const NeedsUser(WindowClosed()),
    );
    await store.close();
    clock = fixedClock();
    store = await openCloudStore(MemoryEngine(storage), clock: () => clock);
    expect(
      (await syncOf(store)).views['move']!.state,
      const NeedsUser(WindowClosed()),
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
}

Map<String, Object?> entryJson() => {
  'version': 1,
  'kind': 'op',
  'op': movePatch('other', elementId: 'e2').toJson(),
  'scope': {'page': 'page-a'},
  'authored': {'noRow': true},
  'authoredIn': 1,
  'retriedAfter': 0,
  'work': 'op',
  'refusal': null,
};

final class RefusingLease extends ForwardingLease {
  RefusingLease(super.inner, this.refuse);

  final bool Function(List<Change> changes) refuse;

  @override
  Future<Committing> commit(List<Change> changes) async => refuse(changes)
      ? const CommitRefused(DeviceFailure('the disk is full'))
      : super.commit(changes);
}
