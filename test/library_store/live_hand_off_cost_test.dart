import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus_library/icarus_library.dart';

import 'live_pages.dart';
import 'sender_world.dart';
import 'server_fixtures.dart' show pageId, strategyId;

const runs = 20;

typedef Timed = ({List<int> micros, int decoded});

Timed timed(World world, LivePageAnswer answer) {
  final micros = <int>[];
  var decoded = 0;
  for (var run = 0; run <= runs; run++) {
    final watch = Stopwatch()..start();
    HeldOnPage? held;
    world.sender.store
        .heldOnPage(strategyId, pageId)
        .then((value) => held = value);
    world.async.flushMicrotasks();
    final converted = livePageOutcome(answer, canRead: appCanRead, held: held!);
    watch.stop();
    expect(
      converted.outcome,
      isA<StoreReadAnswered>().having(
        (read) => (read.base as PageRead).elements.length,
        'elements',
        heavyItems,
      ),
    );
    decoded = converted.decoded;
    if (run > 0) micros.add(watch.elapsedMicroseconds);
  }
  return (micros: micros..sort(), decoded: decoded);
}

String described(String what, Timed timed) {
  final micros = timed.micros;
  final median = (micros[runs ~/ 2 - 1] + micros[runs ~/ 2]) / 2;
  String ms(num micros) => (micros / 1000).toStringAsFixed(2);
  return '$what ($heavyItems items, ${timed.decoded} rows decoded): median '
      '${ms(median)} ms over $runs runs, fastest ${ms(micros.first)} ms, '
      'slowest ${ms(micros.last)} ms';
}

LivePageAnswer answerOf(World world) => LivePageAnswer(
      remotePageOf(world),
      pagePublicId: pageId,
      point: world.server.stamp(),
    );

void main() {
  test(
      'the store\'s part of one live answer of the driver\'s heavy page: '
      'reading the rows it holds there and converting the answer against '
      'them, for a first answer and for an edit answer', () {
    late final Timed first;
    late final Timed edit;
    inWorld((world) {
      fillServerPage(world, heavyItems);
      world.sender.liveOpened(strategyId, openPage);
      world.sender.adopt(strategyId);
      world.settle(const Duration(seconds: 1));

      first = timed(world, answerOf(world));
      expect(first.decoded, heavyItems);

      deliver(world);
      world.teammateMoves(1);
      edit = timed(world, answerOf(world));
      expect(edit.decoded, 1);
    }, addStrategy: false);

    printOnFailure('first ${first.micros}, edit ${edit.micros}');
    debugPrint(described('first answer', first));
    debugPrint(described('edit answer', edit));
  });
}
