import 'package:flutter_test/flutter_test.dart';

import 'cloud_sender_live_test.dart'
    show liveList, listReads, storedPageName, teammateRenamesPage, theListRead;
import 'sender_world.dart';
import 'server_fixtures.dart' show servedAccount, strategyId;

void main() {
  test(
      'a live page list that answers before the take-up and is older than the '
      'take-up\'s own read owes nothing: one list read, not two', () {
    inWorld((world) {
      final from = world.async.elapsed;
      world.openInEditor(strategyId);
      world.sender.liveOpened(strategyId, theListRead);
      final first = liveList(world);
      world.sender.liveArrived(strategyId, theListRead, servedAccount, first);
      teammateRenamesPage(world, 'Renamed before the take-up');
      world.sender.adopt(strategyId);
      world.settle(const Duration(seconds: 30));
      expect(world.holds(), isTrue);
      expect(storedPageName(world), 'Renamed before the take-up');
      expect(listReads(world, from), hasLength(1));
    }, addStrategy: false);
  });

  test(
      'a live page list newer than the take-up\'s read is still taken, with '
      'no read of its own', () {
    inWorld((world) {
      final from = world.async.elapsed;
      world.openInEditor(strategyId);
      world.sender.liveOpened(strategyId, theListRead);
      world.sender.adopt(strategyId);
      world.settle(const Duration(seconds: 30));
      expect(listReads(world, from), hasLength(1));
      teammateRenamesPage(world, 'Renamed after the take-up');
      world.sender
          .liveArrived(strategyId, theListRead, servedAccount, liveList(world));
      world.settle(const Duration(seconds: 30));
      expect(storedPageName(world), 'Renamed after the take-up');
      expect(listReads(world, from), hasLength(1));
    }, addStrategy: false);
  });
}
