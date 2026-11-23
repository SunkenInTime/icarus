import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';
import 'store_support.dart' show lineupGroup, lineupPayload;
import 'support.dart';

const monthLater = Duration(days: 31);

Client online({StrategyRowSet? base}) {
  final client = Client(base: base)..must(const ConnectionReturned());
  client.read(base ?? initialRows());
  return client;
}

void sendAndAnswer(Client client, Server server, List<String> ids) {
  final attempt = client.claim(ids);
  for (final op in client.lastSent()) {
    client.must(OpAnswered(attempt, server.apply(clientId, op)));
  }
}

void expectNamedAgainstTheNewLife(Client client, String opId) {
  final view = client.view(opId);
  expect(view.holds, isEmpty, reason: '${view.state}');
  client.claim([opId]);
  expect(expectedOf(client.lastSent().single), 1);
}

StrategyRowSet withGroup() => strategyRows(
  elements: initialRows().elements.toList(),
  lineupGroups: [lineupGroup('g0')],
);

LineupGroupPatchOp groupWrite(String opId, {int expected = 1}) =>
    LineupGroupPatchOp(
      opId: opId,
      lineupPublicId: 'g0',
      expectedLineupRevision: expected,
      payload: lineupPayload('g0', notes: opId),
      sortIndex: 0,
    );

void main() {
  group('a row whose id starts a new life after its purge', () {
    test('an element: this device\'s landed write from over 29 days ago does '
        'not outrank a fresh result of the row back at revision 1, so the next '
        'edit is not left waiting for a result that never comes, and goes out '
        'against the row as it is now', () {
      final client = online();
      client.edit(
        movePatch(
          'first',
          x: 40,
          merge: FieldMerge(fields: const ['position']),
        ),
      );
      final attempt = client.claim(['first']);
      client.must(
        OpAnswered(attempt, const AppliedAnswer('first', revision: 3)),
      );
      expect(client.queue.landed.single.revision, 3);
      expect(client.queue.landed.single.produced, isNull);
      client.clock = now.add(monthLater);
      client.read(
        strategyRows(
          elements: [
            element('e1', fields: const {'rotation': 90}),
            element('e2'),
            element('e3', pageId: 'page-b'),
          ],
        ),
        pages: ['page-a'],
      );
      client.edit(movePatch('next', x: 60));
      expectNamedAgainstTheNewLife(client, 'next');
      expect(client.queue.landed, isEmpty);
    });

    test('an element: a result read over 29 days ago no longer justifies what '
        'this device predicts its write produced', () {
      final server = Server()
        ..rows = strategyRows(
          elements: [
            element('e1', fields: const {'rotation': 90}),
            element('e2'),
            element('e3', pageId: 'page-b'),
          ],
        );
      final client = online();
      client.clock = now.add(monthLater);
      client.edit(
        movePatch('late', x: 60, merge: FieldMerge(fields: const ['position'])),
      );
      sendAndAnswer(client, server, ['late']);
      expect(client.queue.landed.single.produced, isNull);
    });

    test(
      'a lineup group: a landed write from over 29 days ago does not outrank '
      'a fresh result of the group back at revision 1',
      () {
        final server = Server()..rows = withGroup();
        final client = online(base: withGroup());
        client.edit(groupWrite('first'));
        sendAndAnswer(client, server, ['first']);
        expect(client.queue.landed.single.revision, 2);
        client.clock = now.add(monthLater);
        client.read(withGroup(), pages: ['page-a']);
        client.edit(groupWrite('next'));
        expectNamedAgainstTheNewLife(client, 'next');
      },
    );

    test('a page: a landed rename from over 29 days ago does not outrank a '
        'fresh page list showing the page back at revision 1', () {
      final server = Server();
      final client = online();
      client.edit(
        const PagePatchOp(
          opId: 'first',
          pagePublicId: 'page-b',
          expectedPageRevision: 1,
          name: 'Retakes',
        ),
      );
      sendAndAnswer(client, server, ['first']);
      expect(client.queue.landed.single.revision, 2);
      client.clock = now.add(monthLater);
      client.read(initialRows(), pages: const []);
      client.edit(
        const PagePatchOp(
          opId: 'next',
          pagePublicId: 'page-b',
          expectedPageRevision: 1,
          name: 'Executes',
        ),
      );
      expectNamedAgainstTheNewLife(client, 'next');
    });

    test('within 29 days a result at a lower revision does not outrank this '
        'device\'s landed write: it is older than the answer', () {
      final server = Server();
      final client = online();
      client.edit(movePatch('first', x: 40));
      sendAndAnswer(client, server, ['first']);
      client.clock = now.add(const Duration(days: 28));
      client.read(initialRows(), pages: ['page-a']);
      expect(client.queue.landed.single.revision, 2);
    });
  });

  group('a row a teammate moved to another page', () {
    test(
      'a whole write behind this device\'s own landed work waits for the page '
      'the row was last shown on, not the page the editor still draws it on',
      () {
        final moved = strategyRows(
          elements: [
            element('e1'),
            element('e2', pageId: 'page-b', revision: 2),
            element('e3', pageId: 'page-b'),
          ],
        );
        final client = online();
        client.read(moved);
        client.base = initialRows();
        client.edit(
          movePatch(
            'merge',
            elementId: 'e2',
            merge: FieldMerge(fields: const ['position']),
          ),
        );
        final attempt = client.claim(['merge']);
        client.must(
          OpAnswered(attempt, const AppliedAnswer('merge', revision: 4)),
        );
        expect(client.queue.landed.single.produced, isNull);
        client
          ..must(const ConnectionLost())
          ..must(const ConnectionReturned());
        client.edit(movePatch('whole', elementId: 'e2', expected: 4));
        expect(client.view('whole').holds, [
          awaitingResult(RowResult(const ElementTarget('e2'), 'page-b')),
        ]);
      },
    );
  });
}
