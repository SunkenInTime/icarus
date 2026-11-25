import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'support.dart';

const newerLife = fixtureLife + 1000;

LiveElement e1BornAgain({double x = 0}) => LiveElement(
  publicId: 'e1',
  pagePublicId: 'page-a',
  payload: agentPayload('e1', {
    'position': {'dx': x, 'dy': 0},
  }),
  sortIndex: 0,
  revision: 1,
  unknownFields: jsonObject({'createdAt': newerLife}),
);

StrategyRowSet withE1BornAgain({double x = 0}) =>
    initialRows().withRows([e1BornAgain(x: x)]);

PendingState stateOf(Client client, String opId) => client.view(opId).state;

SendBatch lastBatch(Client client) =>
    client.effects.whereType<SendBatch>().last;

ServerSnapshot asTheServerHoldsIt(StrategyOp op, {required int life}) {
  final server = Server()..rows = withOp(initialRows(), op);
  final copy = server.currentOf(op) as ServerSnapshot;
  return ServerSnapshot(
    target: copy.target,
    revision: copy.revision,
    life: life,
    value: copy.value.toJson(),
  );
}

void main() {
  group('an op names the life of the row the user edited', () {
    test('a move goes out naming the moved row\'s life, and its batch names '
        'the strategy\'s', () {
      final client = Client();
      client.edit(movePatch('move'));
      client.claim(['move']);
      expect(lastBatch(client).lives, {'move': fixtureLife});
      expect(
        lastBatch(client).strategyLife,
        strategyCreatedAt.millisecondsSinceEpoch,
      );
    });

    test('sent again after its answer was lost, it still names the life the '
        'user edited, though a result now shows the row in a later life', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.arrive(pageReadOf(withE1BornAgain(), 'page-a'));
      client.clock = now.add(const Duration(minutes: 5));
      client.claim(['move']);
      expect(lastBatch(client).lives, {'move': fixtureLife});
    });

    test('an add names no row life, since its row has none yet', () {
      final client = Client();
      client.edit(elementAdd('add'));
      client.claim(['add']);
      expect(lastBatch(client).lives, isEmpty);
    });

    test('ops written in two known lives of the strategy do not go in one '
        'batch', () {
      final client = Client();
      client.edit(movePatch('first'));
      final later = initialRows();
      client.read(
        StrategyRowSet(
          strategy: strategyRow(
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              newerLife,
              isUtc: true,
            ),
          ),
          pages: later.pages,
          settings: later.settings,
          elements: later.elements,
          lineupGroups: later.lineupGroups,
        ),
      );
      client.edit(movePatch('second', elementId: 'e2'));
      expect(
        client.step(
          BatchClaimed(clientId: clientId, opIds: ['first', 'second'], at: now),
        ),
        isA<NotApplicable>(),
      );
    });
  });

  group('row_replaced', () {
    test('is refused, never delivered, even when the server\'s row holds '
        'what the op wrote, and the row\'s page is read again', () {
      final client = Client();
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
        ),
      );
      expect(
        stateOf(client, 'move'),
        isA<NeedsUser>().having(
          (state) => state.reason,
          'reason',
          RefusedByServer(
            RejectedByServer(
              RejectionReason.rowReplaced,
              asTheServerHoldsIt(move, life: newerLife),
            ),
          ),
        ),
      );
      expect(client.queue.landed, isEmpty);
      expect(client.queue.shown.content.containsKey('page-a'), isFalse);
      expect(
        client.step(BatchClaimed(clientId: clientId, opIds: ['move'], at: now)),
        isA<NotApplicable>(),
      );
    });
  });

  group('an edit is drawn only over its own row\'s life', () {
    test('a move of a row that a result shows replaced is not drawn over the '
        'replacement', () {
      final client = Client();
      client.edit(movePatch('move', x: 40));
      client.base = withE1BornAgain(x: 7);
      client.arrive(pageReadOf(client.base, 'page-a'));
      expect(
        client.visible.element('e1')!.toJson(),
        e1BornAgain(x: 7).toJson(),
      );
    });

    test('a move of the row as the user saw it is drawn', () {
      final client = Client();
      client.edit(movePatch('move', x: 40));
      expect(
        (client.visible.element('e1')! as LiveElement).payload.data
            .toJson()['position'],
        {'dx': 40, 'dy': 0},
      );
    });
  });

  group('STRATEGY_REPLACED', () {
    Client refused() {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.edit(movePatch('later', elementId: 'e2'));
      client.must(BatchRefused(attempt, BatchRefusal.strategyReplaced));
      return client;
    }

    test('refuses the batch\'s ops for the user and owes the page list, and '
        'while the list is owed nothing is sendable', () {
      final client = refused();
      expect(
        stateOf(client, 'move'),
        const NeedsUser(RefusedByServer(StrategyReplacedOnServer())),
      );
      expect(
        client.view('later').holds,
        contains(awaitingResult(const PageListResult())),
      );
      expect(client.view('later').sendable, isFalse);
      expect(owedReads(client.queue), {const PageListResult()});
      expect(Tally.of(client.queue, now).readsOwed, 1);
    });

    test('a page list pays the debt; the refused op still is not sent', () {
      final client = refused();
      client.arrive(headerReadOf(initialRows()));
      expect(client.queue.shown.listOwed, isFalse);
      expect(owedReads(client.queue), isEmpty);
      expect(client.view('later').sendable, isTrue);
      expect(
        client.step(BatchClaimed(clientId: clientId, opIds: ['move'], at: now)),
        isA<NotApplicable>(),
      );
    });

    test('the debt is stored with the results', () {
      final client = refused();
      final groups = shownToGroups(client.queue.shown);
      final read = shownFromGroups({
        for (final MapEntry(:key, :value) in groups.entries)
          key: jsonEncode(value),
      });
      expect((read as ShownRead).shown.listOwed, isTrue);
    });
  });

  test('a replay answered with no life asks the user, counted as the server '
      'forgetting its answer', () {
    final client = Client();
    client.edit(movePatch('move'));
    final attempt = client.claim(['move']);
    client.must(
      OpAnswered(
        attempt,
        const ReplayWithoutLife(
          'move',
          revision: 2,
          replay: NoopReplay.appliedWhenFirstReceived,
        ),
      ),
    );
    expect(
      stateOf(client, 'move'),
      const NeedsUser(RefusedByServer(AnsweredWithoutLife(2))),
    );
    expect(
      Tally.of(client.queue, now).attention[Attention.serverForgotAnswer],
      1,
    );
  });

  group(
    'stored lives and debts read back as written, and nothing else does',
    () {
      Map<String?, String> storedGroups(Shown shown) => {
        for (final MapEntry(:key, :value) in shownToGroups(shown).entries)
          key: jsonEncode(value),
      };

      test('a header whose lives are not a map is unreadable', () {
        final groups = storedGroups(Client().queue.shown);
        final header = jsonDecode(groups[null]!) as Map<String, Object?>;
        for (final broken in [7, 'lives', <Object?>[]]) {
          expect(
            shownFromGroups({
              ...groups,
              null: jsonEncode({...header, 'lives': broken}),
            }),
            isA<ShownUnreadable>().having(
              (unreadable) => unreadable.problem,
              'problem',
              contains('unreadable lives'),
            ),
          );
        }
      });

      test('a page list debt that is not true or false is unreadable', () {
        final groups = storedGroups(Client().queue.shown);
        final header = jsonDecode(groups[null]!) as Map<String, Object?>;
        expect(
          shownFromGroups({
            ...groups,
            null: jsonEncode({...header, 'listOwed': 'yes'}),
          }),
          isA<ShownUnreadable>(),
        );
      });

      test('an entry keeps the strategy life it was written in, and its '
          'refusal, through a write and a read', () {
        final client = Client();
        client.edit(movePatch('move'));
        final attempt = client.claim(['move']);
        client.must(BatchRefused(attempt, BatchRefusal.strategyReplaced));
        final entry = client.queue.entries.single as PendingOp;
        final read = decodeEntry(
          entry.place,
          jsonDecode(jsonEncode(entryToJson(entry))),
        );
        expect((read as Read<QueueEntry>).value, entry);
        expect(entry.strategyLife, strategyCreatedAt.millisecondsSinceEpoch);
      });
    },
  );

  group('a result row with no life is refused, never stored', () {
    test('when the strategy is added, naming the row', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      expect(
        await store.addCloudStrategy(testAccount, headerReadOf(initialRows()), [
          PageRead(
            page: initialRows().page('page-a')!,
            elements: [withoutLife('e1')],
            lineupGroups: const [],
          ),
        ]),
        isA<Refused<StrategySummary, LibraryRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          const ResultWithoutLife(ElementKey('e1')),
        ),
      );
    });

    test('when it arrives later, and the store keeps what it held', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final before = await syncOf(store);
      final session = await sessionOf(store);
      expect(
        await store.record(testAccount, strategyId, [
          BaseArrived(
            PageRead(
              page: initialRows().page('page-a')!,
              elements: [withoutLife('e1'), element('e2')],
              lineupGroups: const [],
            ),
            session: session,
          ),
        ]),
        isA<Refused<Recorded, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          const ResultWithoutLife(ElementKey('e1')),
        ),
      );
      expect((await syncOf(store)).queue.shown, before.queue.shown);
    });
  });
}

LiveElement withoutLife(String id) => LiveElement(
  publicId: id,
  pagePublicId: 'page-a',
  payload: agentPayload(id, const {}),
  sortIndex: 0,
  revision: 1,
);
