import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus_library/icarus_library.dart';

const strategy = 'strategy-1';
final account = Account('account-a');

const before = (account: null, connection: 1, signIns: 1, signOuts: 0);

SenderReport reconnected(int session) => SessionOpenedFor(
      strategy,
      session,
      (account: account, connection: 2, signIns: 1, signOuts: 0),
    );

SenderReport lost() => EventsWritten(strategy, const [ConnectionLost()]);

SenderReport openedByReconnect(int session) => EventsWritten(
      strategy,
      const [ConnectionReturned(Generation(client: 1, connection: 2))],
      effects: [SessionOpened(session)],
    );

SenderReport reconnectInOpenSession() => EventsWritten(
      strategy,
      const [ConnectionReturned(Generation(client: 1, connection: 2))],
    );

SenderReport openedByStamp(int session) => EventsWritten(
      strategy,
      const [
        OpAnswered(
          1,
          AppliedAnswer('op-1', revision: 3, life: 1),
          point: ResultPoint(client: 1, connection: 2, snapshot: 9),
        ),
      ],
      effects: [SessionOpened(session)],
    );

SenderReport earlierSession() => const SessionOpenedFor(strategy, 1, before);

String judged(List<SenderReport> reports, {bool stampExpected = true}) =>
    reconnectSessionOpening(reports, strategy, stampExpected: stampExpected);

Matcher refusedWith(String words) => throwsA(
    isA<StateError>().having((e) => e.message, 'message', contains(words)));

void main() {
  test('a stamp that opened the session the reconnect bound passes', () {
    expect(
      judged([
        earlierSession(),
        lost(),
        openedByStamp(2),
        reconnectInOpenSession(),
        reconnected(2),
      ]),
      contains('session 2 by a result\'s stamp, the one session opened'),
    );
  });

  test(
      'a stamp that opened a session before the cut does not stand in for '
      'the reconnect opening the one that matters', () {
    expect(
      () => judged([
        openedByStamp(1),
        earlierSession(),
        lost(),
        openedByReconnect(2),
        reconnected(2),
      ]),
      refusedWith('session 2 by the reconnect event, not by a result\'s stamp'),
    );
  });

  test('the reconnect event is logged when no stamp is expected', () {
    expect(
      judged(
        [earlierSession(), lost(), openedByReconnect(2), reconnected(2)],
        stampExpected: false,
      ),
      contains('session 2 by the reconnect event'),
    );
  });

  test('a stamp and then a second session for the reconnect fail', () {
    expect(
      () => judged([
        earlierSession(),
        lost(),
        openedByStamp(2),
        openedByReconnect(3),
        reconnected(3),
      ]),
      refusedWith(
        'opened session 2 by a result\'s stamp, session 3 by the reconnect '
        'event, not that session alone',
      ),
    );
  });

  test('an opening reported by an event the queue did not apply counts', () {
    expect(
      () => judged([
        earlierSession(),
        lost(),
        EventsWritten(
          strategy,
          const [
            ServerTimeHeld(
              1,
              at: Duration.zero,
              session: 1,
              point: ResultPoint(client: 1, connection: 1, snapshot: 1),
            ),
          ],
          effects: const [SessionOpened(2)],
        ),
        openedByReconnect(3),
        reconnected(3),
      ]),
      refusedWith('not that session alone'),
    );
  });

  test('a reconnect that bound a session the store never opened fails', () {
    expect(
      () => judged([earlierSession(), lost(), reconnected(1)]),
      refusedWith('the store opened no session'),
    );
  });

  test('a run whose sender stayed on one connection, or moved twice, fails',
      () {
    expect(
      () => judged([earlierSession(), openedByStamp(2)]),
      refusedWith('on 1 connections'),
    );
    expect(
      () => judged([
        earlierSession(),
        openedByReconnect(2),
        reconnected(2),
        openedByReconnect(3),
        SessionOpenedFor(
          strategy,
          3,
          (account: account, connection: 3, signIns: 1, signOuts: 0),
        ),
      ]),
      refusedWith('on 3 connections'),
    );
  });

  test('a cut the store never saw as a loss is still told apart', () {
    expect(
      judged(
        [earlierSession(), openedByReconnect(2), reconnected(2)],
        stampExpected: false,
      ),
      contains('session 2 by the reconnect event'),
    );
  });
}
