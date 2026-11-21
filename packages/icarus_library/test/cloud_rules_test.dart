import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';

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
      client.must(const BaseArrived(StrategyGone()));
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

  test('rule 3: an older read arriving later never overrides newer '
      'evidence', () {
    final client = Client();
    final newer = teammate(initialRows(), movePatch('theirs', x: 7));
    client.read(newer, pages: ['page-a']);
    final before = client.queue.base.rows[const ElementTarget('e1')];
    client.read(initialRows(), pages: ['page-a']);
    expect(client.queue.base.rows[const ElementTarget('e1')], before);
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
      expect(viewsOf(client.queue, now)['move']!.go, isA<Free>());
      expect(
        viewsOf(client.queue, later)['move']!.go,
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
      client.must(const BaseArrived(StrategyGone()));
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
}
