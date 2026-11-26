import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart' show strategyId;
import 'sender_world.dart';

void main() {
  test(
      'Sol 3: while the strategy is open in the editor, access that comes '
      'back is noticed, and the waiting edit is sent', () {
    inWorld((world) {
      world.openInEditor(strategyId);
      world.server.answerWith(
        strategyId,
        const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved,
            point: stampedWhenAnswered),
      );
      world.server.overrideRead = (call) => const StoreReadRefused(
          StoreReadRefusal.forbidden, 'forbidden',
          point: stampedWhenAnswered);
      world.commitMove(1);
      world.settle(const Duration(hours: 1));
      expect(world.face(), Face.editAccessLost);
      world.server.overrideRead = null;
      world.settle(const Duration(hours: 1));
      expect(world.face(), isNot(Face.editAccessLost));
      expect(world.queueLength(), 0);
    });
  });
}
