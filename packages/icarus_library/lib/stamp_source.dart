import 'dart:math';

import 'icarus_library.dart';

final class StampSource {
  StampSource(this.random, {required ResultPoint from, required this.now})
    : client = from.client,
      connection = from.connection,
      applied = from.connection,
      snapshot = from.snapshot,
      time = from.serverTime;

  final Random? random;
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

  bool _oneIn(int odds) => random?.nextInt(odds) == 0;

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
    if (sameConnection && before != null && _oneIn(6)) {
      _count('a new snapshot at the same time');
    } else {
      final floor = sameConnection ? before ?? 0 : 0;
      time = max(floor, now() - _lag) + 1 + (random?.nextInt(1000) ?? 0);
    }
    _lag ~/= 2;
    if (!sameConnection && before != null && time! < before) {
      _count('time went back on a new connection');
    }
    return current;
  }

  bool get _wouldGoBack => now() - _lag < time!;

  ResultPoint at(Object state) {
    if (time == null && applied == connection && _oneIn(4)) {
      _count('a read before any state was applied');
      _seen = state;
      return current;
    }
    if (identical(state, _seen) &&
        time != null &&
        applied == connection &&
        _oneIn(3)) {
      _count('a stamp at the snapshot already held');
      return current;
    }
    if (identical(state, _seen) &&
        time != null &&
        applied != connection &&
        !_wouldGoBack &&
        _oneIn(3)) {
      _count('a stamp at the snapshot held from before a reconnect');
      return current;
    }
    _seen = state;
    return _apply();
  }

  ResultPoint get answered => answeredFrom(current);

  ResultPoint answeredFrom(ResultPoint held) {
    if (held.serverTime == null) {
      _count('an answer before any state was applied');
    } else {
      _count('an answer at the last snapshot the client applied');
    }
    if (held.connection != connection) {
      _count('an answer stamped on the connection before a reconnect');
    }
    return held;
  }

  ResultPoint probe(int ahead) => ResultPoint(
    client: client,
    connection: connection,
    snapshot: snapshot + ahead,
    serverTime: max(time ?? 0, now()) + ahead,
  );

  void _laggedConnection() {
    if (random?.nextBool() ?? false) _lag = 1 + random!.nextInt(2000000000);
  }

  Generation reconnect() =>
      reconnectTo(connection + 1 + (_oneIn(4) ? 1 + random!.nextInt(3) : 0));

  Generation reconnectTo(int next) {
    connection = next;
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
    _seen = null;
    _laggedConnection();
  }
}
