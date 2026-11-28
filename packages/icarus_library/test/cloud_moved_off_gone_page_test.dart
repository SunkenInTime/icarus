import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_live_basis_test.dart' show claimAt, heldAt, hold, quietClient;
import 'cloud_server.dart';
import 'cloud_support.dart';

const page = 'page-a';

const live = Duration(seconds: 105);

StrategyRowSet movedToB(StrategyRowSet rows) => withOp(
  rows,
  ElementPatchOp(
    opId: 'their-move',
    elementPublicId: 'e1',
    expectedElementRevision: (rows.element('e1')! as LiveElement).revision,
    pagePublicId: 'page-b',
    payload: (rows.element('e1')! as LiveElement).payload,
    sortIndex: 5,
  ),
);

StrategyRowSet aTrashed(StrategyRowSet rows) => withOp(
  rows,
  pageDelete('their-drop', page, expected: rows.strategy.revision),
);

void landOwnEdit(Client client, Server server) {
  client.edit(
    movePatch('first', x: 40, merge: FieldMerge(fields: ['position'])),
  );
  final first = claimAt(client, ['first'], heldAt);
  for (final op in client.lastSent()) {
    client.must(
      OpAnswered(first.attempt, server.apply(clientId, op), point: tick()),
    );
  }
}

({Client client, Server server, int seenAt}) deleteWaiting({
  required bool behindOwn,
}) {
  final server = Server();
  final client = quietClient()..read(server.rows);
  hold(client, 1000, heldAt);
  if (behindOwn) landOwnEdit(client, server);
  final seenAt = (client.visible.element('e1')! as LiveElement).revision;
  client.edit(elementDelete('drop', expected: seenAt));
  return (client: client, server: server, seenAt: seenAt);
}

OpAnswer sendDrop(Client client, Server server) {
  final sent = claimAt(client, ['drop'], live);
  final answer = server.apply(clientId, sent.ops.single);
  client.must(OpAnswered(sent.attempt, answer, point: tick()));
  return answer;
}

void main() {
  group('my delete of an item on page A, once the store knows page A left '
      'the live list, goes in its checked form, naming the revision I saw, '
      'and the server answers', () {
    for (final behindOwn in [false, true]) {
      final where = behindOwn ? 'behind my own work' : 'on its own';
      test('$where: a teammate moved the item to page B first, so the '
          'delete is refused as changed and the item stays on page B', () {
        final (:client, :server, :seenAt) = deleteWaiting(behindOwn: behindOwn);
        server.rows = aTrashed(movedToB(server.rows));
        client.arrive(headerReadOf(server.rows));
        expect(client.view('drop').sendable, isTrue);
        final sent = claimAt(client, ['drop'], live).ops.single;
        expect((sent as ElementDeleteOp).lastWriterWins, isFalse);
        expect(sent.expectedElementRevision, seenAt);
        final answer = server.apply(clientId, sent);
        expect(answer, isA<RejectedAnswer>());
        client.must(
          OpAnswered(client.queue.nextAttempt - 1, answer, point: tick()),
        );
        expect(
          client.view('drop').state,
          isA<NeedsUser>().having(
            (state) => state.reason,
            'reason',
            isA<RefusedByServer>().having(
              (reason) => reason.refusal,
              'refusal',
              isA<RejectedByServer>().having(
                (refusal) => refusal.reason,
                'reason',
                RejectionReason.revisionMismatch,
              ),
            ),
          ),
        );
        expect(server.rows.element('e1'), isA<LiveElement>());
        expect(server.rows.element('e1')!.pagePublicId, 'page-b');
      });

      test('$where: the item is still on page A in the trash, so the delete '
          'is refused as its page deleted', () {
        final (:client, :server, seenAt: _) = deleteWaiting(
          behindOwn: behindOwn,
        );
        server.rows = aTrashed(server.rows);
        client.arrive(headerReadOf(server.rows));
        sendDrop(client, server);
        expect(
          client.view('drop').state,
          const NeedsUser(RefusedAsPageDeleted()),
        );
      });

      test('$where: the item was purged with page A, so the delete has '
          'nothing to do and leaves the queue', () {
        final (:client, :server, seenAt: _) = deleteWaiting(
          behindOwn: behindOwn,
        );
        server.rows = withoutPage(aTrashed(server.rows), page);
        client.arrive(headerReadOf(server.rows));
        expect(sendDrop(client, server), isA<NoopWithoutRevision>());
        expect(client.queue.entry('drop'), isNull);
      });
    }

    test('a delete first sent live while page A was listed, its answer lost, '
        'goes again checked under the same op id once A has left, and the '
        'server\'s replay of its first landing settles it', () {
      final (:client, :server, seenAt: _) = deleteWaiting(behindOwn: false);
      final first = claimAt(client, ['drop'], live);
      final firstForm = first.ops.single as ElementDeleteOp;
      expect(firstForm.lastWriterWins, isTrue);
      expect(server.apply(clientId, firstForm), isA<AppliedAnswer>());
      client.must(
        TransportFailed(first.attempt, TransportFailure.network, at: client.at),
      );
      server.rows = aTrashed(server.rows);
      client.arrive(headerReadOf(server.rows));
      client.clock = client.at.add(const Duration(minutes: 10));
      final again = claimAt(client, ['drop'], live);
      final againForm = again.ops.single as ElementDeleteOp;
      expect(againForm.opId, firstForm.opId);
      expect(againForm.lastWriterWins, isFalse);
      final answer = server.apply(clientId, againForm);
      expect(
        answer,
        isA<NoopAnswer>().having(
          (noop) => noop.replay,
          'replay',
          NoopReplay.appliedWhenFirstReceived,
        ),
      );
      client.must(OpAnswered(again.attempt, answer, point: tick()));
      expect(client.queue.entry('drop'), isNull);
      expect(client.effects, contains(isA<OpRemoved>()));
    });

    test(
      'known behaviour, not covered: my field edit, then my delete, '
      'while a teammate moves the item to page B and sets that field to '
      'the same value in one write; my edit lands as a no-op at their '
      'revision, so my checked delete names it and deletes the item on B',
      () {
        final server = Server();
        final client = quietClient()..read(server.rows);
        hold(client, 1000, heldAt);
        final fields = FieldMerge(fields: ['position']);
        client.edit(movePatch('field', x: 40, merge: fields));
        client.edit(elementDelete('drop', expected: 2));
        server.rows = aTrashed(
          withOp(
            server.rows,
            ElementPatchOp(
              opId: 'their-move',
              elementPublicId: 'e1',
              expectedElementRevision: 1,
              pagePublicId: 'page-b',
              payload: movePatch('theirs', x: 40).payload,
              sortIndex: 5,
            ),
          ),
        );
        final field = claimAt(client, ['field'], live);
        final fieldAnswer = server.apply(clientId, field.ops.single);
        expect(fieldAnswer, isA<NoopAnswer>());
        client.must(OpAnswered(field.attempt, fieldAnswer, point: tick()));
        client.arrive(headerReadOf(server.rows));
        final drop = claimAt(client, ['drop'], live).ops.single;
        expect((drop as ElementDeleteOp).lastWriterWins, isFalse);
        expect(drop.expectedElementRevision, 2);
        expect(server.apply(clientId, drop), isA<AppliedAnswer>());
        expect(server.rows.element('e1'), isA<DeletedElement>());
        expect(server.rows.element('e1')!.pagePublicId, 'page-b');
      },
    );

    test('known behaviour, main\'s: once the store has read the item on '
        'page B, a live delete is last writer wins and deletes it there', () {
      final (:client, :server, seenAt: _) = deleteWaiting(behindOwn: false);
      server.rows = aTrashed(movedToB(server.rows));
      client.read(server.rows);
      final sent = claimAt(client, ['drop'], live).ops.single;
      expect((sent as ElementDeleteOp).lastWriterWins, isTrue);
      expect(server.apply(clientId, sent), isA<AppliedAnswer>());
      expect(server.rows.element('e1')!.pagePublicId, 'page-b');
    });

    test('while page A stays on the live list, a delete sent live is last '
        'writer wins, as on main', () {
      final (:client, :server, seenAt: _) = deleteWaiting(behindOwn: false);
      server.rows = movedToB(server.rows);
      client.arrive(headerReadOf(server.rows));
      final sent = claimAt(client, ['drop'], live).ops.single;
      expect((sent as ElementDeleteOp).lastWriterWins, isTrue);
    });

    test('a whole write behind my own work names the revision I saw and is '
        'refused as changed', () {
      final server = Server();
      final client = quietClient()..read(server.rows);
      hold(client, 1000, heldAt);
      landOwnEdit(client, server);
      client.edit(onVisible(client.visible, movePatch('whole', x: 70)));
      server.rows = aTrashed(movedToB(server.rows));
      client.arrive(headerReadOf(server.rows));
      final before = server.rows.element('e1');
      expect(client.view('whole').sendable, isTrue);
      final sent = claimAt(client, ['whole'], live);
      expect(server.apply(clientId, sent.ops.single), isA<RejectedAnswer>());
      expect(server.rows.element('e1'), before);
    });
  });
}
