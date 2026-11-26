import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:icarus_library/src/cloud/fold.dart';
import 'package:icarus_library/src/cloud/op_facts.dart'
    show CopyExpanded, CopyNotExpanded, expandCopy;
import 'package:icarus_library/src/cloud/visible.dart'
    show SomePages, pagesToLoad, visibleOver;
import 'package:icarus_library/src/field_merge.dart'
    show elementMergeBase, lineupMergeBase;
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';
import 'store_support.dart' show asStored;
import 'support.dart';

Client online({StrategyRowSet? base}) {
  final client = Client(base: base)..must(reconnected());
  client.read(base ?? initialRows());
  return client;
}

PendingState stateOf(Client client, String id) => client.view(id).state;

void sendAndAnswer(Client client, Server server, List<String> ids) {
  final attempt = client.claim(ids);
  for (final op in client.lastSent()) {
    client.must(OpAnswered(attempt, server.apply(clientId, op), point: tick()));
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
          point: tick(),
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
          OwnedBy(testAccount),
          Tally.of(client.queue, now),
          network: Network.online,
          signedIn: SignedInAs(testAccount),
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
      client.must(reconnected());
      expect(client.view('drop').sendable, isTrue);
    });

    test('two people deleting the same element: the server answers nothing '
        'to do and nobody is asked', () {
      final server = Server()
        ..rows = withOp(initialRows(), elementDelete('theirs'));
      final client = Client();
      client.edit(elementDelete('mine'));
      client.must(reconnected());
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
          point: tick(),
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
          point: tick(),
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
          point: tick(),
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
          point: tick(),
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
    test(
      'a retry waiting out its backoff goes at once when the clock moves '
      'back past its failure, instead of waiting for the clock to catch up',
      () {
        final client = online();
        client.edit(movePatch('move', x: 40));
        final attempt = client.claim(['move']);
        client.must(
          TransportFailed(attempt, TransportFailure.network, at: now),
        );
        expect(client.view('move').holds, [isA<UntilRetryTime>()]);
        client.clock = now.subtract(const Duration(days: 1));
        expect(client.view('move').holds, isEmpty);
        expect(client.view('move').sendable, isTrue);
        client.clock = now.add(const Duration(milliseconds: 100));
        expect(client.view('move').holds, [isA<UntilRetryTime>()]);
      },
    );

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
      expect(stateOf(client, 'move'), const NeedsUser(WrittenLongAgo()));
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
        OpAnswered(
          attempt,
          server.apply(clientId, client.lastSent().single),
          point: tick(),
        ),
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
      client.must(reconnected());
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
      client.must(reconnected());
      final attempt = client.claim(['mine']);
      server.apply(clientId, client.lastSent().single);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      server.rows = withOp(server.rows, movePatch('t', expected: 2));
      server.purgeAfterThirtyDays();
      client.clock = now.add(const Duration(days: 31));
      client.must(reconnected());
      expect(stateOf(client, 'mine'), const NeedsUser(WrittenLongAgo()));
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
      client.must(reconnected());
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

    test('a successor goes once its predecessor landed as predicted, and '
        'asks when someone wrote in between', () {
      for (final teammate in [false, true]) {
        final server = Server();
        if (teammate) {
          server.rows = withOp(initialRows(), movePatch('t', rotation: 90));
        }
        final client = online();
        client.edit(elementDelete('drop'));
        client.edit(putBackOf('back', initialRows(), 'e1'));
        sendAndAnswer(client, server, ['drop']);
        if (teammate) {
          expect(stateOf(client, 'back'), const NeedsUser(ChangedUnseen()));
          continue;
        }
        final attempt = client.claim(['back']);
        final sent = client.lastSent().single as ElementAddOp;
        expect(sent.expectedElementRevision, 2);
        client.must(
          OpAnswered(attempt, server.apply(clientId, sent), point: tick()),
        );
        expect(client.queue.entries, isEmpty);
        expect(server.rows.element('e1'), isA<LiveElement>());
      }
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
          point: tick(),
        ),
      );
      expect(client.view('back').sendable, isFalse);
    });

    test('answered applied by this device at the revision it predicted, it '
        'goes as an add over the tombstone with no read; at any other '
        'revision it needs the user', () {
      final client = deletedAndPutBack();
      final attempt = client.claim(['del']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('del', revision: 2, life: fixtureLife),
          point: tick(),
        ),
      );
      client.claim(['back']);
      expect(
        (client.lastSent().single as ElementAddOp).expectedElementRevision,
        2,
      );
      final other = deletedAndPutBack();
      final sent = other.claim(['del']);
      other.must(
        OpAnswered(
          sent,
          const AppliedAnswer('del', revision: 5, life: fixtureLife),
          point: tick(),
        ),
      );
      expect(stateOf(other, 'back'), const NeedsUser(ChangedUnseen()));
    });

    test('answered as nothing to do because someone else deleted it, it needs '
        'the user', () {
      final client = deletedAndPutBack();
      final attempt = client.claim(['del']);
      client.must(
        OpAnswered(
          attempt,
          const NoopAnswer(
            'del',
            revision: 2,
            replay: NoopReplay.notApplied,
            life: fixtureLife,
          ),
          point: tick(),
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
    test('a whole write behind a field merge that landed at the revision '
        'this device predicted goes at once; behind one that did not, it '
        'waits for the row\'s result', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(movePatch('drop', x: 70, expected: 2));
      expect(client.view('drop').sendable, isTrue);
      final other = online();
      other.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      final attempt = other.claim(['drag']);
      other.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('drag', revision: 3, life: fixtureLife),
          point: tick(),
        ),
      );
      other.edit(onVisible(other.visible, movePatch('drop', x: 70)));
      expect(other.view('drop').holds, [
        awaitingResult(const RowResult(ElementTarget('e1'), 'page-a')),
      ]);
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

    test('a page delete made without its page ever read needs the user once '
        'its page list and page come round', () {
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
      expect(client.view('blind').sendable, isFalse);
      client.arrive(headerReadOf(base));
      client.arrive(pageReadOf(base, 'page-b'));
      expect(
        stateOf(client, 'blind'),
        const NeedsUser(DeleteHeld(HeldDeleteCause.contentNeverRead)),
      );
    });
  });

  group('sessions', () {
    test('a result labelled with a session that a restart or an account '
        'change ended is not applicable, even stamped on the connection now '
        'open', () {
      for (final ending in [
        const AppRestarted(build: build),
        const AccountChanged(),
      ]) {
        final client = online();
        final old = client.queue.session.number;
        client.must(ending);
        client.must(reconnected());
        expect(
          notApplicable(
            client.step(
              BaseArrived(
                headerReadOf(initialRows()),
                session: old,
                point: tick(),
              ),
            ),
          ),
          isA<FromAnEndedSession>(),
          reason: '$ending',
        );
      }
    });

    test('a result labelled with the session before a reconnect is taken '
        'when stamped on the new connection, and not when stamped on the '
        'old one', () {
      final client = online();
      final old = client.queue.session.number;
      final onTheOldConnection = tick();
      client.must(const ConnectionLost());
      client.must(reconnected());
      expect(
        notApplicable(
          client.step(
            BaseArrived(
              headerReadOf(initialRows()),
              session: old,
              point: onTheOldConnection,
            ),
          ),
        ),
        isA<FromAnEndedSession>(),
      );
      client.must(
        BaseArrived(headerReadOf(initialRows()), session: old, point: tick()),
      );
      expect(client.queue.shown.list, const ReadThisSession());
    });
    test('an edit made while connected goes live the first time and checked '
        'after a reconnect', () {
      final client = online();
      client.edit(elementDelete('drop', elementId: 'e2'));
      client.must(const ConnectionLost());
      client.must(reconnected());
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
            OpAnswered(
              attempt,
              const AppliedAnswer('b', revision: 2, life: fixtureLife),
              point: tick(),
            ),
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

    test('a batch refused in a way the queue sends again climbs the lost-send '
        'ladder: it waits its backoff, shows as unsent, and needs the user at '
        'the bound; one refused before refusals had times does not count', () {
      final client = online()..clock = asStored(now);
      client.edit(movePatch('move'));
      final untimed = client.claim(['move']);
      client.must(
        BatchRefused(untimed, BatchRefusal.uncheckedTooLate, point: tick()),
      );
      expect(stateOf(client, 'move'), isA<Waiting>());
      for (var n = 1; n < retriesBeforePause; n++) {
        final attempt = client.claim(['move']);
        final at = asStored(now).add(Duration(minutes: n));
        client.must(
          BatchRefused(
            attempt,
            BatchRefusal.editAccessRemoved,
            at: at,
            point: tick(),
          ),
        );
        client.must(EditAccessConfirmed(afterAttempt: attempt));
        expect(
          stateOf(client, 'move'),
          isA<RefusedAgain>()
              .having((state) => state.refusals, 'refusals', n)
              .having(
                (state) => state.backoff,
                'backoff',
                RetryAfter(retryTimeAfter(at, n), failedAt: at),
              ),
        );
        expect(Tally.of(client.queue, at).waiting, {Underway.unsent: 1});
      }
      final last = client.claim(['move']);
      client.must(
        BatchRefused(
          last,
          BatchRefusal.uncheckedTooLate,
          at: asStored(now).add(const Duration(hours: 1)),
          point: tick(),
        ),
      );
      expect(stateOf(client, 'move'), const NeedsUser(RetriesExhausted()));
      final stored = attemptFromText(
        last,
        jsonEncode(attemptToJson(client.queue.attempts[last]!)),
      );
      expect(
        stored,
        isA<CloudRowRead<AttemptFact>>().having(
          (read) => read.value,
          'value',
          client.queue.attempts[last],
        ),
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
      client.must(
        BatchRefused(first, BatchRefusal.editAccessRemoved, point: tick()),
      );
      expect(standingOf(client.queue), Standing.good);
      client.must(
        BatchRefused(second, BatchRefusal.strategyDeleted, point: tick()),
      );
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
          BatchRefused(first, BatchRefusal.upgradeRequired, point: tick()),
          BatchRefused(second, BatchRefusal.upgradeRequired, point: tick()),
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

    test('a read refused for an upgrade shows the upgrade before any batch '
        'was sent, holds sending, keeps across a write, and a newer build '
        'clears it', () {
      final client = online();
      client.edit(movePatch('waiting'));
      final told = client.step(const ReadRefusedForUpgrade(build: build));
      expect(
        told,
        isA<Stepped>().having(
          (step) => step.effects,
          'effects',
          contains(isA<HoldSendingForUpgrade>()),
        ),
      );
      expect(standingOf(client.queue), Standing.upgradeRequired);
      expect(
        syncStateOf(
          OwnedBy(testAccount),
          Tally.of(client.queue, now),
          network: Network.online,
          signedIn: SignedInAs(testAccount),
        ),
        isA<Outstanding>().having(
          (state) => state.face,
          'face',
          Face.upgradeRequired,
        ),
      );
      final stored = factsFromText(
        jsonEncode(factsToJson(testAccount, client.queue.strategy)),
      );
      expect(
        stored,
        isA<CloudRowRead<CloudFacts>>().having(
          (read) => read.value.facts,
          'facts',
          client.queue.strategy,
        ),
      );
      client.must(const AppRestarted(build: 'build-newer'));
      expect(standingOf(client.queue), Standing.good);
    });

    test('while the run is held for an upgrade, that is the face, though an '
        'edit the server refused needs the user', () {
      final client = online();
      client.edit(movePatch('refused'));
      final attempt = client.claim(['refused']);
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'refused',
            RejectionReason.mergeInvalid,
            NoServerCopy(),
          ),
          point: tick(),
        ),
      );
      client.must(const ReadRefusedForUpgrade(build: build));
      expect(
        syncStateOf(
          OwnedBy(testAccount),
          Tally.of(client.queue, now),
          network: Network.online,
          signedIn: SignedInAs(testAccount),
        ),
        isA<Outstanding>().having(
          (state) => state.face,
          'face',
          Face.upgradeRequired,
        ),
      );
    });

    test('an empty queue on a deleted strategy is not plain all saved', () {
      final client = online();
      client.arrive(const StrategyGone());
      expect(
        syncStateOf(
          OwnedBy(testAccount),
          Tally.of(client.queue, now),
          network: Network.online,
          signedIn: SignedInAs(testAccount),
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
          point: tick(),
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
          point: tick(),
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
        OpAnswered(
          attempt,
          const AppliedAnswer('move', revision: 2, life: fixtureLife),
          point: tick(),
        ),
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
      client.must(
        BatchRefused(attempt, BatchRefusal.upgradeRequired, point: tick()),
      );
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
      client.must(
        BatchRefused(early, BatchRefusal.editAccessRemoved, point: tick()),
      );
      expect(standingOf(client.queue), Standing.editAccessLost);
      client.must(
        OpAnswered(
          late,
          const AppliedAnswer('second', revision: 2, life: fixtureLife),
          point: tick(),
        ),
      );
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
        final client = online();
        client.edit(
          movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
        );
        final attempt = client.claim(['drag']);
        client.must(
          OpAnswered(
            attempt,
            const AppliedAnswer('drag', revision: 3, life: fixtureLife),
            point: tick(),
          ),
        );
        client.edit(onVisible(client.visible, movePatch('drop', x: 70)));
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
      authoredAt: entry.authoredAt,
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
    expect(stateOf(client, 'del'), const NeedsUser(WrittenLongAgo()));
    expect(stateOf(client, 'back'), const NeedsUser(WrittenLongAgo()));
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
      client.must(reconnected());
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
      client.must(reconnected());
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
        OpAnswered(
          attempt,
          const AppliedAnswer('move', revision: 2, life: fixtureLife),
          point: tick(),
        ),
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

  test('a revision-checked edit names the revision it was drawn at, which '
      'counts the answer this device expects for the work ahead of it', () {
    final client = online();
    client.edit(pageAdd('add', 'page-c', expected: 1));
    client.edit(onVisible(client.visible, pageDelete('drop', 'page-b')));
    final attempt = client.claim(['add']);
    client.must(
      OpAnswered(
        attempt,
        const AppliedAnswer('add', revision: 2, life: fixtureLife),
        point: tick(),
      ),
    );
    client.read(withOp(initialRows(), pageAdd('add', 'page-c', expected: 1)));
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
      client.must(reconnected());
      sendAndAnswer(client, server, ['order']);
      expect(client.view('whole').sendable, isFalse);
      client.read(server.rows, pages: ['page-a']);
      expect(stateOf(client, 'whole'), isA<NeedsUser>());
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
      client.must(reconnected());
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
      client.edit(elementAdd('move'));
      final attempt = client.claim(['move']);
      client.must(
        BatchRefused(attempt, BatchRefusal.upgradeRequired, point: tick()),
      );
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

    test('a delete does not wait behind a landed field merge, and after a '
        'reconnect a checked delete names the latest revision the device '
        'knows once a result of the new session shows the row', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(elementDelete('drop', expected: 2));
      expect(client.view('drop').sendable, isTrue);
      client.must(const ConnectionLost());
      client.must(reconnected());
      expect(client.view('drop').sendable, isFalse);
      client.read(server.rows);
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

    test('an undo waiting for its row asks the user once its delete\'s resend '
        'window has closed, though nothing happened in between', () {
      final server = Server();
      final client = online();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      sendAndAnswer(client, server, ['del']);
      client
        ..must(const ConnectionLost())
        ..must(reconnected())
        ..edit(putBackOf('back', drawn, 'e1'));
      expect(client.view('back').holds, [isA<AwaitingResult>()]);
      final later = client.at.add(resendWindow + const Duration(minutes: 1));
      final queue = client.queue;
      final afresh = CloudQueue(
        entries: queue.entries,
        attempts: queue.attempts,
        landed: queue.landed,
        nextAttempt: queue.nextAttempt,
        nextSession: queue.nextSession,
        shown: queue.shown,
        strategy: queue.strategy,
        session: queue.session,
      );
      expect(
        entryViews(queue, later)['back']!.state,
        const NeedsUser(ChangedUnseen()),
      );
      expect(entryViews(afresh, later), entryViews(queue, later));
    });

    test('an undo after a delete answered with no revision needs the user', () {
      final client = online();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      final attempt = client.claim(['del']);
      client.must(
        OpAnswered(attempt, const NoopWithoutRevision('del'), point: tick()),
      );
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
      client.must(
        OpAnswered(attempt, server.apply(clientId, sent), point: tick()),
      );
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

    test(
      'an edit whose row was moved to another page is derived again when '
      'that page\'s read changes, so its view matches one derived afresh',
      () {
        final server = Server();
        final client = online();
        client.edit(
          movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
        );
        sendAndAnswer(client, server, ['drag']);
        client.edit(onVisible(client.visible, movePatch('drop', x: 70)));
        final row = server.rows.element('e1')! as LiveElement;
        server.rows = withOp(
          server.rows,
          ElementPatchOp(
            opId: 'away',
            elementPublicId: 'e1',
            expectedElementRevision: revisionOfRowForTest(row)!,
            pagePublicId: 'page-b',
            payload: agentPayload('e1', {'rotation': 45}),
            sortIndex: 1,
          ),
        );
        client.read(server.rows);
        final before = client.view('drop').state;
        client.must(const ResultRefused(page: 'page-b', problem: 'unreadable'));
        final queue = client.queue;
        final afresh = CloudQueue(
          entries: queue.entries,
          attempts: queue.attempts,
          landed: queue.landed,
          nextAttempt: queue.nextAttempt,
          nextSession: queue.nextSession,
          shown: queue.shown,
          strategy: queue.strategy,
          session: queue.session,
        );
        expect(entryViews(afresh, now)['drop']!.state, isNot(before));
        expect(entryViews(queue, now), entryViews(afresh, now));
      },
    );

    test('a whole write waiting on a row that a result of its page no longer '
        'holds needs the user', () {
      final server = Server()
        ..rows = withOp(initialRows(), movePatch('t', rotation: 90));
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(onVisible(client.visible, movePatch('drop', x: 70)));
      expect(client.view('drop').sendable, isFalse);
      final row = server.rows.element('e1')! as LiveElement;
      server.rows = withOp(
        server.rows,
        ElementPatchOp(
          opId: 'away',
          elementPublicId: 'e1',
          expectedElementRevision: 3,
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
      final attempt = client.claim(['add']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('add', revision: 2, life: fixtureLife),
          point: tick(),
        ),
      );
      client.edit(pageDelete('drop', 'page-b'));
      expect(client.view('drop').holds, [
        awaitingResult(const PageListResult()),
        awaitingResult(const PageResult('page-b')),
      ]);
      final gone = withOp(server.rows, pageDelete('t', 'page-b'));
      client.arrive(headerReadOf(gone));
      client.arrive(const PageGone('page-b'));
      expect(client.view('drop').sendable, isTrue);
    });
  });

  group('the revision an op names', () {
    final e1 = initialRows().element('e1')! as LiveElement;

    StrategyRowSet movedAndRotated() => withOp(
      initialRows(),
      ElementPatchOp(
        opId: 't',
        elementPublicId: 'e1',
        expectedElementRevision: 1,
        pagePublicId: 'page-b',
        payload: agentPayload('e1', {
          ...e1.payload.data.toJson(),
          'rotation': 90,
        }),
        sortIndex: 0,
      ),
    );

    test('an offline drag never moves a teammate\'s element back over a '
        'revision it did not see', () {
      final server = Server()..rows = movedAndRotated();
      final client = Client();
      client.edit(
        ElementPatchOp(
          opId: 'drag',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-a',
          payload: agentPayload('e1', {
            ...e1.payload.data.toJson(),
            'position': {'dx': 40, 'dy': 0},
          }),
          sortIndex: e1.sortIndex,
          merge: FieldMerge(fields: ['position']),
        ),
      );
      client.must(reconnected());
      client.read(server.rows);
      sendAndAnswer(client, server, ['drag']);
      expect(stateOf(client, 'drag'), isA<NeedsUser>());
      expect(server.rows.element('e1')!.pagePublicId, 'page-b');
    });

    test('an offline rename never takes a teammate\'s rename revision', () {
      final server = Server()
        ..rows = withOp(
          initialRows(),
          const StrategyPatchOp(
            opId: 't',
            expectedStrategyRevision: 1,
            name: 'Theirs',
          ),
        );
      final client = Client();
      client.edit(
        const StrategyPatchOp(
          opId: 'rename',
          expectedStrategyRevision: 1,
          name: 'Mine',
        ),
      );
      client.must(reconnected());
      client.read(server.rows);
      sendAndAnswer(client, server, ['rename']);
      expect(stateOf(client, 'rename'), isA<NeedsUser>());
      expect(server.rows.strategy.name, 'Theirs');
    });

    test('an offline checked delete never takes a teammate\'s move', () {
      final server = Server()..rows = movedAndRotated();
      final client = Client();
      client.edit(elementDelete('drop'));
      client.must(reconnected());
      client.read(server.rows);
      sendAndAnswer(client, server, ['drop']);
      expect(stateOf(client, 'drop'), isA<NeedsUser>());
      expect(server.rows.element('e1'), isA<LiveElement>());
    });

    test('a whole edit behind this device\'s own add and drag needs the user '
        'when a later result of the page no longer holds the row', () {
      final server = Server();
      final client = online();
      client.edit(elementAdd('add', elementId: 'e9'));
      sendAndAnswer(client, server, ['add']);
      client.edit(
        movePatch(
          'drag',
          elementId: 'e9',
          x: 40,
          merge: FieldMerge(fields: ['position']),
        ),
      );
      server.rows = withOp(
        server.rows,
        movePatch('t', elementId: 'e9', expected: 1, rotation: 90),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(
        onVisible(client.visible, movePatch('whole', elementId: 'e9', x: 70)),
      );
      final row = server.rows.element('e9')! as LiveElement;
      server.rows = withOp(
        server.rows,
        ElementPatchOp(
          opId: 'away',
          elementPublicId: 'e9',
          expectedElementRevision: 3,
          pagePublicId: 'page-b',
          payload: row.payload,
          sortIndex: 1,
        ),
      );
      client.read(server.rows, pages: ['page-a']);
      expect(stateOf(client, 'whole'), const NeedsUser(ChangedUnseen()));
    });

    test('keep mine on an undo conflict goes', () {
      final server = Server()..rows = withOp(initialRows(), elementDelete('t'));
      final client = online();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      sendAndAnswer(client, server, ['del']);
      client.edit(putBackOf('back', drawn, 'e1'));
      expect(stateOf(client, 'back'), const NeedsUser(ChangedUnseen()));
      final tombstone = server.rows.element('e1')! as DeletedElement;
      client.must(
        UserKeptMine(
          'back',
          rebasedForTest(putBackOf('mine', drawn, 'e1'), tombstone.revision),
          authored: const AuthoredNoRow(),
        ),
      );
      expect(client.view('mine').sendable, isTrue);
    });

    test('a put-back over a delete answered more than 29 days ago needs the '
        'user', () {
      final client = online();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      client.edit(putBackOf('back', drawn, 'e1'));
      final attempt = client.claim(['del']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('del', revision: 2, life: fixtureLife),
          point: tick(),
        ),
      );
      expect(client.view('back').sendable, isTrue);
      client.clock = now.add(const Duration(days: 30));
      expect(stateOf(client, 'back'), const NeedsUser(ChangedUnseen()));
    });

    test('a whole-batch refusal after the attempt was given up still means '
        'the server never tried it', () {
      final client = online();
      client.edit(elementAdd('move'));
      final attempt = client.claim(['move']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.must(
        BatchRefused(attempt, BatchRefusal.upgradeRequired, point: tick()),
      );
      client.must(const AppRestarted(build: 'build-2'));
      client.clock = now.add(const Duration(days: 31));
      client.queue = look(client.queue, client.at).queue;
      expect(stateOf(client, 'move'), const Waiting());
    });

    test('a page-gone result alone does not release a waiting page delete; '
        'with a page list after it, the delete goes', () {
      final server = Server();
      final client = online();
      client.edit(elementAdd('add', elementId: 'n', pageId: 'page-b'));
      sendAndAnswer(client, server, ['add']);
      client.edit(pageDelete('drop', 'page-b'));
      client.must(const ConnectionLost());
      client.must(reconnected());
      client.arrive(const PageGone('page-b'));
      expect(client.view('drop').sendable, isFalse);
      client.arrive(
        headerReadOf(withOp(server.rows, pageDelete('t', 'page-b'))),
      );
      expect(client.view('drop').sendable, isTrue);
    });

    test('two people renaming a page to the same name settles without a '
        'question', () {
      final server = Server()
        ..rows = withOp(
          initialRows(),
          const PagePatchOp(
            opId: 't',
            pagePublicId: 'page-a',
            expectedPageRevision: 1,
            name: 'Same',
          ),
        );
      final client = Client();
      client.edit(
        const PagePatchOp(
          opId: 'rename',
          pagePublicId: 'page-a',
          expectedPageRevision: 1,
          name: 'Same',
        ),
      );
      client.must(reconnected());
      client.read(server.rows);
      expect(client.view('rename').sendable, isTrue);
      sendAndAnswer(client, server, ['rename']);
      expect(client.queue.entries, isEmpty);
    });

    test('a landed move asks for the page its row comes from', () {
      final server = Server();
      final client = online();
      client.edit(
        ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
          payload: e1.payload,
          sortIndex: 0,
        ),
      );
      sendAndAnswer(client, server, ['move']);
      expect(
        pagesToLoad(client.queue, SomePages(['page-b'])),
        contains('page-a'),
      );
    });
  });

  group('justified rows', () {
    final e1 = initialRows().element('e1')! as LiveElement;

    StrategyOp rotated(String opId, int expected) =>
        movePatch(opId, expected: expected, rotation: 90);

    Object? rotationOf(StrategyRows rows) =>
        (rows.element('e1')! as LiveElement).payload.data.toJson()['rotation'];

    void settle(Client client, Server server) {
      for (var round = 0; round < 6; round++) {
        final ids = [
          for (final entry in client.queue.entries)
            if (client.view(entry.id).sendable) entry.id,
        ];
        if (ids.isNotEmpty) sendAndAnswer(client, server, ids);
        client.read(server.rows);
      }
    }

    test('a whole edit behind a drag that landed over a teammate\'s rotation '
        'never erases it', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      final attempt = client.claim(['drag']);
      server.rows = withOp(server.rows, rotated('t', 1));
      client.must(
        OpAnswered(
          attempt,
          server.apply(clientId, client.lastSent().single),
          point: tick(),
        ),
      );
      client.edit(
        onVisible(
          client.visible,
          ElementReorderOp(
            opId: 'order',
            elementPublicId: 'e1',
            pagePublicId: 'page-a',
            sortIndex: 1,
            expectedElementRevision: 1,
          ),
        ),
      );
      client.edit(onVisible(client.visible, movePatch('whole', x: 70)));
      settle(client, server);
      expect(rotationOf(server.rows), 90);
    });

    test('a whole edit behind this device\'s own drag goes at once when '
        'nobody else wrote', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(onVisible(client.visible, movePatch('whole', x: 70)));
      expect(client.view('whole').sendable, isTrue);
    });

    test('a page rename behind this device\'s reorder asks when another '
        'device moved the page back first', () {
      final server = Server();
      final client = online();
      client.edit(
        const PageReorderOp(
          opId: 'order',
          pagePublicId: 'page-a',
          sortIndex: 1,
          expectedStrategyRevision: 1,
        ),
      );
      sendAndAnswer(client, server, ['order']);
      server.rows = withOp(
        server.rows,
        const PageReorderOp(
          opId: 'back',
          pagePublicId: 'page-a',
          sortIndex: 0,
          expectedStrategyRevision: 2,
        ),
      );
      client.edit(
        onVisible(
          client.visible,
          const PagePatchOp(
            opId: 'rename',
            pagePublicId: 'page-a',
            expectedPageRevision: 1,
            name: 'Mine',
          ),
        ),
      );
      client.read(server.rows);
      expect(stateOf(client, 'rename'), isA<NeedsUser>());
    });

    test('a page rename behind this device\'s reorder settles when another '
        'device chose the same name', () {
      final server = Server();
      final client = online();
      client.edit(
        const PageReorderOp(
          opId: 'order',
          pagePublicId: 'page-a',
          sortIndex: 1,
          expectedStrategyRevision: 1,
        ),
      );
      sendAndAnswer(client, server, ['order']);
      final page = server.rows.page('page-a')! as LivePage;
      server.rows = withOp(
        server.rows,
        PagePatchOp(
          opId: 'same',
          pagePublicId: 'page-a',
          expectedPageRevision: page.revision,
          name: 'Same',
        ),
      );
      client.edit(
        onVisible(
          client.visible,
          const PagePatchOp(
            opId: 'rename',
            pagePublicId: 'page-a',
            expectedPageRevision: 1,
            name: 'Same',
          ),
        ),
      );
      client.read(server.rows);
      settle(client, server);
      expect(client.queue.entries, isEmpty);
    });

    test('undo of this device\'s delete that landed over a teammate\'s '
        'rotation needs the user', () {
      final server = Server();
      final client = online();
      client.edit(elementDelete('del'));
      final attempt = client.claim(['del']);
      server.rows = withOp(server.rows, rotated('t', 1));
      client.must(
        OpAnswered(
          attempt,
          server.apply(clientId, client.lastSent().single),
          point: tick(),
        ),
      );
      final drawn = client.visible;
      final tombstone = drawn.element('e1')! as DeletedElement;
      client.edit(
        ElementAddOp(
          opId: 'back',
          elementPublicId: 'e1',
          pagePublicId: 'page-a',
          payload: e1.payload,
          sortIndex: e1.sortIndex,
          expectedElementRevision: tombstone.revision,
        ),
      );
      expect(stateOf(client, 'back'), const NeedsUser(ChangedUnseen()));
    });

    test('an undo window runs from the delete\'s first send, not from a '
        'replay', () {
      final client = online();
      final drawn = client.visible;
      client.edit(elementDelete('del'));
      final first = client.claim(['del']);
      client.must(TransportFailed(first, TransportFailure.network, at: now));
      client.clock = now.add(const Duration(days: 28));
      final again = client.claim(['del']);
      client.must(
        OpAnswered(
          again,
          const NoopAnswer(
            'del',
            revision: 2,
            replay: NoopReplay.appliedWhenFirstReceived,
            life: fixtureLife,
          ),
          point: tick(),
        ),
      );
      client.edit(putBackOf('back', drawn, 'e1'));
      client.clock = now.add(const Duration(days: 30));
      expect(stateOf(client, 'back'), isA<NeedsUser>());
    });

    test('a landed move stays on its destination when the source page\'s '
        'result comes first', () {
      final server = Server();
      final client = online();
      client.edit(
        ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
          payload: e1.payload,
          sortIndex: 0,
        ),
      );
      sendAndAnswer(client, server, ['move']);
      client.arrive(pageReadOf(server.rows, 'page-a'));
      final base = StrategyRowSet(
        strategy: initialRows().strategy,
        pages: initialRows().pages,
        settings: initialRows().settings,
        elements: [
          for (final row in initialRows().elements)
            if (row.publicId != 'e1') row,
        ],
      );
      final drawn = visibleOver(base, client.queue, SomePages(['page-b']));
      expect(drawn.element('e1')?.pagePublicId, 'page-b');
    });

    test('an edit waiting for a row\'s result needs the user when its page is '
        'gone', () {
      final server = Server();
      final client = online();
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      final attempt = client.claim(['drag']);
      server.rows = withOp(server.rows, rotated('t', 1));
      client.must(
        OpAnswered(
          attempt,
          server.apply(clientId, client.lastSent().single),
          point: tick(),
        ),
      );
      client.edit(onVisible(client.visible, movePatch('whole', x: 70)));
      expect(client.view('whole').sendable, isFalse);
      client.arrive(const PageGone('page-a'));
      expect(stateOf(client, 'whole'), const NeedsUser(RowPageGone()));
    });

    test('a rename of a new page needs the user when a page list leaves the '
        'page out', () {
      final server = Server();
      final client = online();
      client.edit(pageAdd('add', 'page-c', expected: 1, sortIndex: 2));
      sendAndAnswer(client, server, ['add']);
      client.edit(
        onVisible(
          client.visible,
          const PagePatchOp(
            opId: 'rename',
            pagePublicId: 'page-c',
            expectedPageRevision: 1,
            name: 'Mine',
          ),
        ),
      );
      server.rows = withOp(
        server.rows,
        pageDelete('t', 'page-c', expected: server.rows.strategy.revision),
      );
      client.arrive(headerReadOf(server.rows));
      expect(stateOf(client, 'rename'), const NeedsUser(RowPageGone()));
    });

    test('moving an element off a page and deleting the page asks nothing', () {
      final server = Server();
      final client = online();
      client.edit(
        ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
          payload: e1.payload,
          sortIndex: 0,
        ),
      );
      client.edit(
        pageDelete(
          'drop',
          'page-a',
          expected: client.visible.strategy.revision,
        ),
      );
      sendAndAnswer(client, server, ['move']);
      expect(stateOf(client, 'drop'), isNot(isA<NeedsUser>()));
    });
  });

  group('fourth review', () {
    Object? rotationOf(StrategyRows rows) =>
        (rows.element('e1')! as LiveElement).payload.data.toJson()['rotation'];

    void settle(Client client, Server server) {
      for (var round = 0; round < 6; round++) {
        final ids = [
          for (final entry in client.queue.entries)
            if (client.view(entry.id).sendable) entry.id,
        ];
        if (ids.isNotEmpty) sendAndAnswer(client, server, ids);
        client.read(server.rows);
      }
    }

    test('an answer of nothing to do over a teammate\'s write justifies '
        'nothing, so a later whole edit never erases their rotation', () {
      final server = Server();
      final client = online();
      server.rows = withOp(server.rows, movePatch('t', x: 40, rotation: 90));
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(
        onVisible(
          client.visible,
          movePatch('again', x: 60, merge: FieldMerge(fields: ['position'])),
        ),
      );
      if (client.view('again').sendable) {
        sendAndAnswer(client, server, ['again']);
      }
      client.edit(onVisible(client.visible, movePatch('whole', x: 80)));
      settle(client, server);
      expect(rotationOf(server.rows), 90);
    });

    test('a revision-checked edit written more than 29 days ago needs the '
        'user before it is ever sent', () {
      final client = Client()..read(initialRows());
      client.edit(movePatch('old', x: 80));
      client.clock = now.add(resendWindow);
      client.must(reconnected());
      expect(client.view('old').sendable, isFalse);
      expect(stateOf(client, 'old'), const NeedsUser(WrittenLongAgo()));
    });

    test('solo: renaming a page and then deleting it asks nothing, once the '
        'page list and page come round after the answer', () {
      final server = Server();
      final client = online();
      client.edit(
        const PagePatchOp(
          opId: 'rename',
          pagePublicId: 'page-b',
          expectedPageRevision: 1,
          name: 'Mine',
        ),
      );
      client.edit(pageDelete('del', 'page-b'));
      sendAndAnswer(client, server, ['rename']);
      expect(client.view('del').sendable, isFalse);
      client.read(server.rows);
      expect(client.view('del').sendable, isTrue);
    });

    test('solo: changing a page\'s settings and then deleting it goes once '
        'the settings are answered and the page list and page come round', () {
      final server = Server();
      final client = online();
      client.edit(
        const PageSettingsPatchOp(
          opId: 'settings',
          pagePublicId: 'page-b',
          settings: PageSettings(
            agentSize: 2,
            abilitySize: 1,
            useNeutralTeamColors: true,
          ),
          expectedPageSettingsRevision: 1,
        ),
      );
      client.edit(pageDelete('del', 'page-b'));
      sendAndAnswer(client, server, ['settings']);
      expect(client.view('del').sendable, isFalse);
      client.read(server.rows);
      expect(client.view('del').sendable, isTrue);
    });

    test('a page a page list shows live again no longer reads as gone', () {
      final server = Server();
      final client = online();
      client.edit(
        const PageReorderOp(
          opId: 'order',
          pagePublicId: 'page-a',
          sortIndex: 1,
          expectedStrategyRevision: 1,
        ),
      );
      sendAndAnswer(client, server, ['order']);
      client.edit(
        onVisible(
          client.visible,
          const PagePatchOp(
            opId: 'rename',
            pagePublicId: 'page-a',
            expectedPageRevision: 1,
            name: 'Mine',
          ),
        ),
      );
      client.arrive(const PageGone('page-a'));
      client.arrive(headerReadOf(server.rows));
      expect(stateOf(client, 'rename'), isNot(const NeedsUser(RowPageGone())));
    });

    StrategyRowSet withoutE1(StrategyRowSet rows) => StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: [
        for (final row in rows.elements)
          if (row.publicId != 'e1') row,
      ],
      lineupGroups: rows.lineupGroups,
    );

    for (final (label, answered) in [
      ('answered', true),
      ('unanswered', false),
    ]) {
      test('a move without a payload stays drawn on its destination when the '
          'source page\'s result arrives first, $label', () {
        final server = Server();
        final client = online();
        const move = ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
        );
        client.edit(move);
        final attempt = client.claim(['move']);
        final answer = server.apply(clientId, client.lastSent().single);
        if (answered) client.must(OpAnswered(attempt, answer, point: tick()));
        client.base = withoutE1(client.base);
        client.arrive(pageReadOf(server.rows, 'page-a'));
        final drawn = client.visible.element('e1');
        expect(drawn?.pagePublicId, 'page-b');
        expect(
          (drawn! as LiveElement).sortIndex,
          (server.rows.element('e1')! as LiveElement).sortIndex,
        );
      });
    }

    test('a queued move whose source page\'s result arrives first is drawn '
        'at the revision after the move', () {
      final server = Server();
      final client = online();
      const move = ElementPatchOp(
        opId: 'move',
        elementPublicId: 'e1',
        expectedElementRevision: 1,
        pagePublicId: 'page-b',
      );
      client.edit(move);
      client.claim(['move']);
      server.apply(clientId, client.lastSent().single);
      client.base = withoutE1(client.base);
      client.arrive(pageReadOf(server.rows, 'page-a'));
      expect(
        (client.visible.element('e1')! as LiveElement).revision,
        (server.rows.element('e1')! as LiveElement).revision,
      );
    });

    test('a page whose result showed it, deleted after a teammate added to '
        'it, is held rather than taken as already gone', () {
      final server = Server();
      final client = online();
      client.edit(pageAdd('add', 'page-c'));
      sendAndAnswer(client, server, ['add']);
      client.arrive(pageReadOf(server.rows, 'page-c'));
      client.edit(
        onVisible(client.visible, pageDelete('del', 'page-c', expected: 2)),
      );
      server.rows = withOp(
        server.rows,
        elementAdd('t', elementId: 'theirs', pageId: 'page-c'),
      );
      client.arrive(pageReadOf(server.rows, 'page-c'));
      expect(client.view('del').sendable, isFalse);
    });
  });

  group('fifth review', () {
    Object? rotationOf(StrategyRows rows) =>
        (rows.element('e1')! as LiveElement).payload.data.toJson()['rotation'];

    void settle(Client client, Server server) {
      for (var round = 0; round < 6; round++) {
        final ids = [
          for (final entry in client.queue.entries)
            if (client.view(entry.id).sendable) entry.id,
        ];
        if (ids.isNotEmpty) sendAndAnswer(client, server, ids);
        client.read(server.rows);
      }
    }

    StrategyRowSet withoutE1(StrategyRowSet rows) => StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: [
        for (final row in rows.elements)
          if (row.publicId != 'e1') row,
      ],
      lineupGroups: rows.lineupGroups,
    );

    test('a row cached from an earlier session justifies nothing, so a put '
        'back under the same id at revision 1 is never overwritten', () {
      final server = Server();
      final client = online();
      server.rows = withOp(server.rows, movePatch('t', rotation: 90));
      final rotated = server.rows.element('e1')! as LiveElement;
      server.rows = withOp(server.rows, elementDelete('gone', expected: 2));
      server.rows = withOp(
        withoutE1(server.rows),
        ElementAddOp(
          opId: 'back',
          elementPublicId: 'e1',
          pagePublicId: 'page-a',
          payload: rotated.payload,
          sortIndex: rotated.sortIndex,
        ),
      );
      client.must(const AppRestarted(build: build));
      client.must(reconnected());
      client.edit(
        movePatch('move', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['move']);
      client.edit(onVisible(client.visible, movePatch('whole', x: 80)));
      settle(client, server);
      expect(rotationOf(server.rows), 90);
    });

    test('the strategy row is compared by content, so a teammate\'s theme is '
        'never overwritten behind a rename both chose', () {
      final server = Server();
      final client = online();
      server.rows = withOp(
        server.rows,
        const StrategyPatchOp(
          opId: 'theme',
          expectedStrategyRevision: 1,
          themeProfile: SetValue('night'),
        ),
      );
      server.rows = withOp(
        server.rows,
        const StrategyPatchOp(
          opId: 'name',
          expectedStrategyRevision: 2,
          name: 'Same',
        ),
      );
      client.edit(
        const StrategyPatchOp(
          opId: 'mine',
          expectedStrategyRevision: 1,
          name: 'Same',
        ),
      );
      sendAndAnswer(client, server, ['mine']);
      client.edit(
        onVisible(
          client.visible,
          const StrategyPatchOp(
            opId: 'my-theme',
            expectedStrategyRevision: 1,
            themeProfile: SetValue('day'),
          ),
        ),
      );
      settle(client, server);
      expect(server.rows.strategy.themeProfileId, 'night');
    });

    test('nothing to do at the justified revision keeps the predictions '
        'queued behind it', () {
      final start = strategyRows(
        elements: [
          element(
            'e1',
            fields: const {
              'position': {'dx': 0, 'dy': 0},
            },
          ),
          element('e2'),
          element('e3', pageId: 'page-b'),
        ],
      );
      final server = Server()..rows = start;
      final client = online(base: start);
      client.edit(
        movePatch('d1', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      client.edit(
        onVisible(
          client.visible,
          movePatch('d2', x: 0, merge: FieldMerge(fields: ['position'])),
        ),
      );
      final folded = client.queue.entries.single.id;
      final attempt = client.claim([folded]);
      client.edit(onVisible(client.visible, movePatch('w1', x: 70)));
      client.edit(onVisible(client.visible, movePatch('w2', x: 90)));
      client.must(
        OpAnswered(
          attempt,
          server.apply(clientId, client.lastSent().single),
          point: tick(),
        ),
      );
      sendAndAnswer(client, server, ['w1']);
      expect(client.view('w2').sendable, isTrue);
    });

    test('a live field edit after nothing to do goes at once', () {
      final server = Server();
      final client = online();
      server.rows = withOp(server.rows, movePatch('t', x: 40, rotation: 90));
      client.edit(
        movePatch('drag', x: 40, merge: FieldMerge(fields: ['position'])),
      );
      sendAndAnswer(client, server, ['drag']);
      client.edit(
        onVisible(
          client.visible,
          movePatch('again', x: 60, merge: FieldMerge(fields: ['position'])),
        ),
      );
      expect(client.view('again').sendable, isTrue);
    });

    for (final (label, move) in [
      (
        'changing only the page',
        const ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
        ),
      ),
      (
        'with a merged position',
        ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
          payload: agentPayload('e1', const {
            'position': {'dx': 5, 'dy': 0},
          }),
          merge: FieldMerge(fields: ['position']),
        ),
      ),
    ]) {
      test('a pending move $label shows a teammate\'s newer change on the '
          'destination before its answer', () {
        final server = Server();
        final client = online();
        client.edit(onVisible(client.visible, move));
        client.claim(['move']);
        server.apply(clientId, client.lastSent().single);
        server.rows = withOp(
          server.rows,
          movePatch('t', expected: 2, rotation: 90),
        );
        client.read(server.rows);
        expect(rotationOf(client.visible), 90);
        expect(client.visible.element('e1')!.pagePublicId, 'page-b');
      });
    }

    final orders = [
      ['source', 'destination', 'answer'],
      ['source', 'answer', 'destination'],
      ['destination', 'source', 'answer'],
      ['destination', 'answer', 'source'],
      ['answer', 'source', 'destination'],
      ['answer', 'destination', 'source'],
    ];
    for (final order in orders) {
      test('a move keeps its own place in the order: ${order.join(', ')}', () {
        final start = strategyRows(
          elements: [
            element('e1', sortIndex: 7),
            element('e2'),
            element('e3', pageId: 'page-b'),
          ],
        );
        final server = Server()..rows = start;
        final client = online(base: start);
        const move = ElementPatchOp(
          opId: 'move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
        );
        client.edit(move);
        final attempt = client.claim(['move']);
        final answer = server.apply(clientId, client.lastSent().single);
        final moved = server.rows.element('e1')! as LiveElement;
        for (final step in order) {
          switch (step) {
            case 'source':
              if (client.base.element('e1')?.pagePublicId == 'page-a') {
                client.base = withoutE1(client.base);
              }
              client.arrive(pageReadOf(server.rows, 'page-a'));
            case 'destination':
              client.base = withoutE1(client.base).withRows([moved]);
              client.arrive(pageReadOf(server.rows, 'page-b'));
            case _:
              client.must(OpAnswered(attempt, answer, point: tick()));
          }
          final drawn = [
            for (final row in client.visible.elements)
              if (row is LiveElement && row.publicId == 'e1') row,
          ];
          expect(drawn, hasLength(1), reason: 'after $step');
          expect(drawn.single.pagePublicId, 'page-b', reason: 'after $step');
          expect(
            drawn.single.sortIndex,
            moved.sortIndex,
            reason: 'after $step',
          );
        }
      });
    }
  });

  group('the page-delete hold', () {
    void bothResults(
      Client client,
      Server server,
      String page,
      bool listFirst,
    ) {
      if (listFirst) client.arrive(headerReadOf(server.rows));
      client.arrive(pageReadOf(server.rows, page));
      if (!listFirst) client.arrive(headerReadOf(server.rows));
    }

    test('a delete with nothing ahead of it on a page read this session goes '
        'at once', () {
      final client = online();
      client.edit(pageDelete('del', 'page-b'));
      expect(client.view('del').sendable, isTrue);
    });

    for (final listFirst in [true, false]) {
      final order = listFirst ? 'page list first' : 'page result first';

      test('a delete queued offline asks after a teammate changed the page\'s '
          'settings ($order)', () {
        final server = Server();
        final client = Client()..read(initialRows());
        client.edit(pageDelete('del', 'page-b'));
        server.rows = withOp(
          server.rows,
          const PageSettingsPatchOp(
            opId: 't',
            pagePublicId: 'page-b',
            settings: PageSettings(
              agentSize: 2,
              abilitySize: 1,
              useNeutralTeamColors: true,
            ),
            expectedPageSettingsRevision: 1,
          ),
        );
        client.must(reconnected());
        if (listFirst) {
          client.arrive(headerReadOf(server.rows));
        } else {
          client.arrive(pageReadOf(server.rows, 'page-b'));
        }
        expect(client.view('del').sendable, isFalse);
        bothResults(client, server, 'page-b', listFirst);
        expect(stateOf(client, 'del'), isA<NeedsUser>());
      });

      test('a delete asks once fresh results show a row it saw moved to '
          'another page ($order)', () {
        final server = Server();
        final client = online();
        client.edit(elementAdd('add', elementId: 'n', pageId: 'page-a'));
        sendAndAnswer(client, server, ['add']);
        client.edit(onVisible(client.visible, pageDelete('del', 'page-a')));
        client.must(const ConnectionLost());
        client.must(reconnected());
        final placed = server.rows.element('n')! as LiveElement;
        server.rows = withOp(
          server.rows,
          ElementPatchOp(
            opId: 't',
            elementPublicId: 'n',
            expectedElementRevision: placed.revision,
            pagePublicId: 'page-b',
          ),
        );
        bothResults(client, server, 'page-a', listFirst);
        expect(stateOf(client, 'del'), isA<NeedsUser>());
      });

      test('a page list from before this device added the page never counts '
          'as proof it is gone ($order)', () {
        final server = Server();
        final client = online();
        client.edit(pageAdd('add', 'page-c'));
        sendAndAnswer(client, server, ['add']);
        server.rows = withOp(
          server.rows,
          elementAdd('t', elementId: 'theirs', pageId: 'page-c'),
        );
        client.edit(
          onVisible(client.visible, pageDelete('del', 'page-c', expected: 2)),
        );
        expect(client.view('del').sendable, isFalse);
        bothResults(client, server, 'page-c', listFirst);
        if (!listFirst) {
          expect(
            client.view('del').holds,
            contains(awaitingResult(const PageResult('page-c'))),
          );
          client.arrive(pageReadOf(server.rows, 'page-c'));
        }
        expect(stateOf(client, 'del'), isA<NeedsUser>());
      });
    }
  });

  test('a drag to the same place folded with a real drag predicts the op '
      'that is sent, so the next whole edit goes at once', () {
    final start = strategyRows(
      elements: [
        element(
          'e1',
          fields: const {
            'position': {'dx': 0, 'dy': 0},
          },
        ),
        element('e2'),
        element('e3', pageId: 'page-b'),
      ],
    );
    final server = Server()..rows = start;
    final client = online(base: start);
    client.edit(movePatch('d1', x: 0, merge: FieldMerge(fields: ['position'])));
    client.edit(
      onVisible(
        client.visible,
        movePatch('d2', x: 40, merge: FieldMerge(fields: ['position'])),
      ),
    );
    final folded = client.queue.entries.single.id;
    sendAndAnswer(client, server, [folded]);
    client.edit(onVisible(client.visible, movePatch('whole', x: 70)));
    expect(client.view('whole').sendable, isTrue);
  });

  test('an undo whose page a teammate deleted asks, with that reason', () {
    final server = Server();
    final client = online();
    final drawn = client.visible;
    client.edit(elementDelete('del'));
    client.edit(putBackOf('back', drawn, 'e1'));
    client.must(const ConnectionLost());
    client.must(reconnected());
    sendAndAnswer(client, server, ['del']);
    server.rows = withoutPage(
      withOp(server.rows, pageDelete('t', 'page-a', expected: 1)),
      'page-a',
    );
    client.read(server.rows);
    expect(stateOf(client, 'back'), const NeedsUser(RowPageGone()));
  });

  group('what makes held results stale', () {
    test('a move\'s answer resets its source page even when the '
        'destination\'s result arrived first', () {
      final server = Server();
      final client = online();
      const move = ElementPatchOp(
        opId: 'move',
        elementPublicId: 'e1',
        expectedElementRevision: 1,
        pagePublicId: 'page-b',
      );
      client.edit(move);
      client.edit(onVisible(client.visible, pageDelete('del', 'page-a')));
      final attempt = client.claim(['move']);
      final answer = server.apply(clientId, client.lastSent().single);
      server.rows = withOp(
        server.rows,
        elementAdd('t', elementId: 'theirs', pageId: 'page-a'),
      );
      client.arrive(pageReadOf(server.rows, 'page-b'));
      client.must(OpAnswered(attempt, answer, point: tick()));
      expect(client.view('del').sendable, isFalse);
      client.read(server.rows);
      expect(stateOf(client, 'del'), isA<NeedsUser>());
    });

    test('an answer of nothing to do without a revision resets the page', () {
      final client = online();
      client.edit(elementDelete('gone'));
      client.edit(pageDelete('del', 'page-a'));
      final attempt = client.claim(['gone']);
      client.read(initialRows());
      client.must(
        OpAnswered(attempt, const NoopWithoutRevision('gone'), point: tick()),
      );
      expect(client.view('del').sendable, isFalse);
      expect(resultsNeeded(client.queue, client.at), {
        const PageListResult(),
        const PageResult('page-a'),
      });
    });

    test('an answer for another page\'s settings throws away the views that '
        'counted the page list as fresh', () {
      final server = Server();
      final client = online();
      client.edit(pageDelete('del', 'page-a'));
      expect(client.view('del').sendable, isTrue);
      client.edit(
        const PageSettingsPatchOp(
          opId: 'settings',
          pagePublicId: 'page-b',
          settings: PageSettings(
            agentSize: 2,
            abilitySize: 1,
            useNeutralTeamColors: true,
          ),
          expectedPageSettingsRevision: 1,
        ),
      );
      sendAndAnswer(client, server, ['settings']);
      expect(client.view('del').sendable, isFalse);
      expect(
        resultsNeeded(client.queue, client.at),
        contains(const PageListResult()),
      );
    });

    for (final listFirst in [true, false]) {
      test('a page list and a page result that disagree about whether the '
          'page exists are no verdict (${listFirst ? 'list' : 'page'} '
          'first)', () {
        final client = Client()..read(initialRows());
        client.must(reconnected());
        client.edit(pageDelete('del', 'page-b'));
        final gone = withOp(initialRows(), pageDelete('t', 'page-b'));
        if (listFirst) {
          client.arrive(headerReadOf(initialRows()));
          client.arrive(const PageGone('page-b'));
        } else {
          client.arrive(const PageGone('page-b'));
          client.arrive(headerReadOf(initialRows()));
        }
        expect(gone.page('page-b'), isA<TrashedPage>());
        expect(stateOf(client, 'del'), isNot(isA<NeedsUser>()));
        expect(client.view('del').sendable, isFalse);
        expect(resultsNeeded(client.queue, client.at), {
          const PageListResult(),
          const PageResult('page-b'),
        });
      });
    }

    test('a page delete whose page a fresh page list says is gone goes, even '
        'behind this device\'s own reorder', () {
      final server = Server();
      final client = online();
      client.edit(
        const PageReorderOp(
          opId: 'order',
          pagePublicId: 'page-a',
          sortIndex: 1,
          expectedStrategyRevision: 1,
        ),
      );
      client.edit(
        onVisible(client.visible, pageDelete('del', 'page-b', expected: 2)),
      );
      sendAndAnswer(client, server, ['order']);
      server.rows = withOp(
        server.rows,
        pageDelete('t', 'page-b', expected: server.rows.strategy.revision),
      );
      client.arrive(headerReadOf(server.rows));
      expect(client.view('del').sendable, isTrue);
    });
  });
}
