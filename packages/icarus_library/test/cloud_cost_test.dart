import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/queue.dart' show derivationWork;
import 'package:test/test.dart';

import 'cloud_support.dart';

QueueEvent added(String opId, String elementId, String pageId) =>
    UserEdited(switch (editOf(
      elementAdd(opId, elementId: elementId, pageId: pageId),
      authored: const AuthoredNoRow(),
    )) {
      EditMade(:final edit) => edit,
      _ => throw StateError('an element add is always an edit'),
    });

Client queueOf(int length) {
  final client = Client()..must(const ConnectionReturned());
  for (var i = 0; i < length; i++) {
    client.must(added('add$i', 'n$i', i.isEven ? 'page-a' : 'page-b'));
  }
  final accepted = client.claim([for (var i = 0; i < length; i += 4) 'add$i']);
  for (var i = 0; i < length; i += 4) {
    client.must(OpAnswered(accepted, AppliedAnswer('add$i', revision: 1)));
  }
  final lost = client.claim([for (var i = 1; i < length; i += 4) 'add$i']);
  client.must(TransportFailed(lost, TransportFailure.network, at: now));
  entryViews(client.queue, now);
  return client;
}

final class Measured {
  Measured(this.event, this.took, this.views, this.visits);

  final String event;
  final Duration took;
  final int views;
  final int visits;
}

List<Measured> oneEntryEvents(Client client, {int rounds = 30}) {
  final results = <Measured>[];
  void measure(String event, QueueEvent made) {
    derivationWork.reset();
    final watch = Stopwatch()..start();
    final queue = stepped(transition(client.queue, made, now: now)).queue;
    entryViews(queue, now);
    Tally.of(queue, now);
    watch.stop();
    client.queue = queue;
    results.add(
      Measured(
        event,
        watch.elapsed,
        derivationWork.views,
        derivationWork.visits,
      ),
    );
  }

  for (var round = 0; round < rounds; round++) {
    final id = 'more$round';
    measure('edit', added(id, 'm$id', 'page-a'));
    measure('claim', BatchClaimed(clientId: clientId, opIds: [id], at: now));
    final attempt = client.queue.nextAttempt - 1;
    if (round.isEven) {
      measure('answer', OpAnswered(attempt, AppliedAnswer(id, revision: 1)));
    } else {
      measure(
        'transport failure',
        TransportFailed(attempt, TransportFailure.network, at: now),
      );
    }
  }
  return results;
}

const events = ['edit', 'claim', 'answer', 'transport failure'];

void main() {
  test('the work of an event touching one entry does not grow with the '
      'queue, the views and tally the app asks for afterwards included', () {
    final work = <int, Map<String, (int, int)>>{};
    for (final length in [100, 1000, 3000]) {
      final results = oneEntryEvents(queueOf(length));
      work[length] = {
        for (final event in events)
          event: results
              .where((r) => r.event == event)
              .map((r) => (r.views, r.visits))
              .reduce(
                (a, b) =>
                    (a.$1 > b.$1 ? a.$1 : b.$1, a.$2 > b.$2 ? a.$2 : b.$2),
              ),
      };
    }
    if (Platform.environment['CLOUD_COST'] == '1') stdout.writeln(work);
    for (final event in events) {
      expect(work[1000]![event], work[100]![event], reason: event);
      expect(work[3000]![event], work[100]![event], reason: event);
    }
  });

  test('an event touching one entry of a 1,000-entry queue takes under '
      '2 ms with the views and tally', () {
    final results = oneEntryEvents(queueOf(1000), rounds: 200);
    final lines = <String>[];
    for (final event in events) {
      final times = [
        for (final r in results)
          if (r.event == event) r.took.inMicroseconds,
      ]..sort();
      final median = times[times.length ~/ 2];
      final slow = times[(times.length * 0.95).floor()];
      lines.add('$event: median $median µs, 95th percentile $slow µs');
      if (Platform.environment['CLOUD_COST_TIMES'] == '1') {
        expect(median, lessThan(2000), reason: event);
      }
    }
    if (Platform.environment['CLOUD_COST'] == '1') {
      stdout.writeln(lines.join('\n'));
    }
  });
}
