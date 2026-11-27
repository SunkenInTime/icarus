import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart'
    show ShownRead, shownFromGroups, shownToGroups;
import 'package:test/test.dart';

import 'cloud_lives_test.dart' show asTheServerHoldsIt, newerLife;
import 'cloud_ordering_rules_test.dart'
    show
        answerTime,
        arrivalAt,
        arrivalOf,
        connectedOn,
        e1Of,
        orderAt,
        pageA,
        pageAWithout,
        pointAt,
        stateIn;
import 'cloud_support.dart';
import 'support.dart';

const reorder = PageReorderOp(
  opId: 'reorder',
  pagePublicId: 'page-b',
  sortIndex: 0,
  expectedStrategyRevision: 1,
);

void answer(
  Client client,
  StrategyOp op,
  ResultPoint at, {
  required int revision,
  int life = fixtureLife,
}) {
  client.edit(op);
  final attempt = client.claim([op.opId]);
  client.must(
    OpAnswered(
      attempt,
      AppliedAnswer(op.opId, revision: revision, life: life),
      point: at,
    ),
  );
}

void answerReorder(Client client, ResultPoint at) => answer(
  client,
  reorder,
  at,
  revision: 2,
  life: createdAtOf(initialRows().strategy)!,
);

void answerMove(Client client, ResultPoint at) =>
    answer(client, movePatch('move', x: 40), at, revision: 2);

ElementPatchOp teammateMovesE1ToB() => ElementPatchOp(
  opId: 'teammate',
  elementPublicId: 'e1',
  expectedElementRevision: 1,
  pagePublicId: 'page-b',
  payload: e1.payload,
  sortIndex: 0,
);

LiveElement get e1 => initialRows().element('e1')! as LiveElement;

ResultPoint onTheNewConnection(int snapshot, {required int time}) =>
    ResultPoint(
      client: testClient,
      connection: currentGeneration.connection,
      snapshot: snapshot,
      serverTime: time,
    );

void main() {
  group('a row\'s mark goes with the row (finding 5)', () {
    final movedToB = withOp(initialRows(), teammateMovesE1ToB());
    final edited = withOp(
      movedToB,
      movePatch(
        'edit',
        x: 70,
        expected: 2,
        merge: FieldMerge(fields: const ['position']),
      ),
    );
    final edit = movePatch(
      'edit',
      x: 70,
      merge: FieldMerge(fields: const ['position']),
    );

    Client seenOnA() {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
      client.must(arrivalAt(client, pageA(), pointAt(3)));
      client.must(
        arrivalAt(client, pageReadOf(initialRows(), 'page-b'), pointAt(3)),
      );
      return client;
    }

    for (final answerFirst in [true, false]) {
      test('our field edit written on A lands on X on B at 20; a read of B '
          'at 15 leaves B not current, and one at 21 makes it current '
          '(${answerFirst ? 'the answer' : 'the read'} first)', () {
        final client = seenOnA();
        void readB() => client.must(
          arrivalAt(client, pageReadOf(movedToB, 'page-b'), pointAt(15)),
        );
        if (!answerFirst) readB();
        answer(client, edit, pointAt(20), revision: 3);
        if (answerFirst) readB();
        expect(
          client.queue.shown.rows[const ElementTarget('e1')]?.page,
          'page-b',
        );
        expect(client.queue.shown.pageCurrent('page-b'), isFalse);
        client.must(
          arrivalAt(client, pageReadOf(edited, 'page-b'), pointAt(21)),
        );
        expect(client.queue.shown.pageCurrent('page-b'), isTrue);
      });
    }
  });

  test('a result restores freshness only if it pays the mark of the write '
      'that took it away: a page read from before our answer is taken but '
      'leaves the page not fresh; one from after it makes the page fresh', () {
    final client = connectedOn();
    client.must(arrivalAt(client, pageA(), pointAt(5)));
    answerMove(client, pointAt(10));
    final moved = withOp(initialRows(), movePatch('move', x: 40));
    final before = client.step(arrivalAt(client, pageA(), pointAt(8)));
    expect(before, isA<Stepped>());
    expect(client.queue.shown.pagesTaken['page-a'], isNotNull);
    expect(client.queue.shown.pageCurrent('page-a'), isFalse);
    client.must(arrivalAt(client, pageA(moved), pointAt(12)));
    expect(client.queue.shown.pageCurrent('page-a'), isTrue);
  });

  group('freshness does not depend on which arrived first', () {
    test('a list at the answer\'s point keeps the list current for the '
        'answer\'s page, in either order', () {
      final listFirst = connectedOn();
      listFirst.must(
        arrivalAt(listFirst, headerReadOf(initialRows()), pointAt(12)),
      );
      answerMove(listFirst, pointAt(12));
      expect(listFirst.queue.shown.listCurrentFor('page-a'), isTrue);

      final answerFirst = connectedOn();
      answerMove(answerFirst, pointAt(12));
      answerFirst.must(
        arrivalAt(answerFirst, headerReadOf(initialRows()), pointAt(12)),
      );
      expect(answerFirst.queue.shown.listCurrentFor('page-a'), isTrue);
    });

    test('a page result at the point of a list-changing answer keeps the page '
        'current, in either order', () {
      final pageFirst = connectedOn();
      pageFirst.must(arrivalAt(pageFirst, pageA(), pointAt(12)));
      answerReorder(pageFirst, pointAt(12));
      expect(pageFirst.queue.shown.pageCurrent('page-a'), isTrue);

      final answerFirst = connectedOn();
      answerReorder(answerFirst, pointAt(12));
      answerFirst.must(arrivalAt(answerFirst, pageA(), pointAt(12)));
      expect(answerFirst.queue.shown.pageCurrent('page-a'), isTrue);
    });

    test('a newer list after an older one, our move between them, keeps the '
        'list current for the page', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(7)));
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(9)));
      answerMove(client, pointAt(8));
      client.must(arrivalAt(client, pageA(), pointAt(8)));
      expect(client.queue.shown.listCurrentFor('page-a'), isTrue);
    });

    test('a page result at the reorder\'s point, delivered before it, keeps '
        'the page current', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(7)));
      client.must(
        arrivalAt(client, pageReadOf(initialRows(), 'page-b'), pointAt(8)),
      );
      client.must(arrivalAt(client, pageA(), pointAt(9)));
      answerReorder(client, pointAt(9));
      expect(client.queue.shown.pageCurrent('page-a'), isTrue);
    });
  });

  test('a rename behind our own reorder is not judged current on a list '
      'older than the reorder\'s answer, and is decided on one after it', () {
    final client = connectedOn();
    client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
    client.must(arrivalAt(client, pageA(), pointAt(3)));
    client.edit(reorder);
    client.edit(
      const PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-a',
        expectedPageRevision: 1,
        name: 'Mine',
      ),
    );
    final attempt = client.claim(['reorder']);
    client.must(
      OpAnswered(
        attempt,
        AppliedAnswer(
          'reorder',
          revision: 2,
          life: createdAtOf(initialRows().strategy)!,
        ),
        point: pointAt(12),
      ),
    );
    client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(10)));
    expect(stateIn(client, 'rename'), isNot(isA<NeedsUser>()));
    expect(client.view('rename').holds, contains(isA<AwaitingResult>()));
    client.must(
      arrivalAt(
        client,
        headerReadOf(withOp(initialRows(), reorder)),
        pointAt(13),
      ),
    );
    expect(client.view('rename').holds, isNot(contains(isA<AwaitingResult>())));
  });

  test('an answer the taken result already shows leaves the page fresh', () {
    final client = connectedOn();
    client.must(arrivalAt(client, pageA(), pointAt(12)));
    expect(client.queue.shown.pageCurrent('page-a'), isTrue);
    answerMove(client, pointAt(12));
    expect(client.queue.shown.pageCurrent('page-a'), isTrue);
    expect(client.queue.shown.marks.rows, isEmpty);
  });

  group('our own answers', () {
    test('a read at an earlier server time does not make a page fresh after '
        'a reconnect, and a read at or after the answer\'s time does', () {
      final touched = Shown.nothing.marked(
        AnswerMark(order: orderAt(10, session: 3), serverTime: 200),
        pages: ['page-a'],
        list: false,
        allPages: false,
      );
      final reconnected = touched.inNewSession();
      expect(reconnected.marks, touched.marks);
      for (final (time, fresh) in [(190, false), (200, true), (210, true)]) {
        expect(
          reconnected
              .taken(
                pageA(),
                arrival: arrivalOf(orderAt(1, session: 4), time: time),
              )
              .shown
              .pageCurrent('page-a'),
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

    test('an answer marks the pages it touches, the list when it changes the '
        'list, every page when it renumbers them, and the row it wrote', () {
      final client = connectedOn();
      answerMove(client, pointAt(10));
      final move = client.queue.shown.marks;
      expect(move.pages.keys, ['page-a']);
      expect(move.list, isNull);
      expect(move.allPages, isNull);
      expect(move.rows.keys, [const ElementTarget('e1')]);
      expect(move.rows[const ElementTarget('e1')]!.wrote, {
        const ElementTarget('e1'): const Version(2, life: fixtureLife),
      });
      final other = connectedOn();
      answerReorder(other, pointAt(10));
      final renumbered = other.queue.shown.marks;
      expect(renumbered.list, isNotNull);
      expect(renumbered.allPages, isNotNull);
      expect(renumbered.pages.keys, ['page-b']);
      expect(renumbered.rows, isEmpty);
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

  group('a page the queue holds as gone', () {
    test('a page-gone from before our answer on the page does not make an '
        'edit behind our own work on it ask the user; one from after does', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
      client.must(arrivalAt(client, pageA(), pointAt(3)));
      client.edit(movePatch('first', x: 10));
      final attempt = client.claim(['first']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('first', revision: 2, life: fixtureLife),
          point: pointAt(10),
        ),
      );
      client.edit(movePatch('second', x: 20, expected: 2));
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(8)));
      expect(client.queue.shown.goneThisSession, contains('page-a'));
      expect(client.queue.shown.pageCurrent('page-a'), isFalse);
      expect(stateIn(client, 'second'), isNot(isA<NeedsUser>()));
      client.must(arrivalAt(client, const PageGone('page-a'), pointAt(12)));
      expect(stateIn(client, 'second'), const NeedsUser(RowPageGone()));
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
      expect(since, isA<AllOf>());
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

    test(
      'two answers owed combine into the later order and the later time',
      () {
        final combined = both(
          AfterAnswer(orderAt(9), serverTime: 100),
          AfterAnswer(orderAt(5), serverTime: 300),
        );
        expect(combined, AfterAnswer(orderAt(9), serverTime: 300));
      },
    );

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

    test('a read refusal over combined debts replaces only the order owed, '
        'with its own order, and keeps the refusal', () {
      final client = connectedOn();
      final owed = ResultAtOrAfter(client.queue.session.orderOf(pointAt(3)));
      final combined = both(owed, rowA);
      final refused = Arrival(
        order: client.queue.session.orderOf(pointAt(12)),
        point: pointAt(12),
      );
      expect(
        refusedOver(combined, refused),
        both(ResultAtOrAfter(refused.order), rowA),
      );
      expect(refusedOver(rowA, refused), rowA);
      final later = ResultAtOrAfter(client.queue.session.orderOf(pointAt(20)));
      expect(refusedOver(both(later, rowA), refused), both(later, rowA));
    });
  });

  group('the stored form of combined debts', () {
    final shown = Shown.nothing
        .owingList(ResultAtOrAfter(orderAt(9)))
        .owingList(
          AfterRefusal(
            session: 3,
            point: const ResultPoint(
              client: testClient,
              connection: 1,
              snapshot: 5,
              serverTime: 7,
            ),
            step: 4,
            evidence: const StrategyLifeAtLeast(fixtureLife),
          ),
        );
    const fixture =
        '{"allOf":[{"session":3,"client":1,"snapshot":9},'
        '{"afterRefusal":{"session":3,"client":1,"connection":1,'
        '"snapshot":5,"time":"7","step":4,'
        '"evidence":{"strategyLife":$fixtureLife}}}]}';

    test('is written as allOf', () {
      final read = shownToGroups(shown)[null]!['read']! as Map;
      expect(jsonEncode(read['owedSince']), fixture);
    });

    test('reads back, and an earlier single debt still reads', () {
      final group = shownToGroups(shown)[null]!;
      final stored = jsonEncode(group);
      expect(stored, contains(fixture));
      final read = shownFromGroups({null: stored});
      expect((read as ShownRead).shown.list, shown.list);
      final earlier = stored.replaceFirst(
        fixture,
        '{"session":3,"client":1,"snapshot":9}',
      );
      final single = shownFromGroups({null: earlier});
      expect(
        ((single as ShownRead).shown.list as ReadOwed).since,
        ResultAtOrAfter(orderAt(9)),
      );
    });
  });

  test('an answer is reached by order and time: each leg counts, equal '
      'passes, a read with no time never reaches a timed answer, and an '
      'answer with no time asks only for order', () {
    final timed = AnswerMark(order: orderAt(10), serverTime: 200);
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
    final untimed = AnswerMark(order: orderAt(10));
    expect(untimed.reachedBy(arrivalOf(orderAt(10))), isTrue);
    expect(untimed.reachedBy(arrivalOf(orderAt(9), time: 999)), isFalse);
  });

  test('two marks on one subject keep the later order and the later time, '
      'and the newest version written of each row', () {
    const e1At2 = (
      target: ElementTarget('e1'),
      version: Version(2, life: fixtureLife),
    );
    const e1At3 = (
      target: ElementTarget('e1'),
      version: Version(3, life: fixtureLife),
    );
    const e2At5 = (
      target: ElementTarget('e2'),
      version: Version(5, life: fixtureLife),
    );
    final first = AnswerMark(order: orderAt(9), serverTime: 100, wrote: e1At3);
    final second = AnswerMark(order: orderAt(5), serverTime: 300, wrote: e1At2);
    expect(
      first.and(second),
      AnswerMark(order: orderAt(9), serverTime: 300, wrote: e1At3),
    );
    final both = first.and(AnswerMark(order: orderAt(5), wrote: e2At5));
    expect(both.order, orderAt(9));
    expect(both.serverTime, 100);
    expect(both.wrote, {
      e1At3.target: e1At3.version,
      e2At5.target: e2At5.version,
    });
    expect(first.and(AnswerMark(order: orderAt(5))).wrote, isNull);
  });

  test('a restart drops the marks and what was seen, leaving the record a '
      'reload reads back', () {
    final client = connectedOn();
    client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
    client.must(arrivalAt(client, pageA(), pointAt(3)));
    answerMove(client, pointAt(10));
    answerReorder(client, pointAt(11));
    expect(client.queue.shown.marks.isEmpty, isFalse);
    client.must(const AppRestarted(build: build));
    final shown = client.queue.shown;
    final reloaded = switch (shownFromGroups({
      for (final MapEntry(:key, :value) in shownToGroups(shown).entries)
        key: jsonEncode(value),
    })) {
      ShownRead(:final shown) => shown,
      final other => fail('expected results, got $other'),
    };
    expect(shown.marks.isEmpty, isTrue);
    expect(shown.listSeen, isNull);
    expect(shown.pagesSeen, isEmpty);
    expect(shown, reloaded);
  });

  group('a timed answer whose clock never catches up', () {
    test('two answers that wrote different items on one page release the '
        'page by content once a read shows both, with a clock behind or no '
        'clock at all', () {
      for (final time in [answerTime, null]) {
        final client = connectedOn();
        client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
        client.must(arrivalAt(client, pageA(), pointAt(3)));
        answerMove(client, pointAt(10));
        answer(
          client,
          movePatch('move2', elementId: 'e2', x: 50),
          pointAt(11),
          revision: 2,
        );
        client.must(reconnected());
        ResultPoint behind(int snapshot) => ResultPoint(
          client: testClient,
          connection: currentGeneration.connection,
          snapshot: snapshot,
          serverTime: time,
        );
        final first = withOp(initialRows(), movePatch('move', x: 40));
        client.must(arrivalAt(client, pageA(first), behind(1)));
        expect(
          client.queue.shown.pageCurrent('page-a'),
          isFalse,
          reason: '$time',
        );
        final both = withOp(first, movePatch('move2', elementId: 'e2', x: 50));
        client.must(arrivalAt(client, pageA(both), behind(2)));
        expect(
          client.queue.shown.pageCurrent('page-a'),
          isTrue,
          reason: '$time',
        );
        expect(client.queue.shown.marks.pages, isEmpty, reason: '$time');
      }
    });

    test('after a reconnect, results with server times below the answer\'s '
        'do not reach its mark; one showing the written row releases it', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
      client.must(arrivalAt(client, pageA(), pointAt(3)));
      answerMove(client, pointAt(10));
      client.must(reconnected());
      final behind = answerTime;
      client.must(
        arrivalAt(
          client,
          headerReadOf(initialRows()),
          onTheNewConnection(1, time: behind),
        ),
      );
      expect(client.queue.shown.listCurrent, isTrue);
      client.must(
        arrivalAt(client, pageA(), onTheNewConnection(2, time: behind)),
      );
      expect(client.queue.shown.pageCurrent('page-a'), isFalse);
      expect(client.queue.shown.waitsOnClock('page-a'), isTrue);
      final moved = withOp(initialRows(), movePatch('move', x: 40));
      client.must(
        arrivalAt(client, pageA(moved), onTheNewConnection(3, time: behind)),
      );
      expect(client.queue.shown.pageCurrent('page-a'), isTrue);
      expect(client.queue.shown.waitsOnClock('page-a'), isFalse);
      expect(client.queue.shown.marks.rows, isEmpty);
      expect(client.queue.shown.listCurrentFor('page-a'), isFalse);
      expect(client.queue.shown.waitsOnClock(null), isTrue);
      client.must(
        arrivalAt(
          client,
          headerReadOf(initialRows()),
          onTheNewConnection(4, time: answerTime + 10),
        ),
      );
      expect(client.queue.shown.listCurrentFor('page-a'), isTrue);
      expect(client.queue.shown.marks.isEmpty, isTrue);
    });

    test('a renumbering leaves no row for a page to show: the page waits, '
        'the queue asks for it and says the clock is why, and a read at the '
        'answer\'s time releases it', () {
      final client = connectedOn();
      client.must(arrivalAt(client, headerReadOf(initialRows()), pointAt(2)));
      client.must(arrivalAt(client, pageA(), pointAt(3)));
      client.must(
        arrivalAt(client, pageReadOf(initialRows(), 'page-b'), pointAt(3)),
      );
      answerReorder(client, pointAt(10));
      client.must(reconnected());
      client.edit(pageDelete('drop', 'page-a', expected: 2));
      final behind = answerTime;
      final reordered = withOp(initialRows(), reorder);
      client.must(
        arrivalAt(
          client,
          headerReadOf(reordered),
          onTheNewConnection(1, time: behind),
        ),
      );
      expect(client.queue.shown.listCurrent, isTrue);
      expect(client.queue.shown.listCurrentFor('page-a'), isTrue);
      for (var snapshot = 2; snapshot < 5; snapshot++) {
        client.must(
          arrivalAt(
            client,
            pageA(reordered),
            onTheNewConnection(snapshot, time: behind + snapshot),
          ),
        );
        expect(client.queue.shown.pageCurrent('page-a'), isFalse);
        expect(client.queue.shown.waitsOnClock('page-a'), isTrue);
        expect(client.view('drop').sendable, isFalse);
        expect(
          resultsNeeded(client.queue, client.at),
          contains(const PageResult('page-a')),
        );
      }
      client.must(
        arrivalAt(
          client,
          pageA(reordered),
          onTheNewConnection(5, time: answerTime + 10),
        ),
      );
      expect(client.queue.shown.pageCurrent('page-a'), isTrue);
      expect(client.queue.shown.waitsOnClock('page-a'), isFalse);
      expect(client.view('drop').sendable, isTrue);
    });
  });

  test('a decision on a 300-item page looks only at the marks of rows shown '
      'on that page', () {
    final rows = strategyRows(
      elements: [
        for (var i = 0; i < 300; i++) element('a$i', sortIndex: i),
        for (var i = 0; i < 300; i++)
          element('b$i', pageId: 'page-b', sortIndex: i),
      ],
    );
    var shown = Shown.nothing;
    for (final page in ['page-a', 'page-b']) {
      shown = shown
          .taken(
            pageReadOf(rows, page),
            arrival: arrivalOf(orderAt(5), time: 50),
          )
          .shown;
    }
    AnswerMark wrote(String id) => AnswerMark(
      order: orderAt(10),
      serverTime: 100,
      wrote: (
        target: ElementTarget(id),
        version: const Version(2, life: fixtureLife),
      ),
    );
    for (final id in ['a7', for (var i = 0; i < 300; i++) 'b$i']) {
      shown = shown.marked(
        wrote(id),
        pages: const [],
        list: false,
        allPages: false,
        row: ElementTarget(id),
      );
    }
    expect(shown.marks.rows, hasLength(301));
    expect(shown.marks.rowsOn['page-a'], {const ElementTarget('a7')});
    shownWork.reset();
    expect(shown.pageCurrent('page-a'), isFalse);
    expect(shownWork.marksLooked, 1);
    final edited = withOp(rows, movePatch('a7', elementId: 'a7', x: 40));
    final caughtUp = shown
        .taken(
          pageReadOf(edited, 'page-a'),
          arrival: arrivalOf(orderAt(6), time: 60),
        )
        .shown;
    expect(caughtUp.marks.rows, hasLength(300));
    shownWork.reset();
    expect(caughtUp.pageCurrent('page-a'), isTrue);
    expect(shownWork.marksLooked, 0);
  });
}
