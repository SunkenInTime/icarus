import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus_library/icarus_library.dart';

const strategy = 'strategy-1';
final account = Account('account-a');

const onFirst = ResultPoint(client: 1, connection: 1, snapshot: 4);
const onSecond = ResultPoint(client: 1, connection: 2, snapshot: 9);

ClaimedBatch batch(int attempt, List<String> opIds) => ClaimedBatch(
      strategyId: strategy,
      account: account,
      attempt: attempt,
      clientId: 'client-1',
      ops: [
        for (final opId in opIds)
          StrategyPatchOp(
            opId: opId,
            expectedStrategyRevision: 1,
            name: 'Renamed',
          ),
      ],
      session: 1,
      strategyLife: 1,
    );

SenderReport sent(int attempt, List<String> opIds) =>
    BatchSentAs(strategy, batch(attempt, opIds));

SenderReport timedOut(int attempt, List<String> opIds) => EventsWritten(
      strategy,
      [TransportFailed(attempt, TransportFailure.timeout, at: DateTime(2026))],
      batch: batch(attempt, opIds),
    );

SenderReport answeredOnEndedConnection(int attempt, String opId) =>
    EventsWritten(
      strategy,
      [
        const ConnectionReturned(Generation(client: 1, connection: 2)),
        OpAnswered(
          attempt,
          AppliedAnswer(opId, revision: 2, life: 1),
          point: onFirst,
        ),
      ],
      batch: batch(attempt, [opId]),
    );

SenderReport answered(int attempt, OpAnswer answer, {bool admitted = true}) =>
    EventsWritten(
      strategy,
      [OpAnswered(attempt, answer, point: onSecond)],
      batch: batch(attempt, [answer.opId]),
      effects: [if (admitted) AnswerAdmitted(attempt, opId: answer.opId)],
    );

OpAnswer appliedBefore(String opId) => NoopAnswer(
      opId,
      revision: 2,
      replay: NoopReplay.appliedWhenFirstReceived,
      life: 1,
    );

SenderReport boundOn(int connection, int session) => SessionOpenedFor(
      strategy,
      session,
      (account: account, connection: connection, signIns: 1, signOuts: 0),
    );

String judged(List<SenderReport> reports) => lostAnswerResent(
      [boundOn(1, 1), ...reports, boundOn(2, 2)],
      strategy,
    );

Matcher refusedWith(String words) => throwsA(
    isA<StateError>().having((e) => e.message, 'message', contains(words)));

void main() {
  test(
      'a lost answer and its resend from before the cut did not reach the '
      'case', () {
    expect(
      () => lostAnswerResent([
        boundOn(1, 1),
        sent(1, ['op-1']),
        timedOut(1, ['op-1']),
        sent(2, ['op-1']),
        answered(2, appliedBefore('op-1')),
        boundOn(1, 2),
        boundOn(2, 3),
      ], strategy),
      refusedWith('did not reach the case'),
    );
  });

  test(
      'a lost answer, a resend under the same op id and the server '
      'answering it as already applied pass', () {
    expect(
      judged([
        sent(1, ['op-1']),
        timedOut(1, ['op-1']),
        sent(2, ['op-1']),
        answered(2, appliedBefore('op-1')),
      ]),
      allOf(
        contains('attempt 1 was closed as lost (no answer came (timeout))'),
        contains('op-1 was sent again in attempt 2'),
        contains('applied when first received'),
      ),
    );
  });

  test('an answer the queue closed as from an ended connection is lost', () {
    expect(
      judged([
        sent(1, ['op-1']),
        answeredOnEndedConnection(1, 'op-1'),
        sent(2, ['op-1']),
        answered(2, appliedBefore('op-1')),
      ]),
      contains('its answer came on connection 1, which had ended'),
    );
  });

  test(
      'a run whose first answer simply applied did not reach the case, '
      'whatever came after', () {
    expect(
      () => judged([
        sent(1, ['op-1']),
        answered(1, const AppliedAnswer('op-1', revision: 2, life: 1)),
      ]),
      refusedWith('did not reach the case: none of the 1 batches sent'),
    );
  });

  test('a lost answer whose ops were never sent again fails', () {
    expect(
      () => judged([
        sent(1, ['op-1']),
        timedOut(1, ['op-1']),
      ]),
      throwsA(
        isA<StateError>()
            .having(
              (e) => e.message,
              'message',
              contains('none of its ops was sent again'),
            )
            .having(
              (e) => e.message,
              'message',
              isNot(contains('did not reach the case')),
            ),
      ),
    );
  });

  test(
      'a resend the server applied for the first time did not reach the '
      'case: the server never received the lost send', () {
    expect(
      () => judged([
        sent(1, ['op-1']),
        timedOut(1, ['op-1']),
        sent(2, ['op-1']),
        answered(2, const AppliedAnswer('op-1', revision: 2, life: 1)),
      ]),
      refusedWith('did not reach the case: attempt 1 was closed as lost'),
    );
  });

  test('a resend answered on a connection the queue did not admit fails', () {
    expect(
      () => judged([
        sent(1, ['op-1']),
        timedOut(1, ['op-1']),
        sent(2, ['op-1']),
        answered(2, appliedBefore('op-1'), admitted: false),
      ]),
      refusedWith('and no answer to it was admitted'),
    );
  });

  test('a resend of another op id does not stand in for the lost op', () {
    expect(
      () => judged([
        sent(1, ['op-1']),
        timedOut(1, ['op-1']),
        sent(2, ['op-2']),
        answered(2, appliedBefore('op-2')),
      ]),
      refusedWith('none of its ops was sent again'),
    );
  });

  test('reports of another strategy are not counted', () {
    expect(
      () => judged([
        BatchSentAs('strategy-2', batch(1, ['op-1'])),
        EventsWritten(
          'strategy-2',
          [
            TransportFailed(
              1,
              TransportFailure.timeout,
              at: DateTime(2026),
            ),
          ],
        ),
      ]),
      refusedWith('did not reach the case: none of the 0 batches'),
    );
  });
}
