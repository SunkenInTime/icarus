import 'package:flutter_test/flutter_test.dart';

import 'sender_world.dart';

void main() {
  test(
      'five plain element edits make no page-list read and one page read, as '
      'on main', () {
    inWorld((world) {
      world.settle(const Duration(seconds: 30));
      final before = world.server.readCalls.length;
      for (var n = 1; n <= 5; n++) {
        world.commitMove(n);
        world.settle(const Duration(seconds: 30));
      }
      world.settle(const Duration(minutes: 5));
      final reads = world.server.readCalls.skip(before).toList();
      expect(world.server.calls, hasLength(5));
      expect(reads.where((call) => call.page == null), isEmpty);
      expect(reads.where((call) => call.page != null), hasLength(1));
    });
  });
}
