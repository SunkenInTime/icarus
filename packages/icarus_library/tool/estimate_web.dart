import 'dart:js_interop';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/indexed_db_storage.dart';
import 'package:web/web.dart';

void _say(String line) => console.log('icarus: $line'.toJS);

Future<(int, int, double)> _estimate() async {
  final watch = Stopwatch()..start();
  final estimate = await window.navigator.storage.estimate().toDart;
  return (estimate.usage, estimate.quota, watch.elapsedMicroseconds / 1000);
}

String _noise(Random random, int length) =>
    String.fromCharCodes(List.generate(length, (_) => 33 + random.nextInt(90)));

Future<void> main() async {
  _say(window.navigator.userAgent);
  final engine = IndexedDbEngine('icarus-estimate');
  final lease = switch (await engine.lease()) {
    Leased(:final lease) => lease,
    final other => throw StateError('$other'),
  };
  final random = Random(2);
  final times = <double>[];
  for (var round = 0; round < 12; round++) {
    final (before, quota, took) = await _estimate();
    times.add(took);
    final bytes = 64 * 1024 * (1 + round % 3);
    final applied = await lease.commit([
      Put('area', 'k$round', _noise(random, bytes)),
    ]);
    final (now, _, _) = await _estimate();
    await Future<void>.delayed(const Duration(seconds: 1));
    final (later, _, _) = await _estimate();
    await Future<void>.delayed(const Duration(seconds: 4));
    final (latest, _, _) = await _estimate();
    _say(
      'round $round: wrote $bytes chars ($applied), usage grew '
      '${now - before} at once, ${later - before} after 1 s, '
      '${latest - before} after 5 s; quota $quota',
    );
  }
  times.sort();
  _say(
    'estimate() took median ${times[times.length ~/ 2]} ms, max ${times.last} ms',
  );
  await engine.close();
  _say('done');
}
