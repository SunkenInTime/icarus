import 'dart:async';
import 'package:flutter/material.dart';
import 'package:convex_flutter/convex_flutter.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final List<ConnectionEvent> _stateHistory = [];
  StreamSubscription<WebSocketConnectionState>? _connectionSubscription;

  @override
  void initState() {
    super.initState();
    _connectionSubscription = ConvexClient.instance.connectionState.listen((state) {
      if (mounted) {
        setState(() {
          _stateHistory.insert(0, ConnectionEvent(
            state: state,
            timestamp: DateTime.now()));
          if (_stateHistory.length > 20) _stateHistory.removeLast();
        });
      }
    });
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCurrentStateCard(),
          const SizedBox(height: 16),
          _buildFeatureCard(),
          const SizedBox(height: 16),
          _buildHistoryCard(),
        ],
      ),
    );
  }

  Widget _buildCurrentStateCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('WebSocket Connection State',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Text('Real-time state from underlying WebSocket',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 16),
            StreamBuilder<WebSocketConnectionState>(
              stream: ConvexClient.instance.connectionState,
              initialData: ConvexClient.instance.currentConnectionState,
              builder: (context, snapshot) {
                final state = snapshot.data!;
                final isConnected = state == WebSocketConnectionState.connected;
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isConnected ? Colors.green.shade50 : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isConnected ? Colors.green : Colors.orange, width: 2)),
                  child: Row(
                    children: [
                      Icon(isConnected ? Icons.cloud_done : Icons.cloud_sync,
                        color: isConnected ? Colors.green : Colors.orange, size: 48),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(state.name.toUpperCase(),
                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                                color: isConnected ? Colors.green : Colors.orange)),
                            Text(isConnected ? 'WebSocket is open' : 'WebSocket connecting',
                              style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
            const SizedBox(height: 12),
            Text('isConnected: ${ConvexClient.instance.isConnected}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureCard() {
    return Card(
      color: Colors.blue.shade50,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('✨ New Feature: Real-time Connection State',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('• Automatic state updates without polling\n'
                 '• Two states: Connected and Connecting\n'
                 '• Reflects actual WebSocket connection\n'
                 '• Access via connectionState stream\n'
                 '• Convenience getter: isConnected',
              style: TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('State Change History',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                TextButton.icon(
                  onPressed: () => setState(() => _stateHistory.clear()),
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text('Clear')),
              ],
            ),
            const SizedBox(height: 8),
            if (_stateHistory.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: Text('No state changes yet',
                  style: TextStyle(color: Colors.grey))))
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _stateHistory.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (context, index) {
                  final event = _stateHistory[index];
                  final isConnected = event.state == WebSocketConnectionState.connected;
                  return ListTile(
                    leading: Icon(isConnected ? Icons.cloud_done : Icons.cloud_sync,
                      color: isConnected ? Colors.green : Colors.orange),
                    title: Text(event.state.name.toUpperCase()),
                    subtitle: Text(_formatTime(event.timestamp)),
                    trailing: Text(_timeAgo(event.timestamp),
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

class ConnectionEvent {
  final WebSocketConnectionState state;
  final DateTime timestamp;
  ConnectionEvent({required this.state, required this.timestamp});
}
