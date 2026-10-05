import 'package:flutter/material.dart';
import 'package:convex_flutter/convex_flutter.dart';

/// A reusable widget that displays the current WebSocket connection state.
///
/// This widget listens to the real-time connection state stream and
/// displays a colored chip indicator in the app bar.
class ConnectionStatusIndicator extends StatelessWidget {
  const ConnectionStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<WebSocketConnectionState>(
      stream: ConvexClient.instance.connectionState,
      initialData: ConvexClient.instance.currentConnectionState,
      builder: (context, snapshot) {
        print('snapshot: ${snapshot.data}');
        final state = snapshot.data ?? WebSocketConnectionState.connecting;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Chip(
            avatar: Icon(
              _getIcon(state),
              size: 16,
              color: _getColor(state),
            ),
            label: Text(
              _getLabel(state),
              style: const TextStyle(fontSize: 11),
            ),
            backgroundColor: Colors.white.withOpacity(0.9),
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
        );
      },
    );
  }

  IconData _getIcon(WebSocketConnectionState state) {
    switch (state) {
      case WebSocketConnectionState.connected:
        return Icons.cloud_done;
      case WebSocketConnectionState.connecting:
        return Icons.cloud_sync;
    }
  }

  Color _getColor(WebSocketConnectionState state) {
    switch (state) {
      case WebSocketConnectionState.connected:
        return Colors.green;
      case WebSocketConnectionState.connecting:
        return Colors.orange;
    }
  }

  String _getLabel(WebSocketConnectionState state) {
    switch (state) {
      case WebSocketConnectionState.connected:
        return 'Connected';
      case WebSocketConnectionState.connecting:
        return 'Connecting';
    }
  }
}
