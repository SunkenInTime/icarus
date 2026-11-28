import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_live_basis_test.dart' show claimAt, heldAt, hold, quietClient;
import 'cloud_server.dart';
import 'cloud_support.dart';

const page = 'page-a';

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

void main() {
  group('a teammate moves the item off page A, then page A leaves the live '
      'list, while my change to the item waits', () {
    test('a delete sent live, last writer wins, deletes the item on page B '
        'whether or not it waited behind my own work', () {
      for (final behindOwn in [false, true]) {
        final server = Server();
        final client = quietClient()..read(server.rows);
        hold(client, 1000, heldAt);
        if (behindOwn) landOwnEdit(client, server);
        final seenAt = (client.visible.element('e1')! as LiveElement).revision;
        client.edit(elementDelete('drop', expected: seenAt));
        server.rows = aTrashed(movedToB(server.rows));
        client.arrive(headerReadOf(server.rows));
        expect(
          client.view('drop').sendable,
          isTrue,
          reason: 'behind own $behindOwn',
        );
        final sent = claimAt(client, [
          'drop',
        ], heldAt + const Duration(seconds: 5));
        final delete = sent.ops.single as ElementDeleteOp;
        expect(delete.lastWriterWins, isTrue);
        expect(server.apply(clientId, delete), isA<AppliedAnswer>());
        expect(server.rows.element('e1'), isA<DeletedElement>());
        expect(server.rows.element('e1')!.pagePublicId, 'page-b');
      }
    });

    test('main does the same for a delete not behind my own work when page '
        'A stays live: sent live, it deletes the item on page B', () {
      final server = Server();
      final client = quietClient()..read(server.rows);
      hold(client, 1000, heldAt);
      final seenAt = (client.visible.element('e1')! as LiveElement).revision;
      client.edit(elementDelete('drop', expected: seenAt));
      server.rows = movedToB(server.rows);
      client.arrive(headerReadOf(server.rows));
      final sent = claimAt(client, [
        'drop',
      ], heldAt + const Duration(seconds: 5));
      final delete = sent.ops.single as ElementDeleteOp;
      expect(delete.lastWriterWins, isTrue);
      expect(server.apply(clientId, delete), isA<AppliedAnswer>());
      expect(server.rows.element('e1'), isA<DeletedElement>());
      expect(server.rows.element('e1')!.pagePublicId, 'page-b');
    });

    test('a delete sent checked names the revision I saw and is refused as '
        'changed', () {
      final server = Server();
      final client = quietClient()..read(server.rows);
      landOwnEdit(client, server);
      final seenAt = (client.visible.element('e1')! as LiveElement).revision;
      client.edit(elementDelete('drop', expected: seenAt));
      server.rows = aTrashed(movedToB(server.rows));
      client.arrive(headerReadOf(server.rows));
      final sent = claimAt(client, ['drop'], null);
      final delete = sent.ops.single as ElementDeleteOp;
      expect(delete.lastWriterWins, isFalse);
      expect(delete.expectedElementRevision, seenAt);
      expect(server.apply(clientId, delete), isA<RejectedAnswer>());
      expect(server.rows.element('e1'), isA<LiveElement>());
    });

    test('a whole write behind my own work names the revision I saw and is '
        'refused as changed, live or not', () {
      final server = Server();
      final client = quietClient()..read(server.rows);
      hold(client, 1000, heldAt);
      landOwnEdit(client, server);
      client.edit(onVisible(client.visible, movePatch('whole', x: 70)));
      server.rows = aTrashed(movedToB(server.rows));
      client.arrive(headerReadOf(server.rows));
      final before = server.rows.element('e1');
      expect(client.view('whole').sendable, isTrue);
      final sent = claimAt(client, [
        'whole',
      ], heldAt + const Duration(seconds: 5));
      expect(server.apply(clientId, sent.ops.single), isA<RejectedAnswer>());
      expect(server.rows.element('e1'), before);
    });
  });
}
