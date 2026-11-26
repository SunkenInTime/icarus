import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart'
    show ShownRead, shownFromGroups, shownToGroups;
import 'package:test/test.dart';

import 'cloud_lives_test.dart' show asTheServerHoldsIt, newerLife;
import 'cloud_set_aside_test.dart' show replaced;
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

PendingState stateIn(Client client, String opId) => client.view(opId).state;

PageRead pageAWithout(String elementId) {
  final rows = initialRows();
  return PageRead(
    page: rows.page('page-a')!,
    elements: [
      for (final row in rows.elementsOn('page-a'))
        if (row.publicId != elementId) row,
    ],
    lineupGroups: rows.lineupGroupsOn('page-a').toList(),
  );
}

LiveElement e1Of({
  required int revision,
  required int life,
  Map<String, Object?> fields = const {},
}) => LiveElement(
  publicId: 'e1',
  pagePublicId: 'page-a',
  payload: agentPayload('e1', fields),
  sortIndex: 0,
  revision: revision,
  unknownFields: jsonObject({'createdAt': life}),
);

const answerTime = 1795000000000000000;

var _from = 0;
var _on = 0;

ResultPoint pointAt(int snapshot, {int? time, int later = 0}) => ResultPoint(
  client: testClient,
  connection: _on + later,
  snapshot: _from + snapshot,
  serverTime: time ?? answerTime + snapshot,
);

Client connectedOn() {
  final client = Client();
  client.must(reconnected());
  _from = lastPoint.snapshot;
  _on = currentGeneration.connection;
  return client;
}

BaseArrived arrivalAt(
  Client client,
  ArrivedBase base,
  ResultPoint point, {
  int? requestedAt,
}) => BaseArrived(
  base,
  session: client.queue.session.number,
  point: point,
  requestedAt: requestedAt,
);

ResultRefused refusalAt(
  Client client,
  String? page,
  ResultPoint point, {
  int? requestedAt,
}) => ResultRefused(
  page: page,
  problem: 'unreadable',
  session: client.queue.session.number,
  point: point,
  requestedAt: requestedAt,
);

Arrival arrivalOf(ResultOrder order, {int? time, int? requestedAt}) => Arrival(
  order: order,
  point: ResultPoint(
    client: order.client,
    connection: 1,
    snapshot: order.snapshot,
    serverTime: time,
  ),
  requestedAt: requestedAt,
);

ResultOrder orderAt(int snapshot, {int session = 3, int client = 1}) =>
    ResultOrder(session: session, client: client, snapshot: snapshot);

PageRead pageA([StrategyRowSet? rows]) =>
    pageReadOf(rows ?? initialRows(), 'page-a') as PageRead;

void main() {
  group('a session opened by a stamp survives', () {
    test('an answer for no attempt still opens the session its later '
        'connection starts', () {
      final client = connectedOn();
      final before = client.queue.session.number;
      final step = client.step(
        OpAnswered(
          99,
          const AppliedAnswer('nothing', revision: 2, life: fixtureLife),
          point: pointAt(5, later: 1),
        ),
      );
      expect(notApplicable(step), isA<NoSuchAttempt>());
      expect(client.queue.session.number, greaterThan(before));
      expect(client.queue.session.generation, pointAt(5, later: 1).generation);
    });

    test('a result older than one taken still opens the session of its '
        'later connection', () {
      final client = connectedOn();
      client.must(arrivalAt(client, pageA(), pointAt(20)));
      final before = client.queue.session.number;
      client.must(arrivalAt(client, pageA(), pointAt(30, later: 1)));
      expect(client.queue.session.number, greaterThan(before));
    });

    test('every page of an add is taken when the pages come from a later '
        'connection than the page list', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      final rows = initialRows();
      savedValue(
        await store.addCloudStrategy(
          testAccount,
          StampedRead(headerReadOf(rows), pointAt(1)),
          [
            for (final (index, page) in pageReadsOf(rows).indexed)
              StampedRead(page, pointAt(10 + index, later: 1)),
          ],
        ),
      );
      for (final page in ['page-a', 'page-b']) {
        expect(
          (await syncOf(store)).queue.shown.pageRead(page),
          const ReadThisSession(),
          reason: page,
        );
      }
    });

    test('client 0 is not a client, even to a session no connection has '
        'answered yet', () {
      final client = connectedOn();
      client.must(const AppRestarted(build: build));
      expect(client.queue.session.generation, isNull);
      expect(
        notApplicable(
          client.step(
            arrivalAt(
              client,
              pageA(),
              const ResultPoint(client: 0, connection: 1, snapshot: 9),
            ),
          ),
        ),
        isA<FromAnEndedSession>(),
      );
      expect(client.queue.session.generation, isNull);
    });

    test(
      'a later client with its connection and snapshot counting from the '
      'start again opens a session and is taken after the earlier client',
      () {
        final client = connectedOn();
        client.must(arrivalAt(client, pageA(), pointAt(50)));
        final before = client.queue.session.number;
        client.must(
          arrivalAt(
            client,
            pageA(withOp(initialRows(), movePatch('t', x: 3))),
            const ResultPoint(
              client: 2,
              connection: 1,
              snapshot: 1,
              serverTime: answerTime + 99,
            ),
          ),
        );
        expect(client.queue.session.number, greaterThan(before));
        expect(client.queue.shown.pagesTaken['page-a']?.client, 2);
      },
    );
  });

  group('a refusal is ordered like a result', () {
    test('a page refusal older than the page result taken changes nothing', () {
      final client = connectedOn();
      client.must(arrivalAt(client, pageA(), pointAt(22)));
      expect(
        notApplicable(client.step(refusalAt(client, 'page-a', pointAt(20)))),
        isA<OlderResult>(),
      );
      expect(client.queue.shown.pageRead('page-a'), const ReadThisSession());
    });

    test('a refusal at the point of the result taken changes nothing', () {
      final client = connectedOn();
      client.must(arrivalAt(client, pageA(), pointAt(22)));
      expect(
        notApplicable(client.step(refusalAt(client, 'page-a', pointAt(22)))),
        isA<SameResult>(),
      );
    });

    test('a page result older than a refusal taken is not taken', () {
      final client = connectedOn();
      client.must(refusalAt(client, 'page-a', pointAt(22)));
      expect(
        notApplicable(client.step(arrivalAt(client, pageA(), pointAt(20)))),
        isA<OlderResult>(),
      );
      expect(client.queue.shown.pageRead('page-a'), isA<ReadRefused>());
    });

    test('an older refusal after a newer one changes nothing, for a page '
        'and for the list', () {
      for (final page in ['page-a', null]) {
        final client = connectedOn();
        ResultRefused refusal(String problem, int snapshot) => ResultRefused(
          page: page,
          problem: problem,
          session: client.queue.session.number,
          point: pointAt(snapshot),
        );
        client.must(refusal('newer', 22));
        expect(
          notApplicable(client.step(refusal('older', 20))),
          isA<OlderResult>(),
          reason: '$page',
        );
        final held = page == null
            ? client.queue.shown.list
            : client.queue.shown.pageRead(page);
        expect((held as ReadRefused).problem, 'newer', reason: '$page');
      }
    });

    test('a list refusal older than the list taken changes nothing', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(22)));
      expect(
        notApplicable(client.step(refusalAt(client, null, pointAt(20)))),
        isA<OlderResult>(),
      );
      expect(client.queue.shown.list, const ReadThisSession());
    });

    test('a refused page read that is not causal leaves a refusal debt as it '
        'was, a causal one is paid by a result at or after it, and so is a '
        'page already refused', () {
      final client = connectedOn();
      final move = movePatch('move', x: 40);
      client.edit(move);
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            asTheServerHoldsIt(move, life: newerLife),
          ),
          point: pointAt(4),
        ),
      );
      final owed =
          (client.queue.shown.pageRead('page-a') as ReadOwed).since
              as AfterRefusal;
      client.must(
        refusalAt(client, 'page-a', pointAt(10), requestedAt: owed.step - 1),
      );
      expect(
        (client.queue.shown.pageRead('page-a') as ReadRefused).since,
        owed,
      );
      client.must(
        refusalAt(client, 'page-a', pointAt(11), requestedAt: owed.step),
      );
      expect(
        (client.queue.shown.pageRead('page-a') as ReadRefused).since,
        ResultAtOrAfter(client.queue.session.orderOf(pointAt(11))),
      );
      client.must(refusalAt(client, 'page-a', pointAt(12)));
      expect(
        (client.queue.shown.pageRead('page-a') as ReadRefused).since,
        ResultAtOrAfter(client.queue.session.orderOf(pointAt(12))),
      );
    });

    test('a second strategy-replaced answer for the same attempt changes '
        'nothing', () {
      final client = connectedOn();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      final refused = BatchRefused(
        attempt,
        BatchRefusal.strategyReplaced,
        point: pointAt(5),
        currentLife: newerLife,
      );
      client.must(refused);
      final owed = client.queue.shown.list;
      client.must(arrivalAt(client, pageA(), pointAt(6)));
      expect(notApplicable(client.step(refused)), isA<AnswerAlreadyHandled>());
      expect(client.queue.shown.list, owed);
    });
  });

  group('equal order', () {
    test('a result at the point of one taken is the same answer and changes '
        'nothing', () {
      final client = connectedOn();
      client.must(arrivalAt(client, pageA(), pointAt(22)));
      expect(
        notApplicable(
          client.step(
            arrivalAt(
              client,
              pageA(withOp(initialRows(), movePatch('t', x: 9))),
              pointAt(22),
            ),
          ),
        ),
        isA<SameResult>(),
      );
    });

    test('a page result at the point of the list that adopted a later life '
        'is taken', () {
      final client = connectedOn();
      final adopted = pointAt(30);
      client.must(
        arrivalAt(client, headerReadOf(replaced(initialRows())), adopted),
      );
      expect(client.queue.shown.fence, client.queue.session.orderOf(adopted));
      expect(
        client.step(
          arrivalAt(
            client,
            pageReadOf(replaced(initialRows()), 'page-a'),
            adopted,
          ),
        ),
        isA<Stepped>(),
      );
    });
  });

  group('debts combine', () {
    final rowA = AfterRefusal(
      session: 3,
      point: const ResultPoint(client: testClient, connection: 1, snapshot: 5),
      step: 4,
      evidence: const RowAtLeast(
        ElementTarget('e1'),
        life: fixtureLife,
        revision: 3,
      ),
    );
    final rowB = AfterRefusal(
      session: 3,
      point: const ResultPoint(client: testClient, connection: 1, snapshot: 6),
      step: 5,
      evidence: const RowAtLeast(
        ElementTarget('e2'),
        life: fixtureLife,
        revision: 3,
      ),
    );
    PageRead showing({required int e1, required int e2}) => pageA(
      initialRows().withRows([
        element('e1', revision: e1),
        element('e2', revision: e2),
      ]),
    );

    test('a second refusal on a page keeps the first one\'s evidence: only a '
        'result showing both pays', () {
      final shown = Shown.nothing
          .owingPage('page-a', rowA)
          .owingPage('page-a', rowB);
      final since = (shown.pageRead('page-a') as ReadOwed).since;
      final stale = arrivalOf(orderAt(7));
      expect(since.paidBy(stale, showing(e1: 3, e2: 1)), isFalse);
      expect(since.paidBy(stale, showing(e1: 1, e2: 3)), isFalse);
      expect(since.paidBy(stale, showing(e1: 3, e2: 3)), isTrue);
    });

    test('a header-level refusal keeps the lives an earlier one named', () {
      final shown = Shown.nothing
          .owingListPast(fixtureLife, rowA, named: newerLife)
          .owingListPast(fixtureLife, rowB);
      expect(namedLifeOf(shown.list), newerLife);
      expect((shown.list as ReadOwed).unlessLife, fixtureLife);
    });

    test('two orders owed combine into the later one, in either order', () {
      for (final (first, second) in [
        (orderAt(5), orderAt(9)),
        (orderAt(9), orderAt(5)),
      ]) {
        final shown = Shown.nothing
            .owingList(ResultAtOrAfter(first))
            .owingList(ResultAtOrAfter(second));
        expect((shown.list as ReadOwed).since, ResultAtOrAfter(orderAt(9)));
      }
    });

    test('combined debts survive a write and a read', () {
      final shown = Shown.nothing
          .owingList(ResultAtOrAfter(orderAt(9)))
          .owingList(rowA)
          .owingList(rowB);
      final stored = shownFromGroups({
        for (final MapEntry(:key, :value) in shownToGroups(shown).entries)
          key: jsonEncode(value),
      });
      expect((stored as ShownRead).shown.list, shown.list);
    });
  });

  group('faults the server should never send are reported', () {
    test('a row_replaced without the server\'s row is reported', () {
      final client = connectedOn();
      client.edit(movePatch('move', x: 40));
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
          point: pointAt(5),
        ),
      );
      expect(
        client.effects,
        contains(const ReportReplacedWithoutEvidence('move')),
      );
    });
  });

  group('edit access', () {
    test('a confirmation from an ended connection is not recorded', () {
      final client = connectedOn();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(
          attempt,
          BatchRefusal.editAccessRemoved,
          point: pointAt(4),
        ),
      );
      final onTheEndedConnection = pointAt(5);
      client.must(ConnectionReturned(pointAt(6, later: 1).generation));
      expect(
        notApplicable(
          client.step(
            EditAccessConfirmed(
              afterAttempt: attempt,
              session: client.queue.session.number,
              point: onTheEndedConnection,
            ),
          ),
        ),
        isA<FromAnEndedSession>(),
      );
      expect(standingOf(client.queue), Standing.editAccessLost);
    });
  });

  group('our own answers', () {
    test('a read at an earlier server time does not make a page fresh after '
        'a reconnect, and a read at or after the answer\'s time does', () {
      final mark = AfterAnswer(orderAt(10, session: 3), serverTime: 200);
      final touched = Shown.nothing.touched(
        ['page-a'],
        list: false,
        mark: mark,
      );
      final reconnected = touched.inNewSession().fresh;
      for (final (time, fresh) in [(190, false), (200, true), (210, true)]) {
        expect(
          reconnected
              .afterPage(
                'page-a',
                gone: false,
                arrival: arrivalOf(orderAt(1, session: 4), time: time),
              )
              .pageFreshFor('page-a'),
          fresh,
          reason: 'time $time',
        );
      }
    });

    test('a whole-row edit behind our own answer waits for a page read at or '
        'after that answer before deciding its row is missing', () {
      final client = connectedOn();
      client.must(arrivalAt(client, pageA(), pointAt(5)));
      client.edit(movePatch('first', x: 10));
      final attempt = client.claim(['first']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('first', revision: 3, life: fixtureLife),
          point: pointAt(10),
        ),
      );
      client.edit(movePatch('second', x: 20, expected: 3));
      client.must(arrivalAt(client, pageAWithout('e1'), pointAt(8)));
      expect(stateIn(client, 'second'), isNot(isA<NeedsUser>()));
      client.must(arrivalAt(client, pageAWithout('e1'), pointAt(12)));
      expect(stateIn(client, 'second'), isA<NeedsUser>());
    });
  });

  group('what settles a debt', () {
    test('order compares client before snapshot', () {
      expect(orderAt(9, client: 1).isBefore(orderAt(1, client: 2)), isTrue);
      expect(orderAt(1, client: 2).isBefore(orderAt(9, client: 1)), isFalse);
    });

    test('a result at the order owed pays it', () {
      expect(
        ResultAtOrAfter(orderAt(5)).paidBy(arrivalOf(orderAt(5)), null),
        isTrue,
      );
      expect(
        ResultAtOrAfter(orderAt(5)).paidBy(arrivalOf(orderAt(4)), null),
        isFalse,
      );
    });

    test('a refusal debt: a read with no request step is not causal, a read '
        'requested at the refusal\'s step is', () {
      final owed = AfterRefusal(session: 3, point: pointAt(5), step: 4);
      expect(owed.paidBy(arrivalOf(orderAt(9)), null), isFalse);
      expect(owed.paidBy(arrivalOf(orderAt(9), requestedAt: 3), null), isFalse);
      expect(owed.paidBy(arrivalOf(orderAt(9), requestedAt: 4), null), isTrue);
      expect(owed.paidBy(arrivalOf(orderAt(1, session: 4)), null), isTrue);
    });

    test(
      'a row\'s content pays a refusal debt by life first, then revision',
      () {
        PageRead e1At({required int revision, required int life}) => pageA(
          initialRows().withRows([e1Of(revision: revision, life: life)]),
        );
        final stale = arrivalOf(orderAt(1));
        AfterRefusal owing({int? life}) => AfterRefusal(
          session: 3,
          point: pointAt(5),
          step: 4,
          evidence: RowAtLeast(
            const ElementTarget('e1'),
            life: life,
            revision: 3,
          ),
        );
        for (final (life, shownLife, revision, pays) in [
          (fixtureLife, newerLife, 1, true),
          (newerLife, fixtureLife, 9, false),
          (fixtureLife, fixtureLife, 3, true),
          (fixtureLife, fixtureLife, 2, false),
          (null, fixtureLife, 3, true),
          (null, fixtureLife, 2, false),
        ]) {
          expect(
            owing(
              life: life,
            ).paidBy(stale, e1At(revision: revision, life: shownLife)),
            pays,
            reason: 'owed life $life, shown $shownLife at $revision',
          );
        }
        expect(owing(life: fixtureLife).paidBy(stale, pageA()), isFalse);
      },
    );

    test('an answer is reached by order and time: each leg counts, equal '
        'passes, a read with no time never reaches a timed answer, and an '
        'answer with no time asks only for order', () {
      final timed = AfterAnswer(orderAt(10), serverTime: 200);
      for (final (snapshot, time, reached) in [
        (9, 300, false),
        (11, 100, false),
        (10, 200, true),
        (11, 201, true),
        (11, null, false),
      ]) {
        expect(
          timed.reachedBy(arrivalOf(orderAt(snapshot), time: time)),
          reached,
          reason: 'snapshot $snapshot, time $time',
        );
      }
      final untimed = AfterAnswer(orderAt(10));
      expect(untimed.reachedBy(arrivalOf(orderAt(10))), isTrue);
      expect(untimed.reachedBy(arrivalOf(orderAt(9), time: 999)), isFalse);
    });
  });

  group('the stale read cannot make a held page delete go', () {
    test('row_replaced on the page, a read from before the answer, the '
        'delete still waits; a read after it, the delete asks the user', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
      client.must(arrivalAt(client, pageA(), pointAt(3)));
      final move = movePatch('move', x: 40);
      client.edit(move);
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            asTheServerHoldsIt(move, life: newerLife),
          ),
          point: pointAt(10),
        ),
      );
      client.must(const UserDiscarded('move'));
      client.edit(pageDelete('drop', 'page-a'));
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(8)));
      expect(
        notApplicable(client.step(arrivalAt(client, pageA(), pointAt(8)))),
        isA<OlderResult>(),
      );
      expect(stateIn(client, 'drop'), isNot(isA<NeedsUser>()));
      expect(client.view('drop').sendable, isFalse);
      final now = initialRows().withRows([
        e1Of(revision: 5, life: newerLife, fields: const {'rotation': 90}),
      ]);
      client.must(arrivalAt(client, headerReadOf(now), pointAt(12)));
      client.must(arrivalAt(client, pageA(now), pointAt(12)));
      expect(
        stateIn(client, 'drop'),
        const NeedsUser(DeleteHeld(HeldDeleteCause.pageChanged)),
      );
    });
  });
}
