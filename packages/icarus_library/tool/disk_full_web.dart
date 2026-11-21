import 'dart:js_interop';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/indexed_db_storage.dart';
import 'package:web/web.dart';

void _say(String line) => console.log('icarus: $line'.toJS);

String _outcome(Committing committing) => switch (committing) {
  CommitApplied() => 'applied',
  CommitRefused(:final failure) => 'refused: $failure',
  CommitUnknown(:final failure) => 'unknown: $failure',
};

Future<void> _waitForGo() async {
  while (true) {
    final response = await window.fetch('go'.toJS).toDart;
    if (response.ok) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<void> main() async {
  final engine = IndexedDbEngine('icarus-disk-full');
  final lease = switch (await engine.lease()) {
    Leased(:final lease) => lease,
    final other => throw StateError('$other'),
  };
  _say(
    'victim: ${_outcome(await lease.commit(const [Put('a', 'victim', 'here')]))}',
  );
  _say('ready');
  await _waitForGo();
  final random = Random(3);
  String noise(int length) => String.fromCharCodes([
    for (var c = 0; c < length; c++) 33 + random.nextInt(90),
  ]);
  final result = await lease.commit([
    for (var i = 0; i < 16; i++) ...[
      Put('a', 'l$i', noise(256 * 1024)),
      if (i == 8) const Delete('a', 'victim'),
    ],
  ]);
  _say('commit: ${_outcome(result)}');
  final keys = switch (await lease.keys('a', '')) {
    Done(:final value) => value.join(' '),
    StorageFailed(:final failure) => 'not read: $failure',
  };
  _say('keys after: $keys');
  await engine.close();
  _say('done');
}
