import 'package:flutter/material.dart';
import 'package:convex_flutter/convex_flutter.dart';
import 'widgets/connection_status_indicator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await ConvexClient.initialize(
    ConvexConfig(
      deploymentUrl: "https://your-deployment.convex.cloud",
      clientId: "flutter-example-app",
      operationTimeout: const Duration(seconds: 30),
    ),
  );

  runApp(const ConvexExampleApp());
}

class ConvexExampleApp extends StatelessWidget {
  const ConvexExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Convex Flutter - WebSocket State Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ConnectionDemoScreen(),
    );
  }
}

class ConnectionDemoScreen extends StatefulWidget {
  const ConnectionDemoScreen({super.key});

  @override
  State<ConnectionDemoScreen> createState() => _ConnectionDemoScreenState();
}

class _ConnectionDemoScreenState extends State<ConnectionDemoScreen> {
  final List<ConnectionEvent> _stateHistory = [];

  @override
  void initState() {
    super.initState();
    _listenToConnectionChanges();
  }

  void _listenToConnectionChanges() {
    ConvexClient.instance.connectionState.listen((state) {
      setState(() {
        _stateHistory.insert(0, ConnectionEvent(
          state: state,
          timestamp: DateTime.now(),
        ));
        if (_stateHistory.length > 20) {
          _stateHistory.removeLast();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebSocket State Demo'),
        actions: const [ConnectionStatusIndicator()],
      ),
      body: SingleChildScrollView(
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
      ),
    );
  }

  Widget _buildCurrentStateCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<WebSocketConnectionState>(
          stream: ConvexClient.instance.connectionState,
          initialData: ConvexClient.instance.currentConnectionState,
          builder: (context, snapshot) {
            final state = snapshot.data!;
            final isConnected = state == WebSocketConnectionState.connected;
            return Column(
              children: [
                Icon(
                  isConnected ? Icons.cloud_done : Icons.cloud_sync,
                  color: isConnected ? Colors.green : Colors.orange,
                  size: 64,
                ),
                const SizedBox(height: 12),
                Text(
                  state.name.toUpperCase(),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: isConnected ? Colors.green : Colors.orange,
                  ),
                ),
                Text('isConnected: ${ConvexClient.instance.isConnected}'),
              ],
            );
          },
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
            Text('✨ Real-time Connection State', 
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('• Automatic state updates\n'
                 '• Two states: Connected/Connecting\n'
                 '• Access via connectionState stream'),
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
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('History', 
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                TextButton(
                  onPressed: () => setState(() => _stateHistory.clear()),
                  child: const Text('Clear'),
                ),
              ],
            ),
            if (_stateHistory.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No state changes yet'),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _stateHistory.length,
                itemBuilder: (context, index) {
                  final event = _stateHistory[index];
                  final isConnected = 
                    event.state == WebSocketConnectionState.connected;
                  return ListTile(
                    leading: Icon(
                      isConnected ? Icons.cloud_done : Icons.cloud_sync,
                      color: isConnected ? Colors.green : Colors.orange,
                    ),
                    title: Text(event.state.name.toUpperCase()),
                    subtitle: Text(event.timestamp.toString()),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class ConnectionEvent {
  final WebSocketConnectionState state;
  final DateTime timestamp;
  ConnectionEvent({required this.state, required this.timestamp});
}
