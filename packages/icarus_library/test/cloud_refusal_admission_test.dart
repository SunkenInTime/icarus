import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';

ResultPoint onEndedConnection() {
  final now = tick();
  return ResultPoint(
    client: now.client,
    connection: now.connection - 1,
    snapshot: now.snapshot,
    serverTime: now.serverTime,
  );
}

Client onSecondConnection() {
  final client = Client();
  client
    ..must(reconnected())
    ..must(reconnected())
    ..effects.clear();
  return client;
}

void main() {
  group('a refusal from an ended connection holds nothing', () {
    for (final refusal in SignInRefusal.values) {
      test('a read refused for the sign-in (${refusal.name})', () {
        final client = onSecondConnection();
        final before = client.queue;
        final step = client.step(
          ReadRefusedForSignIn(
            refusal,
            session: client.queue.session.number,
            point: onEndedConnection(),
          ),
        );
        expect(notApplicable(step), isA<ConnectionAlreadyEnded>());
        expect(client.queue, same(before));
        expect(client.effects, isEmpty);
      });
    }

    test('a read refused for an upgrade', () {
      final client = onSecondConnection();
      client.edit(movePatch('waiting'));
      final step = client.step(
        ReadRefusedForUpgrade(
          build: build,
          session: client.queue.session.number,
          point: onEndedConnection(),
        ),
      );
      expect(notApplicable(step), isA<ConnectionAlreadyEnded>());
      expect(standingOf(client.queue), Standing.good);
      expect(client.effects.whereType<HoldSendingForUpgrade>(), isEmpty);
    });

    test('a batch refused for another account closes its attempt as lost, '
        'and the op is sent again under the same id', () {
      final client = onSecondConnection();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      final ended = onEndedConnection();
      client.effects.clear();
      client.must(BatchAccountMismatch(attempt, point: ended));
      expect(
        client.queue.attempts[attempt]?.outcome,
        isA<AttemptFailed>().having(
          (failed) => failed.cause,
          'cause',
          const TransportCut(TransportFailure.answeredOnEndedConnection),
        ),
      );
      expect(client.effects, isNot(contains(isA<ReportAccountMismatch>())));
      expect(client.effects, isNot(contains(isA<AnswerAdmitted>())));
      client.clock = now.add(const Duration(seconds: 1));
      final again = client.claim(['move']);
      expect(again, isNot(attempt));
      expect([for (final op in client.lastSent()) op.opId], ['move']);
    });

    test('an answer from an ended connection is not admitted', () {
      final client = onSecondConnection();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.effects.clear();
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('move', revision: 2, life: fixtureLife),
          point: onEndedConnection(),
        ),
      );
      expect(client.effects.whereType<AnswerAdmitted>(), isEmpty);
    });
  });

  group('a refusal from the current connection is admitted', () {
    for (final (refusal, effect) in [
      (SignInRefusal.unauthenticated, isA<ReportUnauthenticated>()),
      (SignInRefusal.accountMismatch, isA<ReportAccountMismatch>()),
    ]) {
      test('a read refused for the sign-in (${refusal.name}) reports it', () {
        final client = onSecondConnection();
        client.must(
          ReadRefusedForSignIn(
            refusal,
            session: client.queue.session.number,
            point: tick(),
          ),
        );
        expect(client.effects, [effect]);
      });
    }

    test('a read refused for the sign-in under a session that has ended does '
        'not apply', () {
      final client = onSecondConnection();
      final ended = client.queue.session.number;
      client.must(const AccountChanged());
      final step = client.step(
        ReadRefusedForSignIn(
          SignInRefusal.unauthenticated,
          session: ended,
          point: tick(),
        ),
      );
      expect(
        notApplicable(step),
        isA<FromAnEndedSession>().having(
          (why) => why.session,
          'session',
          ended,
        ),
      );
      expect(client.effects.whereType<ReportUnauthenticated>(), isEmpty);
    });

    test('a read refused for an upgrade holds sending', () {
      final client = onSecondConnection();
      client.must(
        ReadRefusedForUpgrade(
          build: build,
          session: client.queue.session.number,
          point: tick(),
        ),
      );
      expect(standingOf(client.queue), Standing.upgradeRequired);
      expect(client.effects, contains(isA<HoldSendingForUpgrade>()));
    });

    test('a batch refused for another account gives the claim back, says the '
        'answer was admitted and reports another account', () {
      final client = onSecondConnection();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.effects.clear();
      client.must(BatchAccountMismatch(attempt, point: tick()));
      expect(client.queue.attempts[attempt]?.outcome, const AttemptReleased());
      expect(client.effects, [
        AnswerAdmitted(attempt),
        const ReportAccountMismatch(),
      ]);
    });

    test('an answer and a whole-batch refusal each say they were admitted', () {
      final client = onSecondConnection();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.effects.clear();
      client.must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'move',
            RejectionReason.mergeInvalid,
            NoServerCopy(),
          ),
          point: tick(),
        ),
      );
      expect(client.effects.whereType<AnswerAdmitted>(), [
        AnswerAdmitted(attempt, opId: 'move'),
      ]);
      client.edit(movePatch('second', elementId: 'e2'));
      final refused = client.claim(['second']);
      client.effects.clear();
      client.must(
        BatchRefused(refused, BatchRefusal.editAccessRemoved, point: tick()),
      );
      expect(client.effects.whereType<AnswerAdmitted>(), [
        AnswerAdmitted(refused),
      ]);
    });
  });
}
