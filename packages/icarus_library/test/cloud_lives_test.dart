import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';
import 'support.dart';

Client online(StrategyRowSet rows) => Client(base: rows)
  ..must(const ConnectionReturned())
  ..read(rows);

void deliver(Client client, Server server, int attempt) {
  final batch = client.effects.whereType<SendBatch>().lastWhere(
    (sent) => sent.attempt == attempt,
  );
  for (final event in server.answer(clientId, batch)) {
    client.must(event);
  }
}

Map<Attention, int> attentionOf(Client client) =>
    Tally.of(client.queue, client.at).attention;

const replacedStrategy = NeedsUser(MadeInAReplacedStrategy());

Inapplicable setAside(Client client, ArrivedBase base, ResultStart started) =>
    notApplicable(
      client.step(
        BaseArrived(
          base,
          session: client.queue.session.number,
          started: started,
        ),
      ),
    );

void main() {
  group('a strategy deleted and made again under the same id', () {
    test('every edit queued on the earlier strategy asks once the device '
        'reads the new page list, one question per edit, none is sent and '
        'none is drawn', () {
      final server = Server();
      final client = online(server.rows)
        ..edit(movePatch('move', x: 40))
        ..edit(elementDelete('remove', elementId: 'e2'))
        ..edit(
          const StrategyPatchOp(
            opId: 'rename',
            expectedStrategyRevision: 1,
            name: 'Renamed',
          ),
        )
        ..edit(
          const PagePatchOp(
            opId: 'page',
            pagePublicId: 'page-a',
            expectedPageRevision: 1,
            name: 'B site',
          ),
        );
      server.reupload();
      client.read(server.rows);
      final views = entryViews(client.queue, client.at);
      expect(views.keys, ['move', 'remove', 'rename', 'page']);
      for (final view in views.values) {
        expect(view.state, replacedStrategy);
        expect(view.sendable, isFalse);
      }
      expect(attentionOf(client), {Attention.strategyReplaced: 4});
      expect(client.visible.strategy.name, server.rows.strategy.name);
      expect(
        client.visible.page('page-a')!.toJson(),
        server.rows.page('page-a')!.toJson(),
      );
      expect(client.visible.element('e1'), isNull);
    });

    test('a batch sent before the device reads the new list is refused '
        'whole; the page list is owed until a list read started after the '
        'refusal arrives, and then each edit asks', () {
      final server = Server();
      final client = online(server.rows)..edit(movePatch('move', x: 40));
      final early = client.startRead();
      server.reupload();
      final before = [for (final row in server.rows.rows) row.toJson()];
      final attempt = client.claim(['move']);
      expect(
        client.effects.whereType<SendBatch>().last.strategyLife,
        fixtureLife,
      );
      deliver(client, server, attempt);
      expect([for (final row in server.rows.rows) row.toJson()], before);
      expect(owedReads(client.queue), {const PageListResult()});
      expect(
        setAside(client, headerReadOf(server.rows), StartedAt(early)),
        isA<StartedBeforeANewerResult>(),
      );
      expect(owedReads(client.queue), {const PageListResult()});
      expect(client.queue.shown.strategyVersion!.lifeOnTheWire, fixtureLife);
      client.read(server.rows);
      expect(owedReads(client.queue), isEmpty);
      expect(client.view('move').state, replacedStrategy);
    });

    test('a rename to the name the new strategy already holds still asks', () {
      final server = Server();
      final client = online(server.rows)
        ..edit(
          StrategyPatchOp(
            opId: 'rename',
            expectedStrategyRevision: 1,
            name: server.rows.strategy.name,
          ),
        );
      server.reupload();
      client.read(server.rows);
      expect(client.view('rename').state, replacedStrategy);
    });

    test('an answer to an edit of the earlier strategy that arrives after the '
        'new list makes no landed record and leaves the edit asking', () {
      final server = Server();
      final client = online(server.rows)..edit(movePatch('move', x: 40));
      final attempt = client.claim(['move']);
      final batch = client.effects.whereType<SendBatch>().last;
      final answers = server.answer(clientId, batch);
      server.reupload();
      client.read(server.rows);
      answers.forEach(client.must);
      expect(client.queue.landed, isEmpty);
      expect(client.view('move').state, replacedStrategy);
      expect(attempt, 1);
    });

    test(
      'a list of the earlier strategy read after the new one is ignored',
      () {
        final server = Server();
        final client = online(server.rows);
        final old = server.rows;
        final early = client.startRead();
        server.reupload();
        client.read(server.rows);
        final shown = client.queue.shown;
        expect(
          setAside(client, headerReadOf(old), const StartedAsItArrived()),
          isA<FromAnEarlierLife>(),
        );
        expect(
          setAside(client, headerReadOf(old), StartedAt(early)),
          isA<StartedBeforeANewerResult>(),
        );
        expect(client.queue.shown, shown);
      },
    );

    test('a page read of an earlier page life than the list shows is '
        'ignored', () {
      final server = Server();
      final client = online(server.rows);
      final old = server.rows;
      server.reupload();
      client.arriveStarted(
        headerReadOf(server.rows),
        const StartedAsItArrived(),
      );
      final shown = client.queue.shown;
      expect(
        setAside(client, pageReadOf(old, 'page-a'), const StartedAsItArrived()),
        isA<FromAnEarlierLife>(),
      );
      expect(client.queue.shown, shown);
      expect(client.queue.shown.content.containsKey('page-a'), isFalse);
    });

    test('a page list showing the strategy ends "deleted on the server"', () {
      final server = Server();
      final client = online(server.rows)..arrive(const StrategyGone());
      expect(standingOf(client.queue), Standing.deletedOnServer);
      server.reupload();
      client.read(server.rows);
      expect(standingOf(client.queue), Standing.good);
    });
  });

  group('an element or lineup deleted, purged after 30 days and put back by '
      'a teammate', () {
    final kinds =
        <String, (StrategyRowSet, StrategyOp, StrategyOp, StrategyOp)>{
          'an element': (
            initialRows(),
            movePatch('edit', x: 40),
            elementDelete('gone', expected: 1),
            ElementAddOp(
              opId: 'back',
              elementPublicId: 'e1',
              pagePublicId: 'page-a',
              payload: agentPayload('e1', const {'rotation': 135}),
              sortIndex: 0,
            ),
          ),
          'a lineup': (
            withLineup(initialRows()),
            LineupGroupPatchOp(
              opId: 'edit',
              lineupPublicId: 'g1',
              expectedLineupRevision: 1,
              payload: lineupNotes('jump throw'),
              sortIndex: 0,
            ),
            const LineupGroupDeleteOp(
              opId: 'gone',
              lineupPublicId: 'g1',
              pagePublicId: 'page-a',
              expectedLineupRevision: 1,
            ),
            LineupGroupAddOp(
              opId: 'back',
              lineupPublicId: 'g1',
              pagePublicId: 'page-a',
              payload: lineupNotes('put back'),
              sortIndex: 0,
            ),
          ),
        };
    for (final MapEntry(key: kind, value: (rows, edit, gone, back))
        in kinds.entries) {
      test('$kind: an edit made on the earlier row names its life, is refused '
          'as replaced with the row as it is, owes the row\'s page, asks, and '
          'is not drawn over the row put back', () {
        final server = Server()..rows = rows;
        final client = online(server.rows)..edit(edit);
        server.apply('teammate', gone);
        server.purgeAfterThirtyDays();
        server.apply('teammate', back);
        final putBack = [for (final row in server.rows.rows) row.toJson()];
        final attempt = client.claim(['edit']);
        expect(client.effects.whereType<SendBatch>().last.lives, {
          'edit': fixtureLife,
        });
        deliver(client, server, attempt);
        expect([for (final row in server.rows.rows) row.toJson()], putBack);
        expect(
          client.view('edit').state,
          isA<NeedsUser>().having(
            (state) => state.reason,
            'reason',
            isA<RefusedByServer>().having(
              (reason) => reason.refusal,
              'refusal',
              isA<RejectedByServer>()
                  .having(
                    (r) => r.reason,
                    'reason',
                    RejectionReason.rowReplaced,
                  )
                  .having((r) => r.current, 'current', isA<ServerSnapshot>()),
            ),
          ),
        );
        expect(owedReads(client.queue), {const PageResult('page-a')});
        client.read(server.rows, pages: ['page-a']);
        expect(owedReads(client.queue), isEmpty);
        expect(
          [for (final row in client.visible.rows) row.toJson()],
          [for (final row in server.rows.rows) row.toJson()],
        );
      });
    }
  });

  group('an answer without a life', () {
    test('asks, and is counted as an answer the server forgot', () {
      final server = Server();
      final client = online(server.rows)..edit(movePatch('drag', x: 40));
      final attempt = client.claim(['drag']);
      server.apply(clientId, client.lastSent().single);
      client.must(
        OpAnswered(
          attempt,
          const ReplayWithoutLife(
            'drag',
            revision: 2,
            replay: NoopReplay.appliedWhenFirstReceived,
          ),
        ),
      );
      expect(
        client.view('drag').state,
        const NeedsUser(RefusedByServer(AnsweredWithoutLife(2))),
      );
      expect(client.queue.landed, isEmpty);
      expect(attentionOf(client), {Attention.serverForgotAnswer: 1});
    });
  });

  group('results are ordered by when they started', () {
    test('a page read started before this device\'s add was answered does not '
        'show the add as gone; one started after the answer does', () {
      final server = Server();
      final client = online(server.rows)..edit(elementAdd('add'));
      final attempt = client.claim(['add']);
      final before = server.rows;
      final early = client.startRead();
      deliver(client, server, attempt);
      expect(client.queue.landed.single.op.opId, 'add');
      client.arriveStarted(pageReadOf(before, 'page-a'), StartedAt(early));
      expect(client.queue.landed.single.shownWithout, isFalse);
      expect(client.visible.element('e9'), isNotNull);
      final late = client.startRead();
      client.arriveStarted(pageReadOf(before, 'page-a'), StartedAt(late));
      expect(client.queue.landed.single.shownWithout, isTrue);
    });

    test('a result that started before one already taken for the same page '
        'is ignored', () {
      final server = Server();
      final client = online(server.rows);
      final first = client.startRead();
      final old = server.rows;
      server.apply('teammate', movePatch('t', x: 70));
      final second = client.startRead();
      client.arriveStarted(
        pageReadOf(server.rows, 'page-a'),
        StartedAt(second),
      );
      final shown = client.queue.shown;
      expect(
        setAside(client, pageReadOf(old, 'page-a'), StartedAt(first)),
        isA<StartedBeforeANewerResult>(),
      );
      expect(client.queue.shown, shown);
    });

    test('a live result adds rows and never shows one as gone', () {
      final server = Server();
      final client = online(server.rows);
      server.apply('teammate', elementDelete('t', elementId: 'e2'));
      server.apply('teammate', elementAdd('t2', elementId: 'e7'));
      client.arriveStarted(
        pageReadOf(server.rows, 'page-a'),
        const LiveResult(),
      );
      expect(client.queue.shown.rows.keys, contains(const ElementTarget('e2')));
      expect(client.queue.shown.rows.keys, contains(const ElementTarget('e7')));
      client.arriveStarted(const StrategyGone(), const LiveResult());
      expect(standingOf(client.queue), Standing.good);
    });
  });

  test('an edit of a page this device added, made before any list showed the '
      'page, names no page life; the batch carries the strategy\'s', () {
    final server = Server();
    final client = online(server.rows)..edit(pageAdd('add', 'page-c'));
    deliver(client, server, client.claim(['add']));
    client.edit(
      const PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-c',
        expectedPageRevision: 1,
        name: 'B site',
      ),
    );
    client.read(server.rows, pages: const []);
    client.claim(['rename']);
    final sent = client.effects.whereType<SendBatch>().last;
    expect(sent.lives, isEmpty);
    expect(sent.strategyLife, fixtureLife);
  });
}

LineupGroupPayload lineupNotes(String notes) => LineupGroupPayload(
  payloadVersion: 1,
  data: {
    'id': 'g1',
    'origins': [
      {
        'id': 'o1',
        'agent': {'type': 'sova'},
      },
    ],
    'landings': [
      {
        'id': 'l1',
        'ability': {'type': 'recon'},
      },
    ],
    'links': [
      {'id': 'k1', 'originId': 'o1', 'landingId': 'l1', 'notes': notes},
    ],
  },
);

StrategyRowSet withLineup(StrategyRowSet rows) => rows.withRows([
  LiveLineupGroup(
    strategyPublicId: strategyId,
    publicId: 'g1',
    pagePublicId: 'page-a',
    payload: lineupNotes(''),
    sortIndex: 0,
    revision: 1,
    unknownFields: jsonObject({'createdAt': fixtureLife}),
  ),
]);
