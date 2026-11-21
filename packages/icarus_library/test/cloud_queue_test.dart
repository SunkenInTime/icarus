import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/fold.dart';
import 'package:icarus_library/src/cloud/op_facts.dart'
    show CopyExpanded, CopyNotExpanded, expandCopy;
import 'package:icarus_library/src/cloud/visible.dart'
    show SomePages, visibleOver;
import 'package:icarus_library/src/field_merge.dart'
    show elementMergeBase, lineupMergeBase;
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';
import 'support.dart';

Client online({StrategyRowSet? base}) {
  final client = Client(base: base)..must(const ConnectionReturned());
  client.read(base ?? initialRows());
  return client;
}

PendingState stateOf(Client client, String id) => client.view(id).state;

void sendAndAnswer(Client client, Server server, List<String> ids) {
  final attempt = client.claim(ids);
  for (final op in client.lastSent()) {
    client.must(OpAnswered(attempt, server.apply(clientId, op)));
  }
}

ElementAddOp putBackOf(String opId, StrategyRows rows, String id) {
  final row = rows.element(id)! as LiveElement;
  return ElementAddOp(
    opId: opId,
    elementPublicId: id,
    pagePublicId: row.pagePublicId,
    payload: row.payload,
    sortIndex: row.sortIndex,
    expectedElementRevision: row.revision + 1,
  );
}

const day = Duration(days: 1);

void main() {
  group('an entry is in one of four states', () {
    test('waiting, sending, unanswered, and needing the user', () {
      final client = online();
      client.edit(movePatch('move'));
      expect(stateOf(client, 'move'), const Waiting());
      final attempt = client.claim(['move']);
      expect(stateOf(client, 'move'), Sending(attempt));
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      expect(stateOf(client, 'move'), isA<Unanswered>());
      client.clock = now.add(const Duration(minutes: 1));
      final again = client.claim(['move']);
      client.must(
        OpAnswered(
          again,
          const RejectedAnswer(
            'move',
            RejectionReason.revisionMismatch,
            NoServerCopy(),
          ),
        ),
      );
      expect(
        stateOf(client, 'move'),
        isA<NeedsUser>().having(
          (state) => state.reason,
          'reason',
          isA<RefusedByServer>(),
        ),
      );
    });
  });

  group('answers settle delivery, and nothing else does', () {
    test('an applied answer takes the entry out and its work stays drawn as '
        'landed until a result shows the row at that revision', () {
      final server = Server();
      final client = online();
      client.edit(movePatch('move', x: 40));
      sendAndAnswer(client, server, ['move']);
      expect(client.queue.entry('move'), isNull);
      expect(
        client.effects,
        contains(const OpRemoved('move', Delivered(Delivery.applied))),
      );
      expect(client.queue.landed.single.revision, 2);
      expect(
        syncStateOf(
          Tally.of(client.queue, now),
          network: Network.online,
          signedIn: SignedIn.thisAccount,
        ),
        isA<AllSaved>(),
      );
      expect(
        (client.visible.element('e1')! as LiveElement).payload.data
            .toJson()['position'],
        (server.rows.element('e1')! as LiveElement).payload.data
            .toJson()['position'],
      );
      client.read(initialRows(), pages: ['page-a']);
      expect(client.queue.landed, isNotEmpty);
      client.read(server.rows, pages: ['page-a']);
      expect(client.queue.landed, isEmpty);
    });

    test('reads never hold, release, settle or drop an entry', () {
      final client = online();
      client.edit(elementDelete('drop'));
      final gone = withOp(initialRows(), elementDelete('theirs'));
      client.read(gone);
      expect(client.queue.entry('drop'), isNotNull);
      expect(client.view('drop').sendable, isTrue);
      client.must(const AppRestarted(build: build));
      client.must(const ConnectionReturned());
      expect(client.view('drop').sendable, isTrue);
    });

    test('two people deleting the same element: the server answers nothing '
        'to do and nobody is asked', () {
      final server = Server()
        ..rows = withOp(initialRows(), elementDelete('theirs'));
      final client = Client();
      client.edit(elementDelete('mine'));
      client.must(const ConnectionReturned());
      sendAndAnswer(client, server, ['mine']);
      expect(client.queue.entries, isEmpty);
      expect(Tally.of(client.queue, now).needingYou, 0);
    });

    test('a rejection needs the user with the current row, and later work on '
        'that row is held behind it', () {
      final client = online();
      client.edit(movePatch('first', x: 40));
      client.edit(elementDelete('then', expected: 2));
      expect(client.view('then').holds, [
        const BehindEntry('first', Dependency.sameRow),
      ]);
      final attempt = client.claim(['first']);
      final current = ServerSnapshot(
        target: SnapshotTarget.element,
        revision: 3,
        value: const {'kind': 'agent'},
      );
      client.must(
        OpAnswered(
          attempt,
          RejectedAnswer('first', RejectionReason.revisionMismatch, current),
        ),
      );
      expect(
        stateOf(client, 'first'),
        NeedsUser(
          RefusedByServer(
            RejectedByServer(RejectionReason.revisionMismatch, current),
          ),
        ),
      );
      expect(client.view('then').sendable, isFalse);
      expect(
        Tally.of(client.queue, now).attention[Attention.waitingOnRefused],
        1,
      );
    });

    test('a rejection whose current row already holds what the op wrote is '
        'done', () {
      final client = online();
      client.edit(
        const StrategyPatchOp(
          opId: 'rename',
          expectedStrategyRevision: 1,
          name: 'Retake A',
        ),
      );
      final attempt = client.claim(['rename']);
      client.must(
        OpAnswered(
          attempt,
          RejectedAnswer(
            'rename',
            RejectionReason.revisionMismatch,
            ServerSnapshot(
              target: SnapshotTarget.strategy,
              revision: 4,
              value: const {'name': 'Retake A', 'mapData': 'ascent'},
            ),
          ),
        ),
      );
      expect(client.queue.entry('rename'), isNull);
      expect(
        client.effects,
        contains(
          const OpRemoved('rename', Delivered(Delivery.alreadyAsWritten)),
        ),
      );
    });

    test('a rejected element op is never judged done from the answer, which '
        'leaves out the page and place', () {
      final client = online();
      client.edit(movePatch('move', x: 40));
      final attempt = client.claim(['move']);
      final sent = client.lastSent().single as ElementPatchOp;
      client.must(
        OpAnswered(
          attempt,
          RejectedAnswer(
            'move',
            RejectionReason.revisionMismatch,
            ServerSnapshot(
              target: SnapshotTarget.element,
              revision: 3,
              value: sent.payload!.toJson(),
            ),
          ),
        ),
      );
      expect(stateOf(client, 'move'), isA<NeedsUser>());
    });

    test('a failed answer is a verdict: it needs the user and is never '
        'retried', () {
      final client = online();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(
          attempt,
          const FailedAnswer(
            'move',
            KnownFailure(FailureCode.pageDeleted),
            'gone',
          ),
        ),
      );
      expect(
        stateOf(client, 'move'),
        isA<NeedsUser>().having(
          (state) => state.reason,
          'reason',
          const RefusedByServer(
            FailedOnServer(KnownFailure(FailureCode.pageDeleted), 'gone'),
          ),
        ),
      );
      expect(client.view('move').sendable, isFalse);
    });

    test('a lost answer resends the same op with the same id in its checked '
        'form, with backoff, then pauses and is shown, never dropped', () {
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      var attempt = client.claim(['drag']);
      final first = client.lastSent().single as ElementPatchOp;
      expect(first.merge!.base, isNull);
      for (var failure = 1; failure <= retriesBeforePause; failure++) {
        client.must(
          TransportFailed(attempt, TransportFailure.network, at: client.at),
        );
        if (failure == retriesBeforePause) break;
        client.clock = client.at.add(const Duration(hours: 1));
        attempt = client.claim(['drag']);
        final again = client.lastSent().single as ElementPatchOp;
        expect(again.opId, 'drag');
        expect(again.merge!.base, isNotNull);
      }
      expect(stateOf(client, 'drag'), const NeedsUser(RetriesExhausted()));
      client.must(const UserRetried('drag'));
      expect(client.view('drag').sendable, isTrue);
    });
  });

  group('the window: a lost answer is resent only inside it', () {
    test('the client window is a day shorter than the server\'s memory', () {
      expect(resendWindow, const Duration(days: 29));
      expect(serverRemembersAnswersFor, const Duration(days: 30));
    });

    test('at day 29 an unanswered entry needs the user and is never '
        'resent, even after the clock moves back', () {
      final client = online();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.clock = now.add(const Duration(days: 29));
      expect(
        client.step(
          BatchClaimed(
            clientId: clientId,
            opIds: const ['move'],
            at: client.at,
          ),
        ),
        isA<NotApplicable>(),
      );
      expect(
        (client.queue.entry('move')! as PendingOp).window,
        const WindowPassed(),
      );
      client.clock = now.add(const Duration(hours: 1));
      client.must(const AppRestarted(build: build));
      expect(stateOf(client, 'move'), const NeedsUser(WindowClosed()));
      expect(client.view('move').sendable, isFalse);
    });

    test('a claim still open when the window passes is recorded too, and its '
        'answer is still taken if it arrives', () {
      final server = Server();
      final client = online();
      client.edit(movePatch('move', x: 40));
      final attempt = client.claim(['move']);
      client.clock = now.add(const Duration(days: 29));
      client.queue = recordExpiries(client.queue, client.at);
      expect(
        (client.queue.entry('move')! as PendingOp).window,
        const WindowPassed(),
      );
      client.must(
        OpAnswered(attempt, server.apply(clientId, client.lastSent().single)),
      );
      expect(client.queue.entry('move'), isNull);
    });

    test('an old add whose answer was lost does not come back after a '
        'teammate deleted it and the server forgot both', () {
      final server = Server();
      final client = online();
      client.edit(elementAdd('add', elementId: 'e9'));
      final attempt = client.claim(['add']);
      server.apply(clientId, client.lastSent().single);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      server.rows = withOp(
        server.rows,
        elementDelete('t', elementId: 'e9', expected: 1),
      );
      server.purgeAfterThirtyDays();
      client.clock = now.add(const Duration(days: 31));
      client.must(const ConnectionReturned());
      expect(stateOf(client, 'add'), const NeedsUser(WindowClosed()));
      expect(
        client.step(
          BatchClaimed(clientId: clientId, opIds: const ['add'], at: client.at),
        ),
        isA<NotApplicable>(),
      );
      expect(server.rows.element('e9'), isNull);
    });

    test('an old field merge whose answer was lost does not overwrite a '
        'teammate who put the field back', () {
      final server = Server();
      final client = Client();
      client.edit(
        movePatch('mine', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      client.must(const ConnectionReturned());
      final attempt = client.claim(['mine']);
      server.apply(clientId, client.lastSent().single);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      server.rows = withOp(server.rows, movePatch('t', expected: 2));
      server.purgeAfterThirtyDays();
      client.clock = now.add(const Duration(days: 31));
      client.must(const ConnectionReturned());
      expect(stateOf(client, 'mine'), const NeedsUser(WindowClosed()));
      expect(
        (server.rows.element('e1')! as LiveElement).payload.data
            .toJson()['position'],
        (withOp(initialRows(), movePatch('x')).element('e1')! as LiveElement)
            .payload
            .data
            .toJson()['position'],
      );
    });
  });

  group('dependencies keep work on one row in order', () {
    test('a stale patch rejected first never lets the delete behind it '
        'go', () {
      final server = Server()
        ..rows = withOp(initialRows(), movePatch('t', rotation: 90));
      final client = Client();
      client.edit(movePatch('stale', x: 40));
      client.edit(elementDelete('drop', expected: 2));
      client.must(const ConnectionReturned());
      expect(
        client.step(
          BatchClaimed(
            clientId: clientId,
            opIds: const ['stale', 'drop'],
            at: now,
          ),
        ),
        isA<NotApplicable>(),
      );
      sendAndAnswer(client, server, ['stale']);
      expect(stateOf(client, 'stale'), isA<NeedsUser>());
      expect(client.view('drop').sendable, isFalse);
      expect(server.rows.element('e1'), isA<LiveElement>());
    });

    test('a move cannot be made without its source page', () {
      final client = Client();
      client.edit(pageAdd('page', 'page-c'));
      client.edit(elementAdd('add', elementId: 'n', pageId: 'page-c'));
      expect(client.view('add').holds, [
        const BehindEntry('page', Dependency.pageAdd),
      ]);
    });

    test('a successor goes at the revision its predecessor landed at', () {
      final server = Server()
        ..rows = withOp(initialRows(), movePatch('t', rotation: 90));
      final client = Client(base: initialRows());
      client.must(const ConnectionReturned());
      client.edit(elementDelete('drop'));
      client.edit(putBackOf('back', initialRows(), 'e1'));
      sendAndAnswer(client, server, ['drop']);
      expect(server.rows.element('e1'), isA<DeletedElement>());
      final tombstone = (server.rows.element('e1')! as DeletedElement).revision;
      final attempt = client.claim(['back']);
      final sent = client.lastSent().single as ElementAddOp;
      expect(sent.expectedElementRevision, tombstone);
      client.must(OpAnswered(attempt, server.apply(clientId, sent)));
      expect(client.queue.entries, isEmpty);
      expect(server.rows.element('e1'), isA<LiveElement>());
    });
  });

  group('a put-back over this device\'s own delete (#668)', () {
    Client deletedAndPutBack() {
      final client = online();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      client.edit(putBackOf('back', drawn, 'e1'));
      return client;
    }

    test('it waits behind the delete while the delete is unsent, sending, '
        'unanswered or refused', () {
      final client = deletedAndPutBack();
      expect(client.view('back').holds, [
        const BehindEntry('del', Dependency.sameRow),
      ]);
      final attempt = client.claim(['del']);
      expect(client.view('back').sendable, isFalse);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      expect(client.view('back').sendable, isFalse);
      client.clock = now.add(const Duration(minutes: 1));
      final again = client.claim(['del']);
      client.must(
        OpAnswered(
          again,
          const RejectedAnswer(
            'del',
            RejectionReason.revisionMismatch,
            NoServerCopy(),
          ),
        ),
      );
      expect(client.view('back').sendable, isFalse);
    });

    test('answered applied by this device, it goes as an add over the '
        'tombstone at the revision the answer named, with no read', () {
      final client = deletedAndPutBack();
      final attempt = client.claim(['del']);
      client.must(OpAnswered(attempt, const AppliedAnswer('del', revision: 5)));
      client.claim(['back']);
      expect(
        (client.lastSent().single as ElementAddOp).expectedElementRevision,
        5,
      );
    });

    test('answered as nothing to do because someone else deleted it, it needs '
        'the user', () {
      final client = deletedAndPutBack();
      final attempt = client.claim(['del']);
      client.must(
        OpAnswered(
          attempt,
          const NoopAnswer('del', revision: 2, replay: NoopReplay.notApplied),
        ),
      );
      expect(stateOf(client, 'back'), const NeedsUser(ChangedUnseen()));
    });

    test('#631: an undo after a lost answer never removes the op that may '
        'have landed', () {
      final client = deletedAndPutBack();
      final attempt = client.claim(['del']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      expect(client.queue.entry('del'), isNotNull);
      expect(client.view('back').holds, [
        const BehindEntry('del', Dependency.sameRow),
      ]);
    });
  });

  group('landed work never authors', () {
    test('a whole write on a row whose latest knowledge is a landed field '
        'merge waits for that row\'s result, then goes when the row is as the '
        'user saw it', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(movePatch('drop', x: 70, expected: 2));
      expect(client.view('drop').holds, [
        awaitingResult(const RowResult(ElementTarget('e1'), 'page-a')),
      ]);
      client.read(server.rows, pages: ['page-a']);
      expect(client.view('drop').sendable, isTrue);
    });

    test('and it needs the user when the row\'s result shows fields the user '
        'never saw', () {
      final server = Server()
        ..rows = withOp(initialRows(), movePatch('t', rotation: 90));
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(movePatch('drop', x: 70, expected: 2));
      client.read(server.rows, pages: ['page-a']);
      expect(stateOf(client, 'drop'), const NeedsUser(ChangedUnseen()));
    });

    test('a field edit after a landed merge does not wait', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(
        movePatch(
          'again',
          x: 60,
          expected: 2,
          merge: FieldMerge(fields: ['position']),
        ),
      );
      expect(client.view('again').sendable, isTrue);
    });
  });

  group('the page delete exception, until #670', () {
    test('a page delete is held when the page no longer holds what the user '
        'saw, and the user can delete anyway', () {
      final client = online();
      client.edit(pageDelete('drop', 'page-a'));
      expect(client.view('drop').sendable, isTrue);
      client.read(
        withOp(initialRows(), movePatch('t', rotation: 90)),
        pages: ['page-a'],
      );
      expect(
        stateOf(client, 'drop'),
        const NeedsUser(DeleteHeld(HeldDeleteCause.pageChanged)),
      );
      client.must(const UserDeletedAnyway('drop'));
      expect(client.view('drop').sendable, isTrue);
    });

    test('a page delete made without its page ever read needs the user', () {
      final client = Client(base: initialRows());
      client.edit(pageDelete('drop', 'page-b'));
      final base = initialRows();
      client.queue = stepped(
        transition(
          CloudQueue.start(build: build),
          UserEdited(
            PageDeleteEdit(
              pageDelete('blind', 'page-b'),
              SeenPage(
                pageDigest: '',
                pageRevision: 0,
                content: const ContentNeverRead(),
              ),
              authoredFor(base, pageDelete('blind', 'page-b')),
            ),
          ),
          now: now,
        ),
      ).queue;
      expect(
        stateOf(client, 'blind'),
        const NeedsUser(DeleteHeld(HeldDeleteCause.contentNeverRead)),
      );
    });
  });

  group('sessions', () {
    test('a result from a session that ended is not applicable', () {
      final client = online();
      final old = client.queue.session.number;
      client.must(const ConnectionLost());
      client.must(const ConnectionReturned());
      expect(
        notApplicable(
          client.step(BaseArrived(headerReadOf(initialRows()), session: old)),
        ),
        isA<FromAnEndedSession>(),
      );
    });

    test('an edit made while connected goes live the first time and checked '
        'after a reconnect', () {
      final client = online();
      client.edit(elementDelete('drop', elementId: 'e2'));
      client.must(const ConnectionLost());
      client.must(const ConnectionReturned());
      client.claim(['drop']);
      expect(
        (client.lastSent().single as ElementDeleteOp).lastWriterWins,
        isFalse,
      );
      final live = online();
      live.edit(elementDelete('drop', elementId: 'e2'));
      live.claim(['drop']);
      expect(
        (live.lastSent().single as ElementDeleteOp).lastWriterWins,
        isTrue,
      );
    });
  });

  group('attempts and standing', () {
    test('an answer counts only from an attempt that contained the op', () {
      final client = online();
      client.edit(movePatch('a'));
      client.edit(movePatch('b', elementId: 'e2'));
      final attempt = client.claim(['a']);
      expect(
        notApplicable(
          client.step(
            OpAnswered(attempt, const AppliedAnswer('b', revision: 2)),
          ),
        ),
        isA<NotInAttempt>(),
      );
    });

    test('an empty claim is refused and sends nothing', () {
      final client = online();
      expect(
        notApplicable(
          client.step(
            BatchClaimed(clientId: clientId, opIds: const [], at: now),
          ),
        ),
        isA<NothingClaimed>(),
      );
    });

    test('#645: an op id in the queue cannot be issued again', () {
      final client = online();
      client.edit(movePatch('same'));
      expect(
        notApplicable(client.step(client.editEvent(movePatch('same')))),
        isA<OpIdTaken>(),
      );
    });

    test('a late access refusal does not undo a newer confirmation, and '
        'nothing undoes a deletion', () {
      final client = online();
      client.edit(movePatch('a'));
      client.edit(movePatch('b', elementId: 'e2'));
      final first = client.claim(['a']);
      client.must(TransportFailed(first, TransportFailure.network, at: now));
      final second = client.claim(['b']);
      client.must(EditAccessConfirmed(afterAttempt: second));
      client.must(BatchRefused(first, BatchRefusal.editAccessRemoved));
      expect(standingOf(client.queue), Standing.good);
      client.must(BatchRefused(second, BatchRefusal.strategyDeleted));
      client.must(EditAccessConfirmed(afterAttempt: second));
      expect(standingOf(client.queue), Standing.deletedOnServer);
    });

    test('an upgrade request is replaced only by one from a later attempt, '
        'and cleared when another build starts', () {
      for (final laterFirst in [true, false]) {
        final client = online();
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
        client.must(const AppRestarted(build: 'build-3'));
        expect(standingOf(client.queue), Standing.good);
      }
    });

    test('an empty queue on a deleted strategy is not plain all saved', () {
      final client = online();
      client.arrive(const StrategyGone());
      expect(
        syncStateOf(
          Tally.of(client.queue, now),
          network: Network.online,
          signedIn: SignedIn.thisAccount,
        ),
        isA<Outstanding>(),
      );
    });

    test('the tally decoder refuses a negative count', () {
      expect(
        Tally.decode({
          'standing': 'good',
          'waiting': {'unsent': -1},
        }),
        isA<CouldNotRead<Tally>>(),
      );
    });
  });

  group('the user\'s choices', () {
    test('#646: use cloud removes only the refused op', () {
      final client = online();
      client.edit(movePatch('refused', x: 40));
      client.edit(movePatch('other', elementId: 'e2'));
      final attempt = client.claim(['refused']);
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
      expect(client.queue.entries.map((entry) => entry.id), ['other']);
    });

    test('keep mine replaces the refused op with the same entity under a '
        'fresh id', () {
      final client = online();
      client.edit(movePatch('refused', x: 40));
      final attempt = client.claim(['refused']);
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
      expect(
        notApplicable(
          client.step(
            UserKeptMine(
              'refused',
              movePatch('fresh', elementId: 'e2', expected: 3),
              authored: const AuthoredNoRow(),
            ),
          ),
        ),
        isA<OtherEntity>(),
      );
      client.must(
        UserKeptMine(
          'refused',
          movePatch('fresh', expected: 3, x: 40),
          authored: const AuthoredNoRow(),
        ),
      );
      expect(client.queue.entries.single.id, 'fresh');
      expect(client.view('fresh').sendable, isTrue);
    });
  });

  test('an edit always records its field base; the policy only decides '
      'whether it goes on the wire', () {
    final client = online();
    client.edit(
      movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
    );
    final entry = client.queue.entry('drag')! as PendingOp;
    expect((entry.op as ElementPatchOp).merge!.base, isNotNull);
  });

  group('standing and access', () {
    test('a strategy gone before a delayed answer still takes the answer', () {
      final client = online();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.arrive(const StrategyGone());
      client.must(
        OpAnswered(attempt, const AppliedAnswer('move', revision: 2)),
      );
      expect(client.queue.entry('move'), isNull);
      expect(standingOf(client.queue), Standing.deletedOnServer);
    });

    test('a strategy gone from the server keeps every entry', () {
      final client = online();
      client.edit(movePatch('move'));
      client.arrive(const StrategyGone());
      expect(standingOf(client.queue), Standing.deletedOnServer);
      expect(client.queue.entry('move'), isNotNull);
    });

    test('an upgrade refusal for a batch an older build sent does not hold '
        'sending in the newer build', () {
      final client = online();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(const AppRestarted(build: 'a newer build'));
      client.must(BatchRefused(attempt, BatchRefusal.upgradeRequired));
      expect(client.effects, isNot(contains(isA<HoldSendingForUpgrade>())));
      expect(standingOf(client.queue), Standing.good);
    });

    test('confirming edit access after an attempt never made is not '
        'applicable', () {
      expect(
        notApplicable(
          Client().step(const EditAccessConfirmed(afterAttempt: 7)),
        ),
        isA<NoSuchAttempt>(),
      );
    });

    test('a later accepted batch is evidence of edit access', () {
      final client = online();
      client.edit(movePatch('first'));
      client.edit(movePatch('second', elementId: 'e2'));
      final early = client.claim(['first']);
      final late = client.claim(['second']);
      client.must(BatchRefused(early, BatchRefusal.editAccessRemoved));
      expect(standingOf(client.queue), Standing.editAccessLost);
      client.must(OpAnswered(late, const AppliedAnswer('second', revision: 2)));
      expect(standingOf(client.queue), Standing.good);
    });

    test('the queue counts cannot be changed by whoever reads them', () {
      final counts = queueCounts(Client().queue, now);
      expect(counts.waiting.clear, throwsUnsupportedError);
      expect(counts.attention.clear, throwsUnsupportedError);
    });

    test(
      'an entry waiting for a result is counted as underway, not unsent',
      () {
        final server = Server();
        final client = online();
        client.edit(
          movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
        );
        sendAndAnswer(client, server, ['drag']);
        client.edit(movePatch('drop', x: 70, expected: 2));
        final tally = Tally.of(client.queue, now);
        expect(tally.waiting[Underway.awaitingResult], 1);
        expect(tally.waiting[Underway.unsent], isNull);
      },
    );
  });

  test('a queue cannot be built with two entries under one id or an attempt '
      'number that could be issued again', () {
    final client = Client()..edit(movePatch('a'));
    final entry = client.queue.entries.single as PendingOp;
    CloudQueue make({
      List<QueueEntry>? entries,
      Map<int, AttemptFact>? attempts,
      int nextAttempt = 1,
    }) => CloudQueue(
      entries: entries ?? [entry],
      attempts: attempts ?? const {},
      landed: const [],
      nextAttempt: nextAttempt,
      nextSession: client.queue.nextSession,
      shown: client.queue.shown,
      strategy: client.queue.strategy,
      session: client.queue.session,
    );
    final again = PendingOp(
      place: entry.place + 1,
      work: entry.work,
      scope: entry.scope,
      authored: entry.authored,
      authoredIn: entry.authoredIn,
      refusal: entry.refusal,
      retriedAfter: entry.retriedAfter,
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
    expect(() => make(attempts: {1: attempt}, nextAttempt: 2), returnsNormally);
  });

  test('a put-back behind a delete whose window passed waits with it for the '
      'user', () {
    final client = online();
    final drawn = client.visible;
    client.edit(elementDelete('del'));
    client.edit(putBackOf('back', drawn, 'e1'));
    final attempt = client.claim(['del']);
    client.must(TransportFailed(attempt, TransportFailure.network, at: now));
    client.clock = now.add(resendWindow);
    client.queue = look(client.queue, client.at).queue;
    expect(stateOf(client, 'del'), const NeedsUser(WindowClosed()));
    expect(client.view('back').holds, [
      const BehindEntry('del', Dependency.sameRow),
    ]);
  });

  test('a page copy reaches the queue as ordinary adds under ids derived on '
      'this device', () {
    final rows = initialRows();
    final copy = pageAdd('copy', 'page-c', copyFrom: 'page-a', sortIndex: 2);
    final ops = switch (expandCopy(rows, copy)) {
      CopyExpanded(:final ops) => ops,
      CopyNotExpanded() => fail('page-a can be copied'),
    };
    expect(ops.first, isA<PageAddOp>());
    expect((ops.first as PageAddOp).copyContentFromPagePublicId, isNull);
    final adds = ops.skip(1).whereType<ElementAddOp>().toList();
    expect(adds.map((op) => op.pagePublicId).toSet(), {'page-c'});
    expect(adds.map((op) => op.elementPublicId), everyElement(startsWith('e')));
    final again = switch (expandCopy(rows, copy)) {
      CopyExpanded(:final ops) => ops,
      CopyNotExpanded() => const <StrategyOp>[],
    };
    expect(
      again.map((op) => op.toJson()).toList(),
      ops.map((op) => op.toJson()).toList(),
    );
  });

  group('lineup items', () {
    Map<String, Object?> link(String id, String notes) => {
      'id': id,
      'originId': 'o0',
      'landingId': 'l0',
      'notes': notes,
    };

    LineupGroupPayload lineup(List<Map<String, Object?>> links) =>
        LineupGroupPayload(
          payloadVersion: 1,
          data: {
            'id': 'g0',
            'origins': [
              {'id': 'o0', 'agent': <String, Object?>{}},
            ],
            'landings': [
              {'id': 'l0', 'ability': <String, Object?>{}},
            ],
            'links': links,
          },
        );

    StrategyRowSet withGroup() => strategyRows(
      elements: initialRows().elements.toList(),
      lineupGroups: [
        LiveLineupGroup(
          strategyPublicId: strategyId,
          publicId: 'g0',
          pagePublicId: 'page-a',
          payload: lineup([link('k1', '')]),
          sortIndex: 0,
          revision: 1,
        ),
      ],
    );

    String notesOf(StrategyRowSet rows) {
      final row = rows.lineupGroup('g0')! as LiveLineupGroup;
      final links = row.payload.data.toJson()['links']! as List<Object?>;
      return (links.single! as Map<String, Object?>)['notes']! as String;
    }

    test('a lineup note edited twice before sending reaches the server as '
        'the last note', () {
      final server = Server()..rows = withGroup();
      final client = online(base: withGroup());
      for (final (id, notes) in [('n1', 'jump'), ('n2', 'jump throw')]) {
        client.edit(
          LineupGroupPatchOp(
            opId: id,
            lineupPublicId: 'g0',
            expectedLineupRevision: 1,
            payload: lineup([link('k1', notes)]),
            sortIndex: 0,
            merge: FieldMerge(fields: ['links/k1']),
          ),
        );
      }
      final ids = [for (final entry in client.queue.entries) entry.id];
      sendAndAnswer(client, server, ids);
      expect(notesOf(server.rows), 'jump throw');
    });

    test('a lineup note edited online and held through a disconnect goes '
        'checked and lands', () {
      final server = Server()..rows = withGroup();
      final client = online(base: withGroup());
      client.edit(
        LineupGroupPatchOp(
          opId: 'note',
          lineupPublicId: 'g0',
          expectedLineupRevision: 1,
          payload: lineup([link('k1', 'jump')]),
          sortIndex: 0,
          merge: FieldMerge(fields: ['links/k1']),
        ),
      );
      client.must(const ConnectionLost());
      client.must(const ConnectionReturned());
      sendAndAnswer(client, server, ['note']);
      expect(client.queue.entries, isEmpty);
      expect(notesOf(server.rows), 'jump');
    });
  });

  group('every field name form the field merge accepts', () {
    LineupGroupPayload full(String tag) => LineupGroupPayload(
      payloadVersion: 1,
      data: {
        'id': 'g0',
        'origins': [
          {'id': 'o0', 'agent': <String, Object?>{}, 'tag': tag},
        ],
        'landings': [
          {'id': 'l0', 'ability': <String, Object?>{}, 'tag': tag},
        ],
        'links': [
          {'id': 'k1', 'originId': 'o0', 'landingId': 'l0', 'notes': tag},
        ],
      },
    );
    final stored = LiveLineupGroup(
      strategyPublicId: strategyId,
      publicId: 'g0',
      pagePublicId: 'page-a',
      payload: full('stored'),
      sortIndex: 0,
      revision: 1,
    );
    final rows = strategyRows(
      elements: initialRows().elements.toList(),
      lineupGroups: [stored],
    );

    for (final name in ['origins/o0', 'landings/l0', 'links/k1']) {
      test('the lineup item $name', () {
        LineupGroupPatchOp edit(String id, String tag) => LineupGroupPatchOp(
          opId: id,
          lineupPublicId: 'g0',
          expectedLineupRevision: 1,
          payload: full(tag),
          sortIndex: 0,
          merge: FieldMerge(fields: [name]),
        );
        final based = withFieldBase(rows, edit('first', 'one'));
        final item = lineupMergeBase(stored.payload, 0, [name]);
        expect((based as LineupGroupPatchOp).merge!.base!.toJson(), item);
        expect(item[name], isNotNull);
        final folded = fold(edit('first', 'one'), edit('then', 'two'));
        final payload =
            ((folded as FoldedOp).op as LineupGroupPatchOp).payload!;
        expect(lineupMergeBase(payload, 0, [name]), {
          name: lineupMergeBase(full('two'), 0, [name])[name],
        });
      });
    }

    final e1 = initialRows().element('e1')! as LiveElement;
    for (final fields in [
      ['position'],
      ['rotation', 'length'],
      [placeField],
    ]) {
      test('the element fields $fields', () {
        ElementPatchOp edit(String id, int value) => ElementPatchOp(
          opId: id,
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          payload: agentPayload('e1', {
            ...e1.payload.data.toJson(),
            'position': {'dx': value, 'dy': value},
            'rotation': value,
            'length': value,
          }),
          sortIndex: value,
          merge: FieldMerge(fields: fields),
        );
        final based = withFieldBase(initialRows(), edit('first', 1));
        expect(
          (based as ElementPatchOp).merge!.base!.toJson(),
          elementMergeBase(e1.payload, e1.sortIndex, fields),
        );
        final folded = fold(edit('first', 1), edit('then', 2));
        final op = (folded as FoldedOp).op as ElementPatchOp;
        final want = edit('then', 2);
        expect(
          elementMergeBase(op.payload!, op.sortIndex!, fields),
          elementMergeBase(want.payload!, want.sortIndex!, fields),
        );
      });
    }
  });

  group('sixth review, still possible', () {
    test('a header after a reconnect does not release a page delete on '
        'page content read before it', () {
      final client = online();
      client.edit(pageDelete('drop', 'page-a'));
      expect(client.view('drop').sendable, isTrue);
      client.must(const ConnectionLost());
      client.must(const ConnectionReturned());
      client.arrive(
        headerReadOf(withOp(initialRows(), movePatch('t', rotation: 90))),
      );
      expect(client.view('drop').holds, [
        awaitingResult(const PageResult('page-a')),
      ]);
      client.read(
        withOp(initialRows(), movePatch('t', rotation: 90)),
        pages: ['page-a'],
      );
      expect(
        stateOf(client, 'drop'),
        const NeedsUser(DeleteHeld(HeldDeleteCause.pageChanged)),
      );
    });

    test('a landed move stops being drawn once a result shows the row at a '
        'later revision, wherever a teammate moved it', () {
      final client = online();
      client.edit(
        ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
          payload: (initialRows().element('e1')! as LiveElement).payload,
          sortIndex: 0,
        ),
      );
      final attempt = client.claim(['move']);
      client.must(
        OpAnswered(attempt, const AppliedAnswer('move', revision: 2)),
      );
      expect(client.queue.landed, hasLength(1));
      final movedBack = withOp(
        withOp(initialRows(), client.lastSent().single),
        ElementPatchOp(
          opId: 'back',
          elementPublicId: 'e1',
          expectedElementRevision: 2,
          pagePublicId: 'page-a',
          payload: (initialRows().element('e1')! as LiveElement).payload,
          sortIndex: 0,
        ),
      );
      client.read(movedBack, pages: ['page-a']);
      expect(client.queue.landed, isEmpty);
      expect(client.visible.element('e1')!.pagePublicId, 'page-a');
    });
  });

  test('a revision-checked edit is sent naming the revision the answer '
      'ahead of it gave, not the one it was drawn at', () {
    final client = online();
    client.edit(pageAdd('add', 'page-c', expected: 1));
    client.edit(pageDelete('drop', 'page-b', expected: 1));
    final attempt = client.claim(['add']);
    client.must(OpAnswered(attempt, const AppliedAnswer('add', revision: 2)));
    client.claim(['drop']);
    expect(expectedOf(client.lastSent().single), 2);
  });

  group('seventh review', () {
    ElementReorderOp reorder(String opId, {required int expected}) =>
        ElementReorderOp(
          opId: opId,
          elementPublicId: 'e1',
          pagePublicId: 'page-a',
          sortIndex: 1,
          expectedElementRevision: expected,
        );

    Object? rotationOf(StrategyRows rows) =>
        (rows.element('e1')! as LiveElement).payload.data.toJson()['rotation'];

    test('a "nothing to do" at a teammate\'s revision does not lend that '
        'revision to the whole write behind it', () {
      final server = Server()
        ..rows = withOp(
          withOp(initialRows(), movePatch('t', rotation: 90)),
          reorder('t2', expected: 2),
        );
      final client = Client();
      client.edit(reorder('order', expected: 1));
      client.edit(movePatch('whole', x: 40, expected: 2));
      client.must(const ConnectionReturned());
      sendAndAnswer(client, server, ['order']);
      expect(client.view('whole').sendable, isFalse);
      client.read(server.rows, pages: ['page-a']);
      expect(stateOf(client, 'whole'), const NeedsUser(ChangedUnseen()));
      expect(rotationOf(server.rows), 90);
    });

    test('taking the cloud\'s version gives up the rest of that row\'s '
        'chain', () {
      final server = Server()
        ..rows = withOp(initialRows(), movePatch('t', rotation: 90));
      final client = Client();
      client.edit(movePatch('first', x: 40));
      client.edit(movePatch('second', x: 60, expected: 2));
      client.edit(movePatch('other', elementId: 'e2', x: 5));
      client.must(const ConnectionReturned());
      sendAndAnswer(client, server, ['first']);
      expect(stateOf(client, 'first'), isA<NeedsUser>());
      client.must(const UserUsedCloud('first'));
      expect(client.queue.entries.map((entry) => entry.id), ['other']);
      expect(
        client.effects,
        contains(
          const OpRemoved(
            'second',
            RemovedByUser(UserRemoval.usedCloud, Landing.notLanded),
          ),
        ),
      );
      expect(rotationOf(server.rows), 90);
    });

    test('a view never records an expiry; look records it and shows it from '
        'the queue it returns', () {
      final client = online();
      client.edit(elementAdd('add', elementId: 'e9'));
      final attempt = client.claim(['add']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.clock = now.add(const Duration(days: 31));
      expect(
        entryViews(client.queue, client.at)['add']!.state,
        isA<Unanswered>(),
      );
      final seen = look(client.queue, client.at);
      expect(seen.views['add']!.state, const NeedsUser(WindowClosed()));
      final rebuilt = CloudQueue(
        entries: seen.queue.entries,
        attempts: seen.queue.attempts,
        landed: seen.queue.landed,
        nextAttempt: seen.queue.nextAttempt,
        nextSession: seen.queue.nextSession,
        shown: seen.queue.shown,
        strategy: seen.queue.strategy,
        session: seen.queue.session,
      );
      client.queue = rebuilt;
      client.clock = now.add(const Duration(days: 28));
      expect(
        client.step(
          BatchClaimed(clientId: clientId, opIds: const ['add'], at: client.at),
        ),
        isA<NotApplicable>(),
      );
    });

    test('a batch refused whole does not start the resend window', () {
      final client = online();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(BatchRefused(attempt, BatchRefusal.upgradeRequired));
      client.must(const AppRestarted(build: 'build-2'));
      client.clock = now.add(const Duration(days: 31));
      client.queue = look(client.queue, client.at).queue;
      expect(stateOf(client, 'move'), const Waiting());
      expect(client.view('move').sendable, isTrue);
    });

    test('a sender gives an attempt up well inside the one-day margin', () {
      expect(
        sendGiveUpAfter,
        lessThan(serverRemembersAnswersFor - resendWindow),
      );
    });

    test('a delete does not wait behind a landed field merge, and a checked '
        'delete names the latest revision the device knows', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(elementDelete('drop', expected: 2));
      expect(client.view('drop').sendable, isTrue);
      client.must(const ConnectionLost());
      client.must(const ConnectionReturned());
      client.claim(['drop']);
      expect(expectedOf(client.lastSent().single), 2);
    });

    test('an undo after a teammate deleted first needs the user', () {
      final server = Server()..rows = withOp(initialRows(), elementDelete('t'));
      final client = online();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      sendAndAnswer(client, server, ['del']);
      client.edit(putBackOf('back', drawn, 'e1'));
      expect(stateOf(client, 'back'), const NeedsUser(ChangedUnseen()));
    });

    test('an undo after a delete answered with no revision needs the user', () {
      final client = online();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      final attempt = client.claim(['del']);
      client.must(OpAnswered(attempt, const NoopWithoutRevision('del')));
      client.edit(putBackOf('back', drawn, 'e1'));
      expect(stateOf(client, 'back'), const NeedsUser(ChangedUnseen()));
    });

    test('an undo of this device\'s applied delete goes at the tombstone '
        'revision even after a result showed the tombstone', () {
      final server = Server();
      final client = online();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      sendAndAnswer(client, server, ['del']);
      client.read(server.rows, pages: ['page-a']);
      client.edit(putBackOf('back', drawn, 'e1'));
      expect(client.view('back').sendable, isTrue);
      final attempt = client.claim(['back']);
      final sent = client.lastSent().single;
      expect(expectedOf(sent), 2);
      client.must(OpAnswered(attempt, server.apply(clientId, sent)));
      expect(server.rows.element('e1'), isA<LiveElement>());
    });

    test('a landed move is drawn off its source page', () {
      final server = Server();
      final client = online();
      final row = initialRows().element('e1')! as LiveElement;
      client.edit(
        ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
          payload: row.payload,
          sortIndex: 0,
        ),
      );
      sendAndAnswer(client, server, ['move']);
      final source = visibleOver(
        client.base,
        client.queue,
        SomePages(['page-a']),
      );
      expect(source.elementsOn('page-a').map((r) => r.publicId), ['e2']);
    });

    test('a whole write waiting on a row that a result of its page no longer '
        'holds needs the user', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(movePatch('drop', x: 70, expected: 2));
      expect(client.view('drop').sendable, isFalse);
      final row = server.rows.element('e1')! as LiveElement;
      server.rows = withOp(
        server.rows,
        ElementPatchOp(
          opId: 'away',
          elementPublicId: 'e1',
          expectedElementRevision: 2,
          pagePublicId: 'page-b',
          payload: row.payload,
          sortIndex: 1,
        ),
      );
      client.read(server.rows, pages: ['page-a']);
      expect(stateOf(client, 'drop'), const NeedsUser(ChangedUnseen()));
    });

    test('a page delete waiting for its page goes once the page is gone', () {
      final server = Server();
      final client = online();
      client.edit(elementAdd('add', elementId: 'n', pageId: 'page-b'));
      sendAndAnswer(client, server, ['add']);
      client.edit(pageDelete('drop', 'page-b'));
      expect(client.view('drop').holds, [
        awaitingResult(const PageResult('page-b')),
      ]);
      final gone = withOp(server.rows, pageDelete('t', 'page-b'));
      client.arrive(headerReadOf(gone));
      client.arrive(const PageGone('page-b'));
      expect(client.view('drop').sendable, isTrue);
    });
  });
}
