import 'package:icarus/collab/convex_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reactive view of the Convex WebSocket connection, seeded with the current
/// state so watchers don't flash "offline" while the stream warms up.
final convexConnectionProvider = StreamProvider<bool>((ref) async* {
  yield ConvexClient.instance.isConnected;
  await for (final state in ConvexClient.instance.connectionState) {
    yield state == WebSocketConnectionState.connected;
  }
});
