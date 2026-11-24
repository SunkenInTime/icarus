import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';
import 'support.dart';

const firstLife = 1763600000000;
const secondLife = 1763700000000;

LiveElement livedElement(String id, int life, {String pageId = 'page-a'}) =>
    LiveElement(
      publicId: id,
      pagePublicId: pageId,
      payload: agentPayload(id, const {}),
      sortIndex: 0,
      revision: 1,
      unknownFields: jsonObject({'createdAt': life}),
    );

StrategyRowSet livedRows(int life, List<String> elements) {
  final rows = strategyRows(
    elements: [for (final id in elements) livedElement(id, life)],
  );
  return StrategyRowSet(
    strategy: strategyRow(
      createdAt: DateTime.fromMillisecondsSinceEpoch(life, isUtc: true),
    ),
    pages: rows.pages.toList(),
    settings: rows.settings.toList(),
    elements: rows.elements.toList(),
    lineupGroups: rows.lineupGroups.toList(),
  );
}

void main() {
  test('a device holds queued edits while its strategy is deleted and '
      'uploaded again under the same id; when it reconnects, the edits of rows '
      'the new life holds ask, a delete of a row it lacks is done, and '
      'nothing the server held in the old life is drawn', () {
    final server = Server()..rows = livedRows(firstLife, ['e1', 'e2']);
    final client = Client(base: server.rows);
    client
      ..edit(movePatch('move', x: 40))
      ..edit(elementDelete('remove', elementId: 'e2'))
      ..edit(
        StrategyPatchOp(
          opId: 'rename',
          expectedStrategyRevision: 1,
          name: 'Renamed',
        ),
      );
    server.rows = livedRows(secondLife, ['e1', 'e5']);
    client.read(server.rows);
    expect(client.queue.shown.strategyVersion, const Version(secondLife, 1));
    expect(client.visible.element('e2'), isNull);
    final attempt = client.claim(['move', 'remove', 'rename']);
    final sent = client.effects.whereType<SendBatch>().last;
    expect(sent.lives, {
      'move': firstLife,
      'remove': firstLife,
      'rename': firstLife,
    });
    for (final op in sent.ops) {
      client.must(
        OpAnswered(
          attempt,
          server.apply(clientId, op, expectedLife: sent.lives[op.opId]),
        ),
      );
    }
    expect(entryViews(client.queue, now).keys, ['move', 'rename']);
    for (final opId in ['move', 'rename']) {
      expect(
        client.view(opId).state,
        isA<NeedsUser>().having(
          (state) => '${state.reason}',
          'reason',
          contains('row_replaced'),
        ),
        reason: opId,
      );
    }
    expect(
      server.rows.element('e1')!.toJson(),
      livedElement('e1', secondLife).toJson(),
    );
    expect(server.rows.strategy.name, 'Retake B');
    expect(client.visible.element('e2'), isNull);
    expect(client.visible.element('e5'), isNotNull);
  });
}
