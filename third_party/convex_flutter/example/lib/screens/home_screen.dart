import 'package:flutter/material.dart';
import 'package:convex_flutter/convex_flutter.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Trigger auto-connection on app startup
    _establishConnection();
  }

  Future<void> _establishConnection() async {
    try {
      // Use a health check query to establish the WebSocket connection
      // Create this query in your Convex backend: convex/health.ts
      await ConvexClient.instance.query(
        'health:ping',
        {},
      );
      debugPrint('HomeScreen: Auto-connection established via health check query');
    } catch (e) {
      debugPrint('HomeScreen: Auto-connection failed: $e');
      // Connection will retry automatically via Convex client
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.rocket_launch, size: 64,
                    color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('Welcome to Convex Flutter',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  const Text(
                    'Explore all SDK capabilities',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('Features', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          _FeatureCard(icon: Icons.login, title: 'Authentication',
            description: 'JWT tokens, auto-refresh',color: Colors.purple),
          _FeatureCard(icon: Icons.message, title: 'Real-time Messaging',
            description: 'Subscriptions, queries, mutations', color: Colors.blue),
          _FeatureCard(icon: Icons.wifi, title: 'Connection State',
            description: 'WebSocket state tracking', color: Colors.green),
          _FeatureCard(icon: Icons.settings, title: 'Advanced',
            description: 'Timeouts, actions, lifecycle', color: Colors.orange),
          const SizedBox(height: 24),
          _buildStatusSummary(),
        ],
      ),
    );
  }

  Widget _buildStatusSummary() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Current Status',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            StreamBuilder<WebSocketConnectionState>(
              stream: ConvexClient.instance.connectionState,
              builder: (context, snapshot) {
                final state = snapshot.data;
                return _StatusRow(icon: Icons.wifi, label: 'Connection',
                  value: state?.name ?? 'Unknown',
                  color: state == WebSocketConnectionState.connected
                      ? Colors.green : Colors.orange);
              }),
            const Divider(),
            StreamBuilder<bool>(
              stream: ConvexClient.instance.authState,
              builder: (context, snapshot) {
                final isAuth = snapshot.data ?? false;
                return _StatusRow(icon: Icons.lock, label: 'Auth',
                  value: isAuth ? 'Yes' : 'No',
                  color: isAuth ? Colors.green : Colors.grey);
              }),
          ],
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Color color;
  const _FeatureCard({required this.icon, required this.title,
    required this.description, required this.color});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, color: color, size: 32),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(description),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _StatusRow({required this.icon, required this.label,
    required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        const Spacer(),
        Text(value, style: TextStyle(color: color)),
      ],
    );
  }
}
