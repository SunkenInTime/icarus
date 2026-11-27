import 'package:flutter_test/flutter_test.dart';
import 'package:icarus_library/icarus_library.dart';

import 'server_fixtures.dart' show strategyId;
import 'sender_world.dart';

const pages = ['p2', 'p3', 'p4', 'p5'];

int strategyRevision(World world) =>
    (world.rowOf((content) => content.strategy).toJson()! as Map)['revision']!
        as int;

void reorder(World world) => world.commit([
      PageReorderOp(
        opId: 'reorder',
        pagePublicId: 'p3',
        sortIndex: 0,
        expectedStrategyRevision: strategyRevision(world),
      ),
    ]);

Map<String, int> callsAfter(
  void Function(World world) act, {
  Duration over = const Duration(minutes: 30),
}) {
  late Map<String, int> counted;
  inWorld(
    (world) {
      world.pagesOnServer(pages);
      world.sender.adopt(strategyId);
      world.settle(const Duration(minutes: 1));
      expect(world.face(), isNull);
      final calls = <String>[];
      world.server.onRead = (call) => calls.add('$call');
      world.server.onCall = (call) => calls.add('send ${call.opIds.join(',')}');
      act(world);
      world.settle(over);
      expect(world.face(), isNull);
      expect(world.queueLength(), 0);
      counted = {
        for (final call in calls.toSet())
          call: calls.where((other) => other == call).length,
      };
    },
    addStrategy: false,
  );
  return counted;
}

void main() {
  test(
      'a reorder of pages followed by an edit of one item on one page reads '
      'only the page list and that page', () {
    final calls = callsAfter((world) {
      reorder(world);
      world.settle(const Duration(seconds: 5));
      world.commitMove(1);
    });
    expect(calls, {
      'send reorder': 1,
      'send move-1': 1,
      'list': 1,
      'page p1': 1,
    });
  });

  test(
      'an edit of one item followed by a rename of its page reads the page '
      'list and that page once, as main does', () {
    final calls = callsAfter((world) {
      world.commitMove(1);
      world.settle(const Duration(seconds: 5));
      final revision = (world
          .rowOf(
            (content) =>
                content.pages.firstWhere((page) => page.publicId == 'p1'),
          )
          .toJson()! as Map)['revision']! as int;
      world.commit([
        PagePatchOp(
          opId: 'rename',
          pagePublicId: 'p1',
          expectedPageRevision: revision,
          name: 'Renamed',
        ),
      ]);
    });
    expect(calls, {
      'send move-1': 1,
      'send rename': 1,
      'list': 1,
      'page p1': 1,
    });
  });

  test(
      'a reorder of pages followed by deleting one page reads the page list '
      'and that page, and no other page', () {
    final calls = callsAfter((world) {
      reorder(world);
      world.settle(const Duration(seconds: 5));
      world.commitPageDelete('delete-p4', 'p4');
    });
    expect(calls, {
      'send reorder': 1,
      'send delete-p4': 1,
      'list': 2,
      'page p4': 1,
    });
  });
}
