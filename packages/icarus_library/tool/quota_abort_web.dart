import 'dart:math';
import 'dart:js_interop';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/indexed_db_storage.dart';
import 'package:web/web.dart';

void _say(String line) => console.log('icarus: $line'.toJS);

String _outcome(Committing committing) => switch (committing) {
  CommitApplied() => 'applied',
  CommitRefused(:final failure) => 'refused: $failure',
  CommitUnknown(:final failure) => 'unknown: $failure',
};

String _listed(Stored<List<String>> listed) => switch (listed) {
  Done(:final value) => value.join(' '),
  StorageFailed(:final failure) => 'not read: $failure',
};

Future<void> main() async {
  final estimate = await window.navigator.storage.estimate().toDart;
  _say('quota ${estimate.quota}, usage ${estimate.usage}');
  final engine = IndexedDbEngine('icarus-quota');
  final lease = switch (await engine.lease()) {
    Leased(:final lease) => lease,
    final other => throw StateError('$other'),
  };
  _say(
    'victim: ${_outcome(await lease.commit(const [Put('a', 'victim', 'here')]))}',
  );
  final random = Random(1);
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
  _say('keys after: ${_listed(await lease.keys('a', ''))}');
  final outcomes = <String, int>{};
  var filled = 0;
  for (var round = 0; round < 400; round++) {
    final outcome = await lease.commit([
      Put('fill', 'k$round', noise(100 * 1024)),
    ]);
    final kind = switch (outcome) {
      CommitApplied() => 'applied',
      CommitRefused(failure: NoRoomForCommit()) => 'refused for room',
      CommitRefused() => 'refused otherwise',
      CommitUnknown(failure: AbortedForQuota()) => 'aborted for quota',
      CommitUnknown() => 'unknown otherwise',
    };
    outcomes[kind] = (outcomes[kind] ?? 0) + 1;
    if (outcome is CommitApplied) filled++;
    if (outcome is! CommitApplied) {
      _say('filling stopped at round $round: ${_outcome(outcome)}');
      break;
    }
  }
  final after = await window.navigator.storage.estimate().toDart;
  _say('filled $filled commits of 100 KiB; $outcomes; usage ${after.usage}');
  await engine.close();
  _say('done');
}
