import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'store_support.dart' show asStored;

const heldAt = Duration(seconds: 100);

enum Session { thisOne, disconnected, another }

enum Basis { none, fresh, atTheLimit, stale, noReading }

bool expectLive({
  required bool attempted,
  required Session session,
  required Basis basis,
}) =>
    !attempted &&
    session == Session.thisOne &&
    (basis == Basis.fresh || basis == Basis.atTheLimit);

Client quietClient() => Client()
  ..holdsServerTime = false
  ..must(const ConnectionReturned());

void hold(Client client, int serverTime, Duration at, {int? session}) =>
    client.must(
      ServerTimeHeld(
        serverTime,
        at: at,
        session: session ?? client.queue.session.number,
      ),
    );

SendBatch claimAt(Client client, List<String> ids, Duration? elapsed) {
  client.must(
    BatchClaimed(
      clientId: clientId,
      opIds: ids,
      at: client.at,
      elapsed: elapsed == null ? null : () => elapsed,
    ),
  );
  return client.effects.whereType<SendBatch>().last;
}

void main() {
  group('the form of a send, row by row', () {
    for (final attempted in [false, true]) {
      for (final session in Session.values) {
        for (final basis in Basis.values) {
          final live = expectLive(
            attempted: attempted,
            session: session,
            basis: basis,
          );
          test('attempted $attempted, session ${session.name}, basis '
              '${basis.name}: ${live ? 'live' : 'checked'}', () {
            final client = quietClient();
            client.read(initialRows());
            if (basis != Basis.none) hold(client, 1000, heldAt);
            client.edit(elementDelete('drop', elementId: 'e2'));
            if (attempted) {
              final attempt = claimAt(client, ['drop'], heldAt).attempt;
              client.must(
                TransportFailed(
                  attempt,
                  TransportFailure.network,
                  at: client.at,
                ),
              );
              client.clock = client.at.add(const Duration(minutes: 10));
            }
            switch (session) {
              case Session.thisOne:
                break;
              case Session.disconnected:
                client.must(const ConnectionLost());
              case Session.another:
                client
                  ..must(const ConnectionLost())
                  ..must(const ConnectionReturned());
            }
            final elapsed = switch (basis) {
              Basis.none || Basis.fresh => heldAt + const Duration(seconds: 5),
              Basis.atTheLimit => heldAt + liveFor,
              Basis.stale => heldAt + liveFor + const Duration(milliseconds: 1),
              Basis.noReading => null,
            };
            final sent = claimAt(client, ['drop'], elapsed);
            expect((sent.ops.single as ElementDeleteOp).lastWriterWins, live);
            expect(sent.basis, live ? 1000 : null);
            expect(
              sendPolicy(
                attempted: attempted,
                connected: session != Session.disconnected,
                writtenThisSession: session != Session.another,
                basis: basis == Basis.none
                    ? null
                    : const ServerTimeBasis(1000, heldAt: heldAt),
                elapsed: elapsed,
              ),
              live ? SendPolicy.live : SendPolicy.checked,
            );
          });
        }
      }
    }
  });

  test('an op with no live form goes the same way and brings no basis', () {
    final client = quietClient();
    client.read(initialRows());
    hold(client, 1000, heldAt);
    client.edit(elementAdd('add'));
    final sent = claimAt(client, ['add'], heldAt);
    expect(sent.ops.single, elementAdd('add'));
    expect(sent.basis, isNull);
  });

  test('a batch carries the oldest basis among its live ops, and a checked op '
      'in it adds none', () {
    final client = quietClient();
    client.read(initialRows());
    hold(client, 1000, heldAt);
    client.edit(elementDelete('first'));
    hold(client, 4000, heldAt + const Duration(seconds: 3));
    client.edit(elementDelete('second', elementId: 'e2'));
    client.edit(elementAdd('add'));
    final sent = claimAt(client, [
      'first',
      'second',
      'add',
    ], heldAt + const Duration(seconds: 10));
    expect(
      [
        for (final op in sent.ops)
          if (op is ElementDeleteOp) op.lastWriterWins,
      ],
      [true, true],
    );
    expect(sent.basis, 1000);
  });

  test('a batch refused for lateness waits again at once and goes checked, '
      'under the same op ids, with no basis', () {
    final client = quietClient();
    client.read(initialRows());
    hold(client, 1000, heldAt);
    client.edit(elementDelete('drop', elementId: 'e2'));
    final first = claimAt(client, ['drop'], heldAt);
    expect((first.ops.single as ElementDeleteOp).lastWriterWins, isTrue);
    client.must(BatchRefused(first.attempt, BatchRefusal.uncheckedTooLate));
    expect(client.view('drop').state, const Waiting());
    expect(client.view('drop').sendable, isTrue);
    final again = claimAt(client, ['drop'], heldAt);
    expect(again.ops.single.opId, 'drop');
    expect((again.ops.single as ElementDeleteOp).lastWriterWins, isFalse);
    expect(again.basis, isNull);
  });

  test(
    'a late refusal drops the basis of every op written on one no newer than '
    'the refused batch\'s, so an edit made while the refused one was in '
    'flight goes checked: one refusal, not two',
    () {
      final client = quietClient();
      client.read(initialRows());
      hold(client, 1000, heldAt);
      client.edit(
        movePatch('a', x: 20, merge: FieldMerge(fields: const ['position'])),
      );
      final first = claimAt(client, ['a'], heldAt);
      expect(isUncheckedSend(first.ops.single), isTrue);
      client.edit(
        movePatch(
          'b',
          rotation: 45,
          merge: FieldMerge(fields: const ['rotation']),
        ),
      );
      expect(
        (client.queue.entries.last as PendingOp).basis,
        const ServerTimeBasis(1000, heldAt: heldAt),
      );
      client.must(BatchRefused(first.attempt, BatchRefusal.uncheckedTooLate));
      expect((client.queue.entries.last as PendingOp).basis, isNull);
      final again = claimAt(client, ['a'], heldAt);
      expect(isUncheckedSend(again.ops.single), isFalse);
      client.must(
        OpAnswered(
          again.attempt,
          const AppliedAnswer('a', revision: 2, life: fixtureLife),
        ),
      );
      final second = claimAt(client, ['b'], heldAt);
      expect(isUncheckedSend(second.ops.single), isFalse);
      expect(second.basis, isNull);
    },
  );

  test('the reading a claim judges its basis by is the one it takes when it '
      'runs, not one handed to it earlier', () {
    final client = quietClient();
    client.read(initialRows());
    hold(client, 1000, heldAt);
    client.edit(elementDelete('drop', elementId: 'e2'));
    var reading = heldAt;
    final claim = BatchClaimed(
      clientId: clientId,
      opIds: const ['drop'],
      at: client.at,
      elapsed: () => reading,
    );
    reading = heldAt + liveFor + const Duration(seconds: 1);
    client.must(claim);
    final sent = client.effects.whereType<SendBatch>().last;
    expect((sent.ops.single as ElementDeleteOp).lastWriterWins, isFalse);
  });

  test('the queue holds a server time only while connected, keeps the newest, '
      'and every new session starts with none', () {
    final client = Client()..holdsServerTime = false;
    hold(client, 1000, heldAt);
    expect(client.queue.session.basis, isNull);
    client.must(const ConnectionReturned());
    hold(client, 2000, heldAt);
    hold(client, 1500, heldAt + const Duration(seconds: 1));
    expect(
      client.queue.session.basis,
      const ServerTimeBasis(2000, heldAt: heldAt),
    );
    client.must(const ConnectionLost());
    expect(client.queue.session.basis, isNull);
    client.must(const ConnectionReturned());
    hold(client, 3000, heldAt);
    client.must(const AccountChanged());
    expect(client.queue.session.basis, isNull);
    hold(client, 3000, heldAt);
    client.must(const AppRestarted(build: build));
    expect(client.queue.session.basis, isNull);
  });

  test('a server time from a session that has ended is not held, so an edit '
      'after an account change goes checked', () {
    final client = quietClient();
    client.read(initialRows());
    final asked = client.queue.session.number;
    client.must(const AccountChanged());
    hold(client, 1000, heldAt, session: asked);
    expect(client.queue.session.basis, isNull);
    client.edit(elementDelete('drop', elementId: 'e2'));
    final sent = claimAt(client, ['drop'], heldAt);
    expect((sent.ops.single as ElementDeleteOp).lastWriterWins, isFalse);
    expect(sent.basis, isNull);
  });

  test('an edit to the same fields after a late refusal does not fold into the '
      'refused op, which goes checked; the edit has no basis, since the '
      'refusal drops the server time the queue held', () {
    final client = quietClient();
    client.read(initialRows());
    hold(client, 1000, heldAt);
    client.edit(
      movePatch('a', x: 20, merge: FieldMerge(fields: const ['position'])),
    );
    final first = claimAt(client, ['a'], heldAt);
    expect(isUncheckedSend(first.ops.single), isTrue);
    client.must(BatchRefused(first.attempt, BatchRefusal.uncheckedTooLate));
    client.edit(
      movePatch('b', x: 30, merge: FieldMerge(fields: const ['position'])),
    );
    expect([for (final entry in client.queue.entries) entry.id], ['a', 'b']);
    expect(client.queue.session.basis, isNull);
    expect((client.queue.entries.last as PendingOp).basis, isNull);
    final again = claimAt(client, ['a'], heldAt);
    expect(isUncheckedSend(again.ops.single), isFalse);
    expect(again.basis, isNull);
  });

  test('an op keeps the basis it was written with; a fold keeps the older '
      'one', () {
    final client = quietClient();
    client.read(initialRows());
    hold(client, 1000, heldAt);
    client.edit(
      movePatch('a', x: 20, merge: FieldMerge(fields: const ['position'])),
    );
    hold(client, 5000, heldAt + const Duration(seconds: 2));
    client.edit(
      movePatch('b', x: 30, merge: FieldMerge(fields: const ['position'])),
    );
    final entry = client.queue.entries.single as PendingOp;
    expect(entry.basis, const ServerTimeBasis(1000, heldAt: heldAt));
  });

  test('a stored op without a basis reads as one with no basis', () {
    final client = quietClient()..clock = asStored(now);
    client.read(initialRows());
    hold(client, 1000, heldAt);
    client.edit(elementDelete('drop', elementId: 'e2'));
    final entry = client.queue.entries.single as PendingOp;
    final json = entryToJson(entry);
    expect(json['basis'], {
      'serverTime': 1000,
      'heldAtMicros': heldAt.inMicroseconds,
    });
    switch (decodeEntry(entry.place, json, sendable: true)) {
      case Read(:final value):
        expect(value, entry);
      case final other:
        fail('$other');
    }
    final older = {...json}..remove('basis');
    switch (decodeEntry(entry.place, older, sendable: true)) {
      case Read(value: final PendingOp read):
        expect(read.basis, isNull);
      case final other:
        fail('$other');
    }
  });
}
