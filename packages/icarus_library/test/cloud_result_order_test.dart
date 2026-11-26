import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:test/test.dart';

import 'cloud_life_forward_test.dart' show strategyLife;
import 'cloud_set_aside_test.dart' show laterLife, replaced, setAsideIds;
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'support.dart';

ResultPoint onNextConnection() {
  final now = tick();
  return ResultPoint(
    client: now.client,
    connection: now.connection + 1,
    snapshot: now.snapshot,
    serverTime: now.serverTime,
  );
}

ResultPoint at(int snapshot, int serverTime) => ResultPoint(
  client: testClient,
  connection: currentGeneration.connection,
  snapshot: snapshot,
  serverTime: serverTime,
);

ReadState readBack(ReadState list) {
  final shown = Shown.nothing.owingList(ResultAtOrAfter.anyResult);
  final groups = shownToGroups(switch (list) {
    ReadOwed(:final since) => shown.owingList(since),
    _ => shown,
  });
  return switch (shownFromGroups({
    for (final MapEntry(:key, :value) in groups.entries) key: jsonEncode(value),
  })) {
    ShownRead(:final shown) => shown.list,
    final other => fail('expected results, got $other'),
  };
}

void main() {
  group('results are ordered by their stamps', () {
    test('a page-gone answer from an earlier snapshot than the page already '
        'taken is dropped', () {
      final client = Client();
      final earlier = tick();
      client.arrive(pageReadOf(initialRows(), 'page-a'));
      final late = client.step(
        client.arrival(const PageGone('page-a'), at: earlier),
      );
      expect(notApplicable(late), isA<OlderResult>());
      expect(client.queue.shown.pages, contains('page-a'));
    });

    test('a page read from an earlier snapshot than one already taken is '
        'dropped, and the newer page stays as it was read', () {
      final client = Client();
      final earlier = tick();
      client.arrive(
        pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
      );
      final shown = client.queue.shown;
      final late = client.step(
        client.arrival(pageReadOf(initialRows(), 'page-a'), at: earlier),
      );
      expect(notApplicable(late), isA<OlderResult>());
      expect(client.queue.shown.content, shown.content);
      expect(client.queue.shown.fresh, shown.fresh);
    });

    test('nothing from before an adoption is taken after it: a page from the '
        'first stay in a life is dropped once the record has left the life '
        'and come back', () {
      final client = Client();
      final inFirstStay = tick();
      client.arrive(headerReadOf(replaced(initialRows())));
      expect(client.queue.shown.strategy?.life, laterLife);
      client.edit(movePatch('move'));
      client.arrive(pageReadOf(replaced(initialRows()), 'page-a'));
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(attempt, BatchRefusal.strategyReplaced, point: tick()),
      );
      client.arrive(headerReadOf(initialRows()));
      expect(client.queue.shown.strategy?.life, strategyLife);
      final late = client.step(
        client.arrival(
          pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
          at: inFirstStay,
        ),
      );
      expect(notApplicable(late), isA<StartedInAnotherLife>());
      expect(client.queue.shown.content.containsKey('page-a'), isFalse);
    });

    test('a list from before an adoption is not taken after it, though it '
        'shows the adopted life', () {
      final client = Client();
      final before = tick();
      client.arrive(headerReadOf(replaced(initialRows())));
      final late = client.step(
        client.arrival(headerReadOf(replaced(initialRows())), at: before),
      );
      expect(notApplicable(late), isA<StartedInAnotherLife>());
    });

    test('a result labelled with a session that ended is not taken, and the '
        'store writes nothing for it', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      final ended = await sessionOf(store);
      await recordAll(store, [const ConnectionLost(), reconnected()]);
      final before = Map.of(storage.contents);
      final recorded = await store.record(testAccount, strategyId, [
        BaseArrived(
          pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
          session: ended,
          point: tick(),
        ),
      ]);
      expect(
        (recorded as Saved<Recorded, CommitRefusal>).value.outcomes.single,
        isA<ReportNotApplicable>().having(
          (outcome) => outcome.why,
          'why',
          isA<FromAnEndedSession>(),
        ),
      );
      expect(storage.contents.keys, before.keys);
    });
  });

  group('a session belongs to one connection', () {
    test('the first result from a later connection opens a session and is '
        'taken in it; a result from the earlier connection is then from an '
        'ended session', () {
      final client = Client();
      client.must(reconnected());
      final session = client.queue.session.number;
      final onOld = tick();
      final step = client.step(
        client.arrival(
          pageReadOf(withOp(initialRows(), movePatch('t', x: 9)), 'page-a'),
          at: onNextConnection(),
        ),
      );
      expect(step, isA<Stepped>().having((it) => it.tookResult, 'took', true));
      expect((step as Stepped).effects, contains(SessionOpened(session + 1)));
      expect(client.queue.session.number, session + 1);
      expect(client.queue.session.connected, isTrue);
      final late = client.step(
        client.arrival(headerReadOf(initialRows()), at: onOld),
      );
      expect(notApplicable(late), isA<FromAnEndedSession>());
    });

    test('the connection event for a generation a result already opened does '
        'not open another session', () {
      final client = Client();
      client.must(reconnected());
      final next = onNextConnection();
      client.arrive(headerReadOf(initialRows()), at: next);
      final session = client.queue.session.number;
      client.must(ConnectionReturned(next.generation));
      expect(client.queue.session.number, session);
      expect(
        notApplicable(
          client.step(
            ConnectionReturned(
              Generation(client: testClient, connection: next.connection - 1),
            ),
          ),
        ),
        isA<ConnectionAlreadyEnded>(),
      );
    });

    test('an answer from an ended connection closes its attempt as lost, and '
        'the op is sent again under the same id', () {
      final client = Client();
      client.must(reconnected());
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      final onOld = tick();
      client.must(reconnected());
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('move', revision: 2, life: fixtureLife),
          point: onOld,
        ),
      );
      expect(
        client.queue.attempts[attempt]?.outcome,
        isA<AttemptFailed>().having(
          (failed) => failed.cause,
          'cause',
          const TransportCut(TransportFailure.answeredOnEndedConnection),
        ),
      );
      expect([for (final entry in client.queue.entries) entry.id], ['move']);
      expect(client.queue.landed, isEmpty);
      client.clock = now.add(const Duration(seconds: 1));
      final again = client.claim(['move']);
      expect(again, isNot(attempt));
      expect([for (final op in client.lastSent()) op.opId], ['move']);
      client.must(
        OpAnswered(
          again,
          const NoopAnswer(
            'move',
            revision: 2,
            life: fixtureLife,
            replay: NoopReplay.appliedWhenFirstReceived,
          ),
          point: tick(),
        ),
      );
      expect(client.queue.entries, isEmpty);
    });
  });

  group('a refusal is paid by content, a later session, or a read asked for '
      'after it', () {
    test('after a STRATEGY_REPLACED that names no life, a list requested '
        'before the refusal pays nothing, one requested after it does, and '
        'the missing life is reported', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      final requestedBefore = client.queue.session.sequence;
      final refused = client.step(
        BatchRefused(attempt, BatchRefusal.strategyReplaced, point: tick()),
      );
      expect(
        (refused as Stepped).effects,
        contains(ReportReplacedWithoutLife(attempt)),
      );
      client.queue = refused.queue;
      final early = client.step(
        client.arrival(
          headerReadOf(replaced(initialRows())),
          requestedAt: requestedBefore,
        ),
      );
      expect(notApplicable(early), isA<OlderResult>());
      client.arrive(headerReadOf(replaced(initialRows())));
      expect(client.queue.shown.strategy?.life, laterLife);
      expect(setAsideIds(client.queue), ['move']);
    });

    test('a list showing the life the refusal named pays it, though it was '
        'requested before the refusal', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      final requestedBefore = client.queue.session.sequence;
      client.must(
        BatchRefused(
          attempt,
          BatchRefusal.strategyReplaced,
          currentLife: laterLife,
          point: tick(),
        ),
      );
      client.must(
        client.arrival(
          headerReadOf(replaced(initialRows())),
          requestedAt: requestedBefore,
        ),
      );
      expect(client.queue.shown.strategy?.life, laterLife);
    });

    test('a list from a later connection pays it', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(attempt, BatchRefusal.strategyReplaced, point: tick()),
      );
      client.must(
        client.arrival(
          headerReadOf(replaced(initialRows())),
          at: onNextConnection(),
          requestedAt: -1,
        ),
      );
      expect(client.queue.shown.strategy?.life, laterLife);
    });

    test('a refused read leaves a refusal debt as it was, whether or not it '
        'would have paid it', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      final requestedBefore = client.queue.session.sequence;
      client.must(
        BatchRefused(attempt, BatchRefusal.strategyReplaced, point: tick()),
      );
      final owed = (client.queue.shown.list as ReadOwed).since;
      client.must(
        ResultRefused(
          page: null,
          problem: 'unreadable',
          session: client.queue.session.number,
          point: tick(),
          requestedAt: requestedBefore,
        ),
      );
      expect((client.queue.shown.list as ReadRefused).since, owed);
      client.must(client.readRefused(null, 'unreadable'));
      expect((client.queue.shown.list as ReadRefused).since, owed);
    });
  });

  group('a write counts as shown only by a result at or after its answer in '
      'both snapshot and time', () {
    test('a page without our added element, at a later snapshot but an '
        'earlier time than the answer, does not count as showing it gone', () {
      final client = Client();
      client.edit(elementAdd('add'));
      final attempt = client.claim(['add']);
      final answered = tick();
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('add', revision: 1, life: fixtureLife),
          point: answered,
        ),
      );
      expect(client.queue.landed, hasLength(1));
      client.arrive(
        pageReadOf(initialRows(), 'page-a'),
        at: at(answered.snapshot + 1, answered.serverTime! - 1),
      );
      expect(client.queue.landed.single.shownWithout, isFalse);
      client.arrive(
        pageReadOf(initialRows(), 'page-a'),
        at: at(answered.snapshot + 2, answered.serverTime! + 1),
      );
      expect(client.queue.landed.single.shownWithout, isTrue);
    });
  });

  group('marks stored by earlier builds', () {
    test('an owed list stored as a session and step reads as owed from the '
        'start of that session, and any result of the session or a later one '
        'pays it, snapshot 0 of client 1 included', () {
      final groups = shownToGroups(
        Shown.nothing.owingList(
          const ResultAtOrAfter(
            ResultOrder(session: 3, client: 2, snapshot: 9),
          ),
        ),
      );
      final strategy = groups[null]!;
      final old = {
        ...strategy,
        'read': {
          'owedSince': {'session': 3, 'step': 7},
        },
      };
      final read = switch (shownFromGroups({
        for (final MapEntry(:key, :value) in groups.entries)
          key: jsonEncode(key == null ? old : value),
      })) {
        ShownRead(:final shown) => shown.list,
        final other => fail('expected results, got $other'),
      };
      expect(
        read,
        const ReadOwed(
          since: ResultAtOrAfter(
            ResultOrder(session: 3, client: 0, snapshot: 0),
          ),
        ),
      );
      final base = headerReadOf(initialRows());
      for (final (session, client, snapshot) in [
        (3, 1, 0),
        (3, 1, 5),
        (4, 1, 0),
      ]) {
        final arrival = Arrival(
          order: ResultOrder(
            session: session,
            client: client,
            snapshot: snapshot,
          ),
          point: ResultPoint(client: client, connection: 0, snapshot: snapshot),
        );
        expect(paidBy(read, arrival, base), isTrue, reason: '$arrival');
      }
      expect(
        paidBy(
          read,
          Arrival(
            order: const ResultOrder(session: 2, client: 1, snapshot: 99),
            point: const ResultPoint(client: 1, connection: 0, snapshot: 99),
          ),
          base,
        ),
        isFalse,
      );
    });

    test('a debt after a refusal and a landed answer survive a write and a '
        'read', () {
      const refusal = AfterRefusal(
        session: 4,
        point: ResultPoint(
          client: 2,
          connection: 3,
          snapshot: 17,
          serverTime: 1700,
        ),
        step: 5,
        evidence: RowAtLeast(ElementTarget('e1'), life: 12, revision: 4),
      );
      expect(
        readBack(const ReadOwed(since: refusal)),
        const ReadOwed(since: refusal),
      );
      const named = AfterRefusal(
        session: 4,
        point: ResultPoint(client: 2, connection: 3, snapshot: 17),
        step: 5,
        evidence: StrategyLifeAtLeast(laterLife),
      );
      expect(
        readBack(const ReadOwed(since: named)),
        const ReadOwed(since: named),
      );
    });
  });

  group('kept from the result-source review rounds', () {
    test('an edit whose read names no life is of another life than a record '
        'that has one: it is set aside, never applied', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      final page =
          ((await store.readPage(strategyId, 'page-a')) as Found<PageContent>)
              .value;
      final lifeless = PageContent(
        strategyLife: null,
        page: page.page,
        settings: page.settings,
        elements: page.elements,
        lineupGroups: page.lineupGroups,
        unknownKinds: page.unknownKinds,
        unplaced: page.unplaced,
        foreignNames: page.foreignNames,
      );
      expect(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('late', x: 77),
          seen: lifeless,
        ),
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          isA<EditOfAReplacedStrategy>(),
        ),
      );
      expect(setAsideIds((await syncOf(store)).queue), ['late']);
    });

    test(
      'an op id already kept aside cannot be used again, on either path',
      () {
        final client = Client();
        client.must(
          UserEdited(
            (client.editEvent(movePatch('kept')) as UserEdited).edit,
            madeOn: laterLife,
          ),
        );
        expect(setAsideIds(client.queue), ['kept']);
        expect(
          notApplicable(
            client.step(
              UserEdited(
                (client.editEvent(movePatch('kept', elementId: 'e2'))
                        as UserEdited)
                    .edit,
                madeOn: laterLife,
              ),
            ),
          ),
          isA<OpIdTaken>(),
        );
        expect(
          notApplicable(
            client.step(client.editEvent(movePatch('kept', elementId: 'e2'))),
          ),
          isA<OpIdTaken>(),
        );
        client.edit(movePatch('queued', elementId: 'e2'));
        expect(
          notApplicable(
            client.step(
              UserEdited(
                (client.editEvent(movePatch('queued', elementId: 'e3'))
                        as UserEdited)
                    .edit,
                madeOn: laterLife,
              ),
            ),
          ),
          isA<OpIdTaken>(),
        );
      },
    );
  });

  group('a commit takes the life from the read it was built from', () {
    test(
      'an edit built from a read made before the replacement is set aside, '
      'though it is committed after the record adopted the replacement',
      () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, initialRows());
        await recordAll(store, [const AppRestarted(build: build)]);
        final seen =
            (await store.readPage(strategyId, 'page-a')) as Found<PageContent>;
        await recordAll(store, [
          BaseArrived(
            headerReadOf(replaced(initialRows())),
            session: await sessionOf(store),
            point: tick(),
          ),
        ]);
        final committed = await store.commitAs(
          testAccount,
          strategyId,
          movePatch('late', x: 77),
          seen: seen.value,
        );
        expect(
          committed,
          isA<Refused<Committed, CommitRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            isA<EditOfAReplacedStrategy>(),
          ),
        );
        expect(setAsideIds((await syncOf(store)).queue), ['late']);
      },
    );
  });
}
