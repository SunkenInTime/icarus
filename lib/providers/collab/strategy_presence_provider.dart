import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/collab/presence/presence_room.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/lineup_editing_presence_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

export 'package:icarus/collab/presence/presence_models.dart';

/// Who else has the open cloud strategy open, and their cursors. Joins the
/// strategy's room while the editor shows a cloud strategy, and leaves as soon
/// as nothing on screen watches it, however the editor was left. Local
/// strategies have no room.
final strategyPresenceProvider =
    NotifierProvider.autoDispose<StrategyPresenceNotifier, PresenceRoomState>(
  StrategyPresenceNotifier.new,
);

class StrategyPresenceNotifier extends AutoDisposeNotifier<PresenceRoomState> {
  PresenceRoom? _room;

  @override
  PresenceRoomState build() {
    final strategyPublicId = ref.watch(
      strategyProvider.select(
        (s) =>
            s.isOpen && s.source == StrategySource.cloud ? s.strategyId : null,
      ),
    );
    final cloudEnabled = ref.watch(isCloudCollabEnabledProvider);
    if (strategyPublicId == null || !cloudEnabled) {
      _room = null;
      return PresenceRoomState.off;
    }

    final repository = ref.read(convexStrategyRepositoryProvider);
    final room = PresenceRoom(
      issuePass: () => repository.issueRoomPass(strategyPublicId),
    );
    _room = room;
    final subscription = room.states.listen((next) => state = next);
    ref.onDispose(() {
      subscription.cancel();
      room.dispose();
    });
    room.start();
    // What this user is editing goes out as it changes, and from the start.
    ref.listen(
      myLineupEditingProvider,
      (_, editing) => room.setEditing(editing),
      fireImmediately: true,
    );
    return room.state;
  }

  /// The pointer is over the map at ([x], [y]) in attack-side world
  /// coordinates, on the page being viewed.
  void moveCursor(double x, double y) {
    final pageId = ref.read(strategyPageSessionProvider).activePageId;
    if (pageId == null) return;
    _room?.moveCursor(PresenceCursor(pageId: pageId, x: x, y: y));
  }

  void hideCursor() => _room?.hideCursor();
}
