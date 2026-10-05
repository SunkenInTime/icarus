import 'package:icarus/collab/convex_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the Convex WebSocket is connected right now, for code that checks
/// once before sending. It is the latest value of [convexConnectionProvider],
/// so it follows every change; before the stream's first event it asks the
/// client directly. (A snapshot read once and cached would keep whatever it
/// saw first: on web the socket is still opening at startup, so it said
/// offline forever and no edit was ever sent.)
final convexConnectionSnapshotProvider = Provider<bool>((ref) {
  return ref.watch(convexConnectionProvider).valueOrNull ??
      ConvexClient.instance.isConnected;
});

/// Reactive view of the Convex WebSocket connection, seeded with the current
/// state so watchers don't flash "offline" while the stream warms up.
final convexConnectionProvider = StreamProvider<bool>((ref) async* {
  final client = ConvexClient.instance;
  yield client.isConnected;
  await for (final state in client.connectionState) {
    yield state == WebSocketConnectionState.connected;
  }
});
