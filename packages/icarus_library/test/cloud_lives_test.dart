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
    expect(entryViews(client.queue, client.at).keys, ['move', 'rename']);
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

  group('an answer without a life', () {
    Client online() {
      final client = Client()..must(const ConnectionReturned());
      client.read(initialRows());
      return client;
    }

    test('a replay of a receipt written before the server sent lives leaves a '
        'landed record with no version: a later whole-row edit waits for the '
        'row\'s result, and that result settles it', () {
      final server = Server();
      final client = online();
      client.edit(movePatch('drag', x: 40));
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
      expect(client.queue.landed.single.version, isNull);
      client.edit(onVisible(client.visible, movePatch('drop', x: 70)));
      expect(client.view('drop').holds, [
        awaitingResult(const RowResult(ElementTarget('e1'), 'page-a')),
      ]);
      client.read(server.rows, pages: ['page-a']);
      expect(client.queue.landed, isEmpty);
      expect(client.view('drop').sendable, isTrue);
      client.claim(['drop']);
      final sent = client.effects.whereType<SendBatch>().last;
      expect(expectedOf(sent.ops.single), 2);
      expect(sent.lives, {'drop': fixtureLife});
    });

    test('a page result read before the answer does not settle it', () {
      final server = Server();
      final client = online();
      client.edit(movePatch('drag', x: 40));
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
      client.read(server.rows, pages: const []);
      expect(client.queue.landed, hasLength(1));
    });

    test('a refusal of a replaced row with no copy asks like any refusal '
        'without one', () {
      final client = online();
      client.edit(movePatch('drag', x: 40));
      final attempt = client.claim(['drag']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'drag',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
        ),
      );
      final plain = online();
      plain.edit(movePatch('drag', x: 40));
      final plainAttempt = plain.claim(['drag']);
      plain.must(
        OpAnswered(
          plainAttempt,
          const RejectedAnswer(
            'drag',
            RejectionReason.revisionMismatch,
            NoServerCopy(),
          ),
        ),
      );
      expect(
        client.view('drag').state,
        const NeedsUser(
          RefusedByServer(
            RejectedByServer(RejectionReason.rowReplaced, NoServerCopy()),
          ),
        ),
      );
      expect(
        plain.view('drag').state,
        const NeedsUser(
          RefusedByServer(
            RejectedByServer(RejectionReason.revisionMismatch, NoServerCopy()),
          ),
        ),
      );
      expect(
        client.visible.element('e1')!.toJson(),
        plain.visible.element('e1')!.toJson(),
      );
    });
  });

  test('a page this device added takes its life from the first page list '
      'that shows it, so a rename authored before then goes out naming it', () {
    final server = Server();
    final client = Client()..must(const ConnectionReturned());
    client.read(initialRows());
    client.edit(pageAdd('add', 'page-c'));
    final added = client.claim(['add']);
    client.must(
      OpAnswered(added, server.apply(clientId, client.lastSent().single)),
    );
    client.edit(
      PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-c',
        expectedPageRevision: 1,
        name: 'B site',
      ),
    );
    final pageLife = createdAtOf(server.rows.page('page-c')!)!;
    expect(pageLife, isNot(createdAtOf(server.rows.strategy)));
    client.read(server.rows, pages: const []);
    client.claim(['rename']);
    expect(client.effects.whereType<SendBatch>().last.lives, {
      'rename': pageLife,
    });
  });

  test('a page added here whose answer was lost, in a strategy deleted and '
      'uploaded again with a page of that id: on reconnect the page add is '
      'refused for the strategy\'s life, a rename of the page waits behind '
      'it, and giving the add up takes the rename with it, leaving the new '
      'page untouched', () {
    final server = Server();
    final client = Client()..must(const ConnectionReturned());
    client.read(initialRows());
    client.edit(pageAdd('add', 'page-c'));
    final lost = client.claim(['add']);
    server.apply(clientId, client.lastSent().single);
    client.must(TransportFailed(lost, TransportFailure.network, at: now));
    client.edit(
      PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-c',
        expectedPageRevision: 1,
        name: 'B site',
      ),
    );
    server
      ..rows = relivedRows(server.rows, secondLife)
      ..recorded.clear()
      ..firstClient.clear();
    client
      ..must(const ConnectionLost())
      ..must(const ConnectionReturned());
    client.read(server.rows);
    client.clock = now.add(const Duration(seconds: 1));
    final uploaded = server.rows;
    expect(client.view('rename').sendable, isFalse);
    final attempt = client.claim(['add']);
    final sent = client.effects.whereType<SendBatch>().last;
    expect(sent.ops.map((op) => op.opId), ['add']);
    expect(sent.lives, {'add': fixtureLife});
    client.must(
      OpAnswered(
        attempt,
        server.apply(clientId, sent.ops.single, expectedLife: fixtureLife),
      ),
    );
    expect(
      client.view('add').state,
      const NeedsUser(
        RefusedByServer(
          RejectedByServer(RejectionReason.rowReplaced, NoServerCopy()),
        ),
      ),
    );
    expect(client.view('rename').sendable, isFalse);
    expect(
      server.rows.page('page-c')!.toJson(),
      uploaded.page('page-c')!.toJson(),
    );
    client.must(const UserDiscarded('add'));
    expect(entryViews(client.queue, client.at), isEmpty);
    expect(
      server.rows.page('page-c')!.toJson(),
      uploaded.page('page-c')!.toJson(),
    );
  });
}

Row relived(Row row, int life) {
  final born = jsonObject({'createdAt': life});
  return switch (row) {
    LivePage() => LivePage(
      publicId: row.publicId,
      strategyPublicId: row.strategyPublicId,
      name: row.name,
      isAutoNamed: row.isAutoNamed,
      sortIndex: row.sortIndex,
      isAttack: row.isAttack,
      revision: 1,
      unknownFields: born,
    ),
    ReadablePageSettings() => ReadablePageSettings(
      pagePublicId: row.pagePublicId,
      settings: row.settings,
      revision: 1,
      unknownFields: born,
    ),
    LiveElement() => LiveElement(
      publicId: row.publicId,
      pagePublicId: row.pagePublicId,
      payload: row.payload,
      sortIndex: row.sortIndex,
      revision: 1,
      unknownFields: born,
    ),
    _ => row,
  };
}

StrategyRowSet relivedRows(StrategyRowSet rows, int life) => StrategyRowSet(
  strategy: strategyRow(
    createdAt: DateTime.fromMillisecondsSinceEpoch(life, isUtc: true),
  ),
  pages: [for (final row in rows.pages) relived(row, life) as PageRow],
  settings: [
    for (final row in rows.settings) relived(row, life) as PageSettingsRow,
  ],
  elements: [
    for (final row in rows.elements)
      if (row is LiveElement) relived(row, life) as ElementRow,
  ],
  lineupGroups: const [],
);
