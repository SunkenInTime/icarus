import 'package:flutter/material.dart';
import 'dart:async';
import 'package:convex_flutter/convex_flutter.dart';

class AdvancedScreen extends StatefulWidget {
  const AdvancedScreen({super.key});

  @override
  State<AdvancedScreen> createState() => _AdvancedScreenState();
}

class _AdvancedScreenState extends State<AdvancedScreen> {
  String? _timeoutResult;
  bool _isTesting = false;
  AppLifecycleEvent? _currentLifecycle;
  final List<String> _lifecycleHistory = [];

  @override
  void initState() {
    super.initState();
    ConvexClient.instance.lifecycleEvents.listen((event) {
      setState(() {
        _currentLifecycle = event;
        _lifecycleHistory.insert(0, '${DateTime.now()}: ${event.name}');
        if (_lifecycleHistory.length > 10) _lifecycleHistory.removeLast();
      });
    });
  }

  Future<void> _testTimeout(int seconds) async {
    setState(() {
      _isTesting = true;
      _timeoutResult = null;
    });

    final stopwatch = Stopwatch()..start();
    try {
      await ConvexClient.instance.query("messages:list", {});
      stopwatch.stop();
      setState(() {
        _timeoutResult = 'Success in ${stopwatch.elapsedMilliseconds}ms';
        _isTesting = false;
      });
    } on TimeoutException {
      stopwatch.stop();
      setState(() {
        _timeoutResult = 'Timeout after ${stopwatch.elapsedMilliseconds}ms';
        _isTesting = false;
      });
    } catch (e) {
      stopwatch.stop();
      setState(() {
        _timeoutResult = 'Error: $e (${stopwatch.elapsedMilliseconds}ms)';
        _isTesting = false;
      });
    }
  }

  Future<void> _testAction() async {
    try {
      final result = await ConvexClient.instance.action(
        name: "myActions:doSomething",
        args: {"param": "test"},
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action result: $result')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeout testing
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Timeout Testing',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  const Text('Test query execution with different timeouts',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      ElevatedButton(
                        onPressed: _isTesting ? null : () => _testTimeout(1),
                        child: const Text('1s timeout')),
                      ElevatedButton(
                        onPressed: _isTesting ? null : () => _testTimeout(5),
                        child: const Text('5s timeout')),
                      ElevatedButton(
                        onPressed: _isTesting ? null : () => _testTimeout(30),
                        child: const Text('30s timeout')),
                    ],
                  ),
                  if (_timeoutResult != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(4)),
                      child: Text(_timeoutResult!,
                        style: const TextStyle(fontFamily: 'monospace')),
                    ),
                  ],
                  if (_isTesting)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator()),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Actions
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Server Actions',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  const Text('Execute backend actions (long-running operations)',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _testAction,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Run Test Action')),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Lifecycle management
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('App Lifecycle',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Current State:',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text(_currentLifecycle?.name ?? 'unknown'),
                        backgroundColor: _currentLifecycle == AppLifecycleEvent.resumed
                            ? Colors.green.shade100
                            : Colors.grey.shade100),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Recent Events:',
                    style: TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  if (_lifecycleHistory.isEmpty)
                    const Text('No events yet', style: TextStyle(color: Colors.grey))
                  else
                    ...(_lifecycleHistory.map((event) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(event,
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                    ))),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Error handling examples
          Card(
            color: Colors.orange.shade50,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb_outline, color: Colors.orange),
                      SizedBox(width: 8),
                      Text('Error Handling Tips',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  SizedBox(height: 12),
                  Text('• Always wrap operations in try-catch\n'
                       '• Handle TimeoutException separately\n'
                       '• Check ClientError types for specifics\n'
                       '• Use subscription onError callbacks\n'
                       '• Monitor connection state changes',
                    style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
