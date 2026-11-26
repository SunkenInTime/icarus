import 'package:icarus_library/icarus_library.dart';
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
  requestedIn: order.session,
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

    test('the first result at a refused point is taken and pays the '
        'refusal, for a page and for the list', () {
      for (final page in ['page-a', null]) {
        final client = connectedOn();
        client.must(refusalAt(client, page, pointAt(22)));
        client.must(
          arrivalAt(
            client,
            page == null ? headerReadOf(initialRows()) : pageA(),
            pointAt(22),
          ),
        );
        expect(
          page == null
              ? client.queue.shown.list
              : client.queue.shown.pageRead(page),
          const ReadThisSession(),
          reason: '$page',
        );
      }
    });

    test('a refusal moves no content mark: the taken order stays with the '
        'content, and a refusal older than the last refusal is dropped', () {
      final client = connectedOn();
      client.must(arrivalAt(client, pageA(), pointAt(10)));
      final content = client.queue.shown.pagesTaken['page-a'];
      client.must(refusalAt(client, 'page-a', pointAt(22)));
      expect(client.queue.shown.pagesTaken['page-a'], content);
      expect(
        client.queue.shown.pagesRefusedAt['page-a'],
        client.queue.session.orderOf(pointAt(22)),
      );
      expect(
        notApplicable(client.step(refusalAt(client, 'page-a', pointAt(15)))),
        isA<OlderResult>(),
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

    test('a read refusal replaces a debt only with what its own order '
        'proves: a row_replaced debt stays, so a read requested before it '
        'cannot pay it by a later snapshot', () {
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
        refusalAt(client, 'page-a', pointAt(12), requestedAt: owed.step),
      );
      expect(
        (client.queue.shown.pageRead('page-a') as ReadRefused).since,
        owed,
      );
      expect(
        notApplicable(
          client.step(
            arrivalAt(client, pageA(), pointAt(13), requestedAt: owed.step - 1),
          ),
        ),
        isA<OlderResult>(),
      );
      expect(client.queue.shown.pageRead('page-a'), isA<ReadRefused>());
      client.must(
        arrivalAt(client, pageA(), pointAt(14), requestedAt: owed.step),
      );
      expect(client.queue.shown.pageRead('page-a'), const ReadThisSession());
    });

    test('a later read refusal replaces an order owed with its own order', () {
      final client = connectedOn();
      client.must(refusalAt(client, 'page-a', pointAt(11)));
      client.must(refusalAt(client, 'page-a', pointAt(12)));
      expect(
        (client.queue.shown.pageRead('page-a') as ReadRefused).since,
        ResultAtOrAfter(client.queue.session.orderOf(pointAt(12))),
      );
    });
  });

  test('a read requested in one session does not pay a refusal recorded in '
      'the next', () {
    final client = connectedOn();
    client.must(arrivalAt(client, pageA(), pointAt(3)));
    final asked = client.queue.session.number;
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
        point: pointAt(12, later: 1),
      ),
    );
    expect(client.queue.session.number, greaterThan(asked));
    expect(client.queue.shown.pageRead('page-a'), isA<ReadOwed>());
    final late = BaseArrived(
      pageA(),
      session: asked,
      point: pointAt(10, later: 1),
      requestedAt: 99,
    );
    expect(notApplicable(client.step(late)), isA<OlderResult>());
    expect(client.queue.shown.pageRead('page-a'), isA<ReadOwed>());
  });

  group('sessions', () {
    test('an op answer stamped on a later connection before the reconnect '
        'opens the session and lands', () {
      final client = connectedOn();
      client.must(arrivalAt(client, pageA(), pointAt(3)));
      final before = client.queue.session.number;
      client.edit(movePatch('move', x: 40));
      final attempt = client.claim(['move']);
      client.effects.clear();
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('move', revision: 2, life: fixtureLife),
          point: pointAt(4, later: 1),
        ),
      );
      final opened = client.queue.session.number;
      expect(opened, greaterThan(before));
      expect(client.effects, contains(SessionOpened(opened)));
      expect(
        client.effects,
        contains(const OpRemoved('move', Delivered(Delivery.applied))),
      );
    });

    test('a list of an older life is dropped but still opens the session its '
        'later connection starts', () {
      final client = connectedOn();
      client.must(
        arrivalAt(client, headerReadOf(replaced(initialRows())), pointAt(5)),
      );
      final life = client.queue.shown.strategy?.life;
      final before = client.queue.session.number;
      expect(
        notApplicable(
          client.step(
            arrivalAt(
              client,
              headerReadOf(initialRows()),
              pointAt(6, later: 1),
            ),
          ),
        ),
        isA<OlderResult>(),
      );
      expect(client.queue.shown.strategy?.life, life);
      expect(client.queue.session.number, greaterThan(before));
    });

    test('a result labelled with an ended lifecycle opens nothing, even '
        'stamped ahead of the bound connection', () {
      final client = connectedOn();
      final old = client.queue.session.number;
      client.must(const AppRestarted(build: build));
      client.must(ConnectionReturned(pointAt(1, later: 1).generation));
      final session = client.queue.session;
      client.effects.clear();
      expect(
        notApplicable(
          client.step(
            BaseArrived(pageA(), session: old, point: pointAt(2, later: 2)),
          ),
        ),
        isA<FromAnEndedSession>(),
      );
      expect(client.queue.session, session);
      expect(client.effects.whereType<SessionOpened>(), isEmpty);
    });

    test('a session opening clears the taken orders and the fence', () {
      final client = connectedOn();
      client.must(
        arrivalAt(client, headerReadOf(replaced(initialRows())), pointAt(5)),
      );
      client.must(
        arrivalAt(
          client,
          pageReadOf(replaced(initialRows()), 'page-a'),
          pointAt(6),
        ),
      );
      expect(client.queue.shown.fence, isNotNull);
      expect(client.queue.shown.listTaken, isNotNull);
      expect(client.queue.shown.pagesTaken, isNotEmpty);
      client.must(ConnectionReturned(pointAt(7, later: 1).generation));
      expect(client.queue.shown.fence, isNull);
      expect(client.queue.shown.listTaken, isNull);
      expect(client.queue.shown.pagesTaken, isEmpty);
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
}
