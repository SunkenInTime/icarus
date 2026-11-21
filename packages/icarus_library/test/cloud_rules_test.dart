import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

StrategyRowSet teammate(StrategyRowSet rows, StrategyOp op) => withOp(rows, op);

void main() {
  group('rule 1: a check compares what the user saw', () {
    test('a teammate\'s same move plus a rotation stops my stacked delete', () {
      final client = Client();
      client.edit(movePatch('move', x: 10));
      final attempt = client.claim(['move']);
      client.edit(elementDelete('delete', expected: 2));
      final server = teammate(
        initialRows(),
        movePatch('theirs', x: 10, rotation: 90),
      );
      client.must(
        OpAnswered(
          attempt,
          const NoopAnswer('move', revision: 2, replay: NoopReplay.notApplied),
        ),
      );
      expect(client.view('delete').holds, [
        AwaitingBase(const ElementTarget('e1')),
      ]);
      client.read(server);
      expect(
        client.view('delete').go,
        isA<NeedsUser>().having(
          (go) => go.reason,
          'reason',
          isA<ChangedUnseen>(),
        ),
      );
      expect(
        notApplicable(
          transition(
            client.queue,
            BatchClaimed(clientId: clientId, opIds: ['delete'], at: now),
            now: now,
          ),
        ),
        isA<NotInThatState>(),
      );
    });

    test('the same collision holds a page delete for the user', () {
      final client = Client();
      client.edit(movePatch('move', x: 10));
      final attempt = client.claim(['move']);
      client.edit(pageDelete('delete', 'page-a'));
      client.must(
        OpAnswered(
          attempt,
          const NoopAnswer('move', revision: 2, replay: NoopReplay.notApplied),
        ),
      );
      client.read(
        teammate(initialRows(), movePatch('theirs', x: 10, rotation: 90)),
      );
      expect(
        client.view('delete').go,
        isA<NeedsUser>().having((go) => go.reason, 'reason', isA<DeleteHeld>()),
      );
    });

    test('a checked op goes with the base\'s revision when the content is '
        'what the user saw', () {
      final client = Client();
      final there = teammate(
        teammate(initialRows(), movePatch('away', x: 5)),
        movePatch('back', expected: 2, x: 0),
      );
      client.read(there);
      client.edit(elementDelete('delete', expected: 3));
      client.claim(['delete']);
      expect(
        (client.lastSent().single as ElementDeleteOp).expectedElementRevision,
        3,
      );
    });
  });

  group('rule 2: a dependency is satisfied by an applied answer', () {
    test('a copy never shares a batch with an earlier edit of its source', () {
      final client = Client();
      client.edit(movePatch('move'));
      client.edit(pageAdd('copy', 'page-c', copyFrom: 'page-a'));
      expect(
        notApplicable(
          transition(
            client.queue,
            BatchClaimed(clientId: clientId, opIds: ['move', 'copy'], at: now),
            now: now,
          ),
        ),
        isA<HeldBack>(),
      );
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.revisionMismatch,
            NoServerCopy(),
          ),
        ),
      );
      expect(client.view('copy').holds, [
        const BehindEntry('move', Dependency.pageWork),
      ]);
      expect(
        Tally.of(client.queue, now).attention[Attention.waitingOnRefused],
        1,
      );
    });

    test('a move cannot be made without its source page', () {
      final move = movePatch('move', pageId: 'page-b');
      expect(
        editOf(move, authored: const AuthoredNoRow()),
        isA<NeedsRowPage>(),
      );
      final made = editOf(
        move,
        authored: const AuthoredNoRow(),
        rowPage: 'page-a',
      );
      expect(
        (made as EditMade).edit.scope,
        const Moving(from: 'page-a', to: 'page-b'),
      );
    });
  });

  group('rule 3: the state is a function of the facts', () {
    test('a copy whose page was read before its answer settles on the '
        'answer', () {
      final client = Client();
      client.edit(pageAdd('copy', 'page-c', copyFrom: 'page-b'));
      final attempt = client.claim(['copy']);
      final copy = client.queue.entries.single as PendingOp;
      final server = withOp(initialRows(), copy.op);
      client.read(server);
      client.must(
        OpAnswered(
          attempt,
          AppliedAnswer('copy', revision: server.strategy.revision),
        ),
      );
      expect(client.queue.entries, isEmpty);
    });

    test('a strategy gone before a delayed answer still settles the '
        'accepted entry', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.arrive(const StrategyGone());
      client.must(
        OpAnswered(attempt, const AppliedAnswer('move', revision: 2)),
      );
      expect(client.queue.entries, isEmpty);
      expect(standingOf(client.queue), Standing.deletedOnServer);
    });

    test('a late access refusal does not undo a newer confirmation, and '
        'nothing undoes a deletion', () {
      final client = Client();
      client.edit(movePatch('a'));
      client.edit(movePatch('b', elementId: 'e2'));
      final first = client.claim(['a']);
      client.must(TransportFailed(first, TransportFailure.network, at: now));
      final second = client.claim(['b']);
      client.must(EditAccessConfirmed(afterAttempt: second));
      client.must(BatchRefused(first, BatchRefusal.editAccessRemoved));
      expect(standingOf(client.queue), Standing.good);
      client.must(BatchRefused(second, BatchRefusal.strategyDeleted));
      client.must(EditAccessConfirmed(afterAttempt: second + 5));
      expect(standingOf(client.queue), Standing.deletedOnServer);
    });
  });

  group('evidence is ordered by read, not by revision', () {
    test('an earlier read arriving later never replaces a later one', () {
      final client = Client();
      final changed = teammate(initialRows(), movePatch('theirs', x: 7));
      final earlier = client.startRead();
      final later = client.startRead();
      client.arrive(pageReadOf(changed, 'page-a'), read: later);
      final before = client.queue.base.evidence(const ElementTarget('e1'));
      client.arrive(pageReadOf(initialRows(), 'page-a'), read: earlier);
      expect(client.queue.base.evidence(const ElementTarget('e1')), before);
    });

    test('a later read replaces an earlier one even with a lower '
        'revision', () {
      final client = Client();
      client.read(
        teammate(initialRows(), movePatch('theirs', x: 7)),
        pages: ['page-a'],
      );
      client.read(initialRows(), pages: ['page-a']);
      expect(
        client.queue.base.evidence(const ElementTarget('e1')),
        isA<RowSeen>().having((seen) => seen.revision, 'revision', 1),
      );
    });

    test('a complete read that omits a row is evidence it is absent', () {
      final client = Client();
      final without = withOp(
        withOp(initialRows(), elementDelete('gone', elementId: 'e2')),
        pageDelete('page gone', 'page-b', expected: 1),
      );
      final pageRead = pageReadOf(initialRows(), 'page-a') as PageRead;
      client.arrive(
        PageRead(
          page: pageRead.page,
          settings: pageRead.settings,
          elements: [
            for (final row in pageRead.elements)
              if (row.publicId != 'e2') row,
          ],
          lineupGroups: pageRead.lineupGroups,
        ),
      );
      expect(
        client.queue.base.evidence(const ElementTarget('e2')),
        isA<RowAbsent>(),
      );
      client.arrive(
        HeaderRead(
          strategy: without.strategy,
          pages: [
            for (final page in without.pages)
              if (page.publicId != 'page-b') page,
          ],
          settings: [
            for (final row in without.settings)
              if (row.pagePublicId != 'page-b') row,
          ],
        ),
      );
      expect(
        client.queue.base.evidence(const PageTarget('page-b')),
        isA<RowAbsent>(),
      );
      expect(client.queue.base.pageGoneAfter('page-b', 0), isTrue);
    });

    test('a read number not yet issued is refused', () {
      final client = Client();
      expect(
        notApplicable(
          client.step(
            BaseArrived(
              const StrategyGone(),
              read: client.queue.nextRead,
              startedAt: now,
            ),
          ),
        ),
        isA<NoSuchRead>(),
      );
    });
  });

  test('an unreadable row still gives its revision as base evidence', () {
    final client = Client();
    client.arrive(
      PageRead(
        page: page('page-a', sortIndex: 0),
        settings: settings('page-a'),
        elements: [
          UnreadableElement(
            publicId: 'e1',
            pagePublicId: 'page-a',
            stored: const {'publicId': 'e1', 'revision': 5, 'deleted': false},
            problem: 'newer',
            reason: const FromNewerBuild(),
          ),
        ],
        lineupGroups: const [],
      ),
    );
    expect(
      client.queue.base.evidence(const ElementTarget('e1')),
      isA<RowSeen>().having((seen) => seen.revision, 'revision', 5),
    );
  });

  group('rule 4: attempts are numbered by the queue', () {
    test('an answer counts only from an attempt that contained the op', () {
      final client = Client();
      client.edit(movePatch('a'));
      client.edit(movePatch('b', elementId: 'e2'));
      final first = client.claim(['a']);
      final second = client.claim(['b']);
      expect(second, greaterThan(first));
      expect(
        notApplicable(
          transition(
            client.queue,
            OpAnswered(first, const AppliedAnswer('b', revision: 2)),
            now: now,
          ),
        ),
        isA<NotInAttempt>(),
      );
    });
  });

  group('rule 6: after the server forgets, only a revision check is safe', () {
    test('a lost edit undone by a teammate needs the user once the window '
        'passes', () {
      final client = Client();
      client.edit(
        movePatch(
          'move',
          x: 10,
          merge: FieldMerge(fields: ['position'], base: {'position': null}),
        ),
      );
      final attempt = client.claim(['move']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      final server = teammate(
        teammate(initialRows(), movePatch('mine-landed', x: 10)),
        movePatch('theirs', expected: 2, x: 0),
      );
      client.read(server);
      final later = now.add(
        serverRemembersAnswersFor + const Duration(hours: 1),
      );
      expect(entryViews(client.queue, now)['move']!.go, isA<Free>());
      expect(
        entryViews(client.queue, later)['move']!.go,
        isA<NeedsUser>().having(
          (go) => go.reason,
          'reason',
          isA<ServerForgotAnswer>(),
        ),
      );
    });

    test('the window matches the server\'s purge of op records', () {
      final source = File('../../convex/maintenance.ts').readAsStringSync();
      final days = RegExp(
        r'const DAYS_30_MS = (\d+) \* 24 \* 60 \* 60 \* 1000;',
      ).firstMatch(source);
      expect(
        Duration(days: int.parse(days!.group(1)!)),
        serverRemembersAnswersFor,
      );
      expect(source, contains('Date.now() - DAYS_30_MS'));
    });
  });

  group('defects ruled out earlier', () {
    test('#631: an undo after a lost answer never removes the sent op', () {
      final client = Client();
      client.edit(movePatch('edit', x: 50));
      final attempt = client.claim(['edit']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.edit(movePatch('undo', expected: 2, x: 0));
      expect(client.view('edit').state, isA<AnswerUnknown>());
      expect(client.view('undo').holds, [
        const BehindEntry('edit', Dependency.sameRow),
      ]);
      expect(
        notApplicable(
          transition(client.queue, const UserDiscarded('edit'), now: now),
        ),
        isA<NotInThatState>(),
      );
    });

    test('#645: an op id in the queue cannot be issued again', () {
      final client = Client();
      client.edit(movePatch('first'));
      client.claim(['first']);
      expect(
        notApplicable(client.step(client.editEvent(movePatch('first')))),
        isA<OpIdTaken>(),
      );
    });

    test('#646: Use cloud removes only the refused op; a later edit of the '
        'item is then checked against the cloud version', () {
      final client = Client();
      client.edit(movePatch('refused'));
      final attempt = client.claim(['refused']);
      client.edit(movePatch('later', expected: 2, x: 40));
      client.edit(movePatch('elsewhere', elementId: 'e2'));
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'refused',
            RejectionReason.revisionMismatch,
            NoServerCopy(),
          ),
        ),
      );
      client.must(const UserUsedCloud('refused'));
      expect(client.queue.entries.map((entry) => entry.id), [
        'later',
        'elsewhere',
      ]);
      expect(
        client.view('later').go,
        isA<NeedsUser>().having(
          (go) => go.reason,
          'reason',
          isA<ChangedUnseen>(),
        ),
      );
    });
  });

  group('smaller items', () {
    test('the tally decoder refuses a negative count', () {
      expect(
        Tally.decode({
          'standing': 'good',
          'attention': {'oversized': -1},
          'unreadable': 1,
        }),
        isA<CouldNotRead<Tally>>(),
      );
    });

    test('an empty queue on a deleted strategy is not plain all saved', () {
      final client = Client();
      client.arrive(const StrategyGone());
      expect(
        syncStateOf(
          Tally.of(client.queue, now),
          network: Network.online,
          signedIn: SignedIn.thisAccount,
        ),
        isA<Outstanding>().having(
          (state) => state.face,
          'face',
          Face.deletedOnServer,
        ),
      );
    });

    test('Keep mine keeps the same entity, page id included', () {
      final client = Client();
      client.edit(pageDelete('delete', 'page-a'));
      client.read(initialRows(), pages: ['page-a']);
      final attempt = client.claim(['delete']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'delete',
            RejectionReason.revisionMismatch,
            NoServerCopy(),
          ),
        ),
      );
      expect(
        notApplicable(
          client.step(
            UserKeptMine(
              'delete',
              pageDelete('other', 'page-b'),
              authored: const AuthoredNoRow(),
            ),
          ),
        ),
        isA<OtherEntity>(),
      );
    });

    test('an upgrade request is cleared only when another build starts', () {
      final client = Client();
      client.edit(movePatch('a'));
      final attempt = client.claim(['a']);
      client.must(BatchRefused(attempt, BatchRefusal.upgradeRequired));
      client.must(const AppRestarted(build: build));
      expect(standingOf(client.queue), Standing.upgradeRequired);
      client.must(const AppRestarted(build: 'build-2'));
      expect(standingOf(client.queue), Standing.good);
    });
  });

  group('content is what the user saw', () {
    test('an item the base holds on another page needs the user, merges '
        'included', () {
      for (final merge in [
        null,
        FieldMerge(fields: ['position']),
      ]) {
        final client = Client();
        client.edit(movePatch('mine', x: 40, merge: merge));
        client.read(
          teammate(initialRows(), movePatch('theirs', pageId: 'page-b', x: 10)),
        );
        expect(
          client.view('mine').go,
          isA<NeedsUser>().having(
            (go) => go.reason,
            'reason',
            isA<ChangedUnseen>(),
          ),
          reason: '$merge',
        );
      }
    });

    test('a row with no readable revision is not the same fact as no row', () {
      final rows = strategyRows(
        elements: [
          UnreadableElement(
            publicId: 'e1',
            pagePublicId: 'page-a',
            stored: const {'publicId': 'e1'},
            problem: 'damaged',
            reason: const Damaged(),
          ),
        ],
      );
      expect(authoredFor(rows, elementDelete('x')), const AuthoredUnreadable());
      expect(
        authoredFor(rows, elementDelete('y', elementId: 'e7')),
        const AuthoredNoRow(),
      );
    });

    test('no row waits for evidence of absence instead of assuming it', () {
      final server = withOp(initialRows(), pageAdd('add', 'page-c'));
      final client = Client(base: server);
      client.queue = CloudQueue(
        entries: [
          PendingOp(
            place: 0,
            work: OpWork(
              ElementDeleteOp(
                opId: 'x',
                elementPublicId: 'ghost',
                pagePublicId: 'page-c',
                expectedElementRevision: 1,
              ),
            ),
            scope: const OnPage('page-c'),
            authored: const AuthoredNoRow(),
            policy: SendPolicy.checked,
            answer: const NotAnswered(),
            retriedAfter: 0,
          ),
        ],
        attempts: const {},
        nextAttempt: 1,
        nextRead: client.queue.nextRead,
        base: BaseFacts.none,
        strategy: StrategyFacts.fresh,
        session: client.queue.session,
      );
      expect(client.view('x').holds, [
        const AwaitingBase(ElementTarget('ghost')),
      ]);
      client.read(server, pages: ['page-c']);
      expect(client.view('x').holds, isEmpty);
      expect(client.view('x').go, isA<Free>());
    });

    test('an edit always records its field base; the policy only decides '
        'whether it goes on the wire', () {
      final bare = movePatch('bare', merge: FieldMerge(fields: ['position']));
      expect(
        editOf(bare, authored: const AuthoredNoRow(), rowPage: 'page-a'),
        isA<NeedsFieldBase>(),
      );
      final client = Client()..must(const ConnectionReturned());
      client.edit(bare);
      final stored = (client.queue.entries.single as PendingOp).op;
      expect((stored as ElementPatchOp).merge!.base, isNotNull);
      client.claim(['bare']);
      expect((client.lastSent().single as ElementPatchOp).merge!.base, isNull);
    });
  });

  test('work on a copied page waits until a read shows the copy', () {
    final client = Client();
    client.edit(pageAdd('copy', 'page-c', copyFrom: 'page-b'));
    final attempt = client.claim(['copy']);
    client.edit(elementAdd('add', pageId: 'page-c'));
    final copy = client.queue.entries.first as PendingOp;
    final server = withOp(initialRows(), copy.op);
    client.must(
      OpAnswered(
        attempt,
        AppliedAnswer('copy', revision: server.strategy.revision),
      ),
    );
    expect(client.view('add').holds, [
      const AwaitingBase(PageTarget('page-c')),
    ]);
    client.read(server);
    expect(client.queue.entries.map((entry) => entry.id), ['add']);
    expect(client.view('add').holds, isEmpty);
  });

  group('gone and live again are ordered by read', () {
    test('an accepted entry settles under a page found gone by a read '
        'started after its answer, not before', () {
      final client = Client();
      client.edit(elementAdd('add', pageId: 'page-b'));
      final attempt = client.claim(['add']);
      final early = client.startRead();
      client.must(OpAnswered(attempt, const AppliedAnswer('add', revision: 1)));
      client.arrive(const PageGone('page-b'), read: early);
      expect(client.view('add').state, isA<Accepted>());
      client.arrive(const PageGone('page-b'));
      expect(client.queue.entries, isEmpty);
    });

    test('a page-deleted refusal is reissued once a read started after it '
        'shows the page live', () {
      final client = Client();
      client.edit(elementAdd('add', pageId: 'page-b'));
      final attempt = client.claim(['add']);
      final early = client.startRead();
      client.must(
        OpAnswered(
          attempt,
          const FailedAnswer(
            'add',
            KnownFailure(FailureCode.pageDeleted),
            'deleted',
          ),
        ),
      );
      client.arrive(headerReadOf(initialRows()), read: early);
      expect(client.view('add').go, isA<Free>());
      client.arrive(headerReadOf(initialRows()));
      expect(
        client.view('add').go,
        isA<NeedsFreshId>().having(
          (go) => go.reason,
          'reason',
          isA<PageLiveAgain>(),
        ),
      );
      client.must(Reissue(const {'add': 'add again'}));
      client.claim(['add again']);
      expect(client.lastSent().single.opId, 'add again');
    });
  });

  group('after the server forgets an op', () {
    final later = now.add(serverRemembersAnswersFor + const Duration(hours: 1));

    Client lostDelete({required bool online}) {
      final client = Client();
      if (online) client.must(const ConnectionReturned());
      client.edit(elementDelete('x'));
      final attempt = client.claim(['x']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      return client..clock = later;
    }

    test('a read from before the window passed is not enough', () {
      final client = lostDelete(online: false);
      expect(client.view('x').holds, [const AwaitingBase(ElementTarget('e1'))]);
    });

    test('a row read as authored after the window is reissued under a fresh '
        'id in its checked form', () {
      final client = lostDelete(online: true);
      expect(
        (client.lastSent().single as ElementDeleteOp).lastWriterWins,
        isTrue,
      );
      client.read(initialRows(), pages: ['page-a']);
      expect(
        client.view('x').go,
        isA<NeedsFreshId>().having(
          (go) => go.reason,
          'reason',
          isA<ServerForgot>(),
        ),
      );
      client.must(Reissue(const {'x': 'x again'}));
      client.claim(['x again']);
      final sent = client.lastSent().single as ElementDeleteOp;
      expect(sent.opId, 'x again');
      expect(sent.lastWriterWins, isFalse);
      expect(sent.expectedElementRevision, 1);
    });

    test('a row changed since it was authored needs the user', () {
      final client = lostDelete(online: false);
      client.read(teammate(initialRows(), movePatch('theirs', rotation: 90)));
      expect(
        client.view('x').go,
        isA<NeedsUser>().having(
          (go) => go.reason,
          'reason',
          isA<ServerForgotAnswer>(),
        ),
      );
    });
  });

  group('construction and ordering', () {
    test('an upgrade request is replaced only by one from a later '
        'attempt', () {
      for (final laterFirst in [true, false]) {
        final client = Client();
        client.edit(movePatch('a'));
        client.edit(movePatch('b', elementId: 'e2'));
        final first = client.claim(['a']);
        client.must(const AppRestarted(build: 'build-2'));
        final second = client.claim(['b']);
        final refusals = [
          BatchRefused(first, BatchRefusal.upgradeRequired),
          BatchRefused(second, BatchRefusal.upgradeRequired),
        ];
        for (final refusal in laterFirst ? refusals.reversed : refusals) {
          client.must(refusal);
        }
        expect(
          client.queue.strategy.upgradeTold,
          UpgradeToldTo('build-2', attempt: second),
        );
        expect(standingOf(client.queue), Standing.upgradeRequired);
      }
    });

    test('an empty claim is refused and sends nothing', () {
      final client = Client()..edit(movePatch('a'));
      final before = client.effects.length;
      expect(
        notApplicable(
          client.step(BatchClaimed(clientId: clientId, opIds: [], at: now)),
        ),
        isA<NothingClaimed>(),
      );
      expect(client.effects.length, before);
    });

    test('a queue cannot be built with two entries under one id or an '
        'attempt number that could be issued again', () {
      final client = Client()..edit(movePatch('a'));
      final entry = client.queue.entries.single;
      CloudQueue make({
        List<QueueEntry>? entries,
        Map<int, AttemptFact>? attempts,
        int nextAttempt = 1,
      }) => CloudQueue(
        entries: entries ?? [entry],
        attempts: attempts ?? const {},
        nextAttempt: nextAttempt,
        nextRead: client.queue.nextRead,
        base: client.queue.base,
        strategy: client.queue.strategy,
        session: client.queue.session,
      );
      final pending = entry as PendingOp;
      final again = PendingOp(
        place: pending.place + 1,
        work: pending.work,
        scope: pending.scope,
        authored: pending.authored,
        policy: pending.policy,
        answer: pending.answer,
        retriedAfter: pending.retriedAfter,
      );
      expect(make, returnsNormally);
      expect(() => make(entries: [entry, again]), throwsArgumentError);
      final attempt = AttemptFact(
        number: 1,
        clientId: clientId,
        build: build,
        at: now,
        ops: [entry.op],
        outcome: const AttemptOpen(),
      );
      expect(() => make(attempts: {1: attempt}), throwsArgumentError);
      expect(
        () => make(attempts: {1: attempt}, nextAttempt: 2),
        returnsNormally,
      );
    });
  });
}
