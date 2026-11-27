import 'package:flutter_test/flutter_test.dart';
import 'package:icarus_library/icarus_library.dart';

import 'server_fixtures.dart' show serverRows, strategyId;
import 'sender_world.dart';

void main() {
  test(
      'an item add that lands on a page a teammate deletes is retired once a '
      'read of that page shows it gone, and the sender stops reading for it',
      () {
    inWorld((world) {
      world.settle();
      final page =
          serverRows().elements.whereType<LiveElement>().first.pagePublicId;
      world.server.answerNext(strategyId, (call) async {
        final applied = world.server.applyAll(call);
        world.teammateDeletesPage(page);
        return applied;
      });
      world.commitAdds(1);
      world.settle(const Duration(minutes: 2));
      final reads = world.server.readCalls.length;
      world.settle(const Duration(hours: 1));
      expect(world.cloud().queue.landed, isEmpty);
      expect(world.server.readCalls.length - reads, lessThanOrEqualTo(1));
    });
  });
}
