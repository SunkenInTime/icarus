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
