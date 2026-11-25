import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
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
      expect(client.queue.shown.pageRead('page-a'), const ReadOwed());
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
      expect(client.queue.shown.list, const ReadThisSession());
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
      expect((read as ShownRead).shown.list, const ReadOwed());
    });
  });

  test('a replay answered with no life asks the user, counted as the server '
      'forgetting its answer', () {
    final client = Client();
    client.edit(movePatch('move'));
    final attempt = client.claim(['move']);
    client.must(
      OpAnswered(attempt, const AnswerWithoutLife('move', revision: 2)),
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
            null: jsonEncode({...header, 'read': 'maybe'}),
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

    final lifeless = <String, (HeaderRead, List<PageRead>, RowKey)>{
      'a page row': (
        HeaderRead(
          strategy: initialRows().strategy,
          pages: [
            LivePage(
              publicId: 'page-a',
              strategyPublicId: strategyId,
              name: 'Page 1',
              sortIndex: 0,
              isAttack: true,
              revision: 1,
            ),
          ],
          settings: const [],
        ),
        const [],
        const PageKey('page-a'),
      ),
      'a page settings row': (
        HeaderRead(
          strategy: initialRows().strategy,
          pages: [initialRows().page('page-a')!],
          settings: [
            ReadablePageSettings(
              pagePublicId: 'page-a',
              settings: defaultSettings,
              revision: 1,
            ),
          ],
        ),
        const [],
        const PageSettingsKey('page-a'),
      ),
      'an element row': (
        headerReadOf(initialRows()),
        [
          PageRead(
            page: initialRows().page('page-a')!,
            elements: [withoutLife('e1')],
            lineupGroups: const [],
          ),
        ],
        const ElementKey('e1'),
      ),
      'a lineup row': (
        headerReadOf(initialRows()),
        [
          PageRead(
            page: initialRows().page('page-a')!,
            elements: const [],
            lineupGroups: [
              LiveLineupGroup(
                strategyPublicId: strategyId,
                publicId: 'g1',
                pagePublicId: 'page-a',
                payload: LineupGroupPayload(
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
                      {'id': 'k1', 'originId': 'o1', 'landingId': 'l1'},
                    ],
                  },
                ),
                sortIndex: 0,
                revision: 1,
              ),
            ],
          ),
        ],
        const LineupGroupKey(strategyId, 'g1'),
      ),
    };
    for (final MapEntry(key: kind, value: (header, pages, key))
        in lifeless.entries) {
      test('$kind with no life is refused, naming it', () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        expect(
          await store.addCloudStrategy(testAccount, header, pages),
          isA<Refused<StrategySummary, LibraryRefusal>>().having(
            (refused) => refused.reason,
            'reason',
            ResultWithoutLife(key),
          ),
        );
      });
    }

    test('after the store is closed and opened again', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      final session = await sessionOf(store);
      expect(
        await store.record(testAccount, strategyId, [
          BaseArrived(
            PageRead(
              page: initialRows().page('page-a')!,
              elements: [withoutLife('e1')],
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
    });

    test('a row this build cannot draw keeps the life the server sent, so its '
        'page is stored', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      final undrawable = UnreadableElement(
        publicId: 'e9',
        pagePublicId: 'page-a',
        stored: {
          ...element('e9').toJson(),
          'payload': {
            'kind': 'hologram',
            'payloadVersion': 1,
            'data': <String, Object?>{},
          },
        },
        problem: 'a kind from a newer build',
        reason: const FromNewerBuild(),
      );
      expect(createdAtOf(undrawable), fixtureLife);
      savedValue(
        await store.addCloudStrategy(testAccount, headerReadOf(initialRows()), [
          PageRead(
            page: initialRows().page('page-a')!,
            elements: [undrawable],
            lineupGroups: const [],
          ),
        ]),
      );
    });
  });

  group('a result the store refused has a face, and the sender reads it '
      'again', () {
    test('a refused page is counted as unreadable work until a page the store '
        'keeps arrives', () {
      final client = Client();
      client.must(
        const ResultRefused(page: 'page-a', problem: 'ResultWithoutLife(e1)'),
      );
      final tally = Tally.of(client.queue, now);
      expect(tally.unreadable, 1);
      expect(
        syncStateOf(
          OwnedBy(testAccount),
          tally,
          network: Network.online,
          signedIn: SignedInAs(testAccount),
        ),
        isA<Outstanding>().having(
          (state) => state.face,
          'face',
          Face.unreadableWork,
        ),
      );
      expect(owedReads(client.queue), {const PageResult('page-a')});
      client.arrive(pageReadOf(initialRows(), 'page-a'));
      expect(Tally.of(client.queue, now).unreadable, 0);
      expect(owedReads(client.queue), isEmpty);
    });

    test('the refusal is stored with the results', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await recordAll(store, [
        const ResultRefused(page: null, problem: 'ResultOutOfPlace(x)'),
      ]);
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      expect(
        (await syncOf(store)).queue.shown.list,
        const ReadRefused('ResultOutOfPlace(x)'),
      );
    });
  });

  group('one read state per list and per page', () {
    Client discardedTheLastRefusedOp() {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(BatchRefused(attempt, BatchRefusal.strategyReplaced));
      client.must(const UserDiscarded('move'));
      return client;
    }

    test('with nothing queued, an owed list is not reported as synced', () {
      final client = discardedTheLastRefusedOp();
      expect(client.queue.entries, isEmpty);
      final tally = Tally.of(client.queue, now);
      expect(tally.readsOwed, 1);
      expect(
        syncStateOf(
          OwnedBy(testAccount),
          tally,
          network: Network.online,
          signedIn: SignedInAs(testAccount),
        ),
        isA<Outstanding>().having(
          (state) => state.face,
          'face',
          Face.awaitingResult,
        ),
      );
    });

    test('an answer that the strategy is gone pays the debt', () {
      final client = discardedTheLastRefusedOp();
      client.arrive(const StrategyGone());
      expect(owedReads(client.queue), isEmpty);
      expect(Tally.of(client.queue, now).readsOwed, 0);
    });

    test('an owed page holds the edits on it, is counted, keeps what it '
        'showed, and its read pays it', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.edit(movePatch('later', elementId: 'e2'));
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
        ),
      );
      expect(client.queue.shown.pageRead('page-a'), const ReadOwed());
      expect(client.queue.shown.content.containsKey('page-a'), isTrue);
      expect(
        client.view('later').holds,
        contains(awaitingResult(const PageResult('page-a'))),
      );
      expect(Tally.of(client.queue, now).readsOwed, 1);
      client.arrive(pageReadOf(initialRows(), 'page-a'));
      expect(client.queue.shown.pageRead('page-a'), const ReadThisSession());
      expect(owedReads(client.queue), isEmpty);
    });

    test('the list debt is stored: it survives the store being closed and '
        'opened again', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      savedValue(
        await store.commitAs(testAccount, strategyId, movePatch('move')),
      );
      final claimed = await recordAll(store, [
        BatchClaimed(clientId: clientId, opIds: const ['move'], at: now),
      ]);
      final attempt = effectsOf(claimed).whereType<SendBatch>().single.attempt;
      await recordAll(store, [
        BatchRefused(attempt, BatchRefusal.strategyReplaced),
      ]);
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      expect((await syncOf(store)).queue.shown.list, const ReadOwed());
    });
  });

  group('review of the first lives push', () {
    test('a resend after the app starts again names the life the user '
        'edited, even once a result shows a replacement', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      expect(lastBatch(client).lives, {'move': fixtureLife});
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.must(const AppRestarted(build: build));
      client.read(withE1BornAgain());
      client.clock = now.add(const Duration(minutes: 5));
      client.claim(['move']);
      expect(lastBatch(client).lives, {'move': fixtureLife});
    });

    test('an edit made after the app starts again, over a row read in an '
        'earlier session, names that row\'s life', () {
      final client = Client();
      client.must(const AppRestarted(build: build));
      client.edit(movePatch('move'));
      client.claim(['move']);
      expect(lastBatch(client).lives, {'move': fixtureLife});
    });

    test('a field edit of a replacement row does not fold into an unsent '
        'edit of the row it replaced', () {
      final client = Client();
      final position = FieldMerge(fields: ['position']);
      client.edit(movePatch('first', x: 40, merge: position));
      client.base = withE1BornAgain(x: 7);
      client.arrive(pageReadOf(client.base, 'page-a'));
      client.edit(movePatch('second', x: 90, merge: position));
      expect(
        [for (final entry in client.queue.entries) entry.id],
        ['first', 'second'],
      );
      expect(
        [
          for (final entry in client.queue.entries)
            expectedLifeOf(entry as PendingOp),
        ],
        [fixtureLife, newerLife],
      );
    });

    test('a retry after a header of a later strategy life was read names the '
        'strategy life the op was written in', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.read(withStrategyLife(initialRows(), newerLife));
      client.clock = now.add(const Duration(minutes: 5));
      client.claim(['move']);
      expect(
        lastBatch(client).strategyLife,
        strategyCreatedAt.millisecondsSinceEpoch,
      );
    });

    test('a page rename refused as replaced is never delivered, even when '
        'the server\'s page has the same name', () {
      final client = Client();
      const rename = PagePatchOp(
        opId: 'rename',
        pagePublicId: 'page-a',
        expectedPageRevision: 1,
        name: 'Renamed',
      );
      client.edit(rename);
      final attempt = client.claim(['rename']);
      client.must(
        OpAnswered(
          attempt,
          RejectedAnswer(
            'rename',
            RejectionReason.rowReplaced,
            asTheServerHoldsIt(rename, life: newerLife),
          ),
        ),
      );
      expect(client.queue.entries.single.id, 'rename');
      expect(client.queue.landed, isEmpty);
      expect(stateOf(client, 'rename'), isA<NeedsUser>());
    });

    test('a queued move is not drawn onto a replacement strategy, even where '
        'its element has the same row life', () {
      final client = Client();
      client.edit(movePatch('move', x: 40));
      client.base = withStrategyLife(initialRows(), newerLife);
      client.read(client.base);
      expect(
        client.visible.element('e1')!.toJson(),
        initialRows().element('e1')!.toJson(),
      );
    });

    test('a store that sees a row recreated on another page at a lower '
        'revision moves it there', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      final old = initialRows().withRows([
        LiveElement(
          publicId: 'e3',
          pagePublicId: 'page-b',
          payload: agentPayload('e3', const {}),
          sortIndex: 0,
          revision: 5,
          unknownFields: jsonObject({'createdAt': fixtureLife}),
        ),
      ]);
      await addCloud(store, old);
      final session = await sessionOf(store);
      final again = LiveElement(
        publicId: 'e3',
        pagePublicId: 'page-a',
        payload: agentPayload('e3', const {}),
        sortIndex: 1,
        revision: 1,
        unknownFields: jsonObject({'createdAt': newerLife}),
      );
      await recordAll(store, [
        BaseArrived(
          PageRead(
            page: initialRows().page('page-a')!,
            elements: [...initialRows().elementsOn('page-a'), again],
            lineupGroups: const [],
          ),
          session: session,
        ),
      ]);
      final pageA = await store.readPage(strategyId, 'page-a');
      expect(
        (pageA as Found<PageContent>).value.elements.map((row) => row.publicId),
        contains('e3'),
      );
    });

    test('the stand-in server refuses a resend of a refused op the same way, '
        'so a refusal lost on the way arrives again', () {
      final server = Server();
      final client = Client(base: server.rows);
      client.edit(movePatch('move'));
      server.rows = server.rows.withRows([e1BornAgain()]);
      final attempt = client.claim(['move']);
      final lost = server.answer(clientId, lastBatch(client));
      expect(lost, [
        isA<OpAnswered>().having(
          (event) => event.answer,
          'answer',
          isA<RejectedAnswer>().having(
            (answer) => answer.reason,
            'reason',
            RejectionReason.rowReplaced,
          ),
        ),
      ]);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.clock = now.add(const Duration(minutes: 5));
      client.claim(['move']);
      final again = server.answer(clientId, lastBatch(client));
      (String, RejectionReason, ServerCopy) refusalIn(QueueEvent event) =>
          switch (event) {
            OpAnswered(
              answer: RejectedAnswer(
                :final opId,
                :final reason,
                :final current,
              ),
            ) =>
              (opId, reason, current),
            _ => fail('expected a refusal, got $event'),
          };
      expect(again.map(refusalIn).toList(), lost.map(refusalIn).toList());
      for (final event in again) {
        client.must(event);
      }
      expect(stateOf(client, 'move'), isA<NeedsUser>());

      final replaced = Server();
      final writer = Client(base: replaced.rows);
      writer.edit(movePatch('move'));
      final first = writer.claim(['move']);
      replaced.reupload();
      final refusedOnce = replaced.answer(clientId, lastBatch(writer));
      writer.must(TransportFailed(first, TransportFailure.network, at: now));
      writer.clock = now.add(const Duration(minutes: 5));
      writer.claim(['move']);
      expect(replaced.answer(clientId, lastBatch(writer)), [
        isA<BatchRefused>().having(
          (event) => event.refusal,
          'refusal',
          BatchRefusal.strategyReplaced,
        ),
      ]);
      expect(refusedOnce.single, isA<BatchRefused>());
    });
  });
}

StrategyRowSet withStrategyLife(StrategyRowSet rows, int life) =>
    StrategyRowSet(
      strategy: strategyRow(
        createdAt: DateTime.fromMillisecondsSinceEpoch(life, isUtc: true),
      ),
      pages: rows.pages,
      settings: rows.settings,
      elements: rows.elements,
      lineupGroups: rows.lineupGroups,
    );

LiveElement withoutLife(String id) => LiveElement(
  publicId: id,
  pagePublicId: 'page-a',
  payload: agentPayload(id, const {}),
  sortIndex: 0,
  revision: 1,
);
