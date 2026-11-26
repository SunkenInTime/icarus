import 'dart:math';

import 'package:icarus_library/icarus_library.dart';

final class StampSource {
  StampSource(this.random, {required ResultPoint from, required this.now})
    : client = from.client,
      connection = from.connection,
      applied = from.connection,
      snapshot = from.snapshot,
      time = from.serverTime;

  final Random random;
  final int Function() now;
  int client;
  int connection;
  int applied;
  int snapshot;
  int? time;
  int _lag = 0;
  Object? _seen;
  final made = <String, int>{};

  void _count(String what) => made[what] = (made[what] ?? 0) + 1;

  ResultPoint get current => ResultPoint(
    client: client,
    connection: applied,
    snapshot: snapshot,
    serverTime: time,
  );

  Generation get generation =>
      Generation(client: client, connection: connection);

  ResultPoint _apply() {
    snapshot++;
    final before = time;
    final sameConnection = applied == connection;
    applied = connection;
    if (sameConnection && before != null && random.nextInt(6) == 0) {
      _count('a new snapshot at the same time');
    } else {
      final floor = sameConnection ? before ?? 0 : 0;
      time = max(floor, now() - _lag) + 1 + random.nextInt(1000);
    }
    _lag ~/= 2;
    if (!sameConnection && before != null && time! < before) {
      _count('time went back on a new connection');
    }
    return current;
  }

  ResultPoint at(Object state) {
    if (identical(state, _seen) &&
        time != null &&
        applied == connection &&
        random.nextInt(3) == 0) {
      _count('a stamp at the snapshot already held');
      return current;
    }
    _seen = state;
    return _apply();
  }

  ResultPoint get answered {
    if (time == null) _count('an answer before any state was applied');
    if (applied != connection) {
      _count('an answer stamped on the connection before a reconnect');
    }
    return current;
  }

  ResultPoint probe(int ahead) => ResultPoint(
    client: client,
    connection: connection,
    snapshot: snapshot + ahead,
    serverTime: max(time ?? 0, now()) + ahead,
  );

  void _laggedConnection() {
    _seen = null;
    if (random.nextBool()) _lag = 1 + random.nextInt(2000000000);
  }

  Generation reconnect() {
    connection += 1 + (random.nextInt(4) == 0 ? 1 + random.nextInt(3) : 0);
    _laggedConnection();
    return generation;
  }

  Generation anotherClient() {
    client++;
    _fresh();
    _count('a second client in one run');
    return generation;
  }

  void restart() {
    client = 1;
    _fresh();
  }

  void _fresh() {
    connection = 1;
    applied = 1;
    snapshot = 0;
    time = null;
    _laggedConnection();
  }
}
