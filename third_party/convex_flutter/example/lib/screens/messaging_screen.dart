import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:convex_flutter/convex_flutter.dart';

class MessagingScreen extends StatefulWidget {
  const MessagingScreen({super.key});

  @override
  State<MessagingScreen> createState() => _MessagingScreenState();
}

class _MessagingScreenState extends State<MessagingScreen> {
  final TextEditingController _messageController = TextEditingController();
  final String _currentUserId = "Flutter App";
  List<Map<String, dynamic>> _messages = [];
  SubscriptionHandle? _subscriptionHandle;
  bool _isSubscribed = false;
  int _messageCount = 0;

  @override
  void initState() {
    super.initState();
    _startSubscription();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _subscriptionHandle?.cancel();
    super.dispose();
  }

  Future<void> _startSubscription() async {
    if (_subscriptionHandle != null) return;

    try {
      _subscriptionHandle = await ConvexClient.instance.subscribe(
        name: "messages:list",
        args: {},
        onUpdate: (value) {
          if (!mounted) return;
          final List<dynamic> jsonList = jsonDecode(value);
          final List<Map<String, dynamic>> parsedMessages =
              jsonList.map((e) => e as Map<String, dynamic>).toList();
          setState(() {
            _messages = parsedMessages;
            _messageCount = parsedMessages.length;
            _isSubscribed = true;
          });
        },
        onError: (message, value) {
          if (!mounted) return;
          debugPrint("Subscription error: $message");
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $message')));
        },
      );
      if (mounted) setState(() => _isSubscribed = true);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to subscribe: $e')));
    }
  }

  void _stopSubscription() {
    _subscriptionHandle?.cancel();
    _subscriptionHandle = null;
    setState(() {
      _isSubscribed = false;
      _messages.clear();
    });
  }

  Future<void> _sendMessage() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) return;

    try {
      await ConvexClient.instance.mutation(
        name: "messages:send",
        args: {"body": message, "author": _currentUserId},
      );
      _messageController.clear();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send: $e')));
    }
  }

  Future<void> _queryMessages() async {
    try {
      final result = await ConvexClient.instance.query("messages:list", {});
      final List<dynamic> jsonList = jsonDecode(result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Query returned ${jsonList.length} messages')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Query failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Status bar
        Container(
          padding: const EdgeInsets.all(12),
          color: _isSubscribed ? Colors.green.shade100 : Colors.orange.shade100,
          child: Row(
            children: [
              Icon(_isSubscribed ? Icons.wifi : Icons.wifi_off,
                color: _isSubscribed ? Colors.green : Colors.orange),
              const SizedBox(width: 8),
              Text(_isSubscribed ? 'Live Updates' : 'Paused',
                style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('$_messageCount messages'),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(_isSubscribed ? Icons.pause : Icons.play_arrow),
                onPressed: _isSubscribed ? _stopSubscription : _startSubscription,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _queryMessages,
                tooltip: 'Query messages'),
            ],
          ),
        ),

        // Message list
        Expanded(
          child: _messages.isEmpty
              ? const Center(child: Text('No messages yet'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[index];
                    final isMyMessage = message['userId'] == _currentUserId ||
                        message['author'] == _currentUserId;

                    return Align(
                      alignment: isMyMessage
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.7),
                        decoration: BoxDecoration(
                          color: isMyMessage ? Colors.blue[100] : Colors.grey[200],
                          borderRadius: BorderRadius.circular(12).copyWith(
                            bottomRight: isMyMessage ? Radius.zero : const Radius.circular(12),
                            bottomLeft: isMyMessage ? const Radius.circular(12) : Radius.zero),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(message['body'] ?? '',
                              style: const TextStyle(fontSize: 16)),
                            if (message['author'] != null)
                              Text('- ${message['author']}',
                                style: const TextStyle(fontSize: 10, color: Colors.grey)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),

        // Input area
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.2),
              spreadRadius: 1, blurRadius: 3)],
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  decoration: InputDecoration(
                    hintText: 'Type a message...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8)),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _sendMessage,
                icon: const Icon(Icons.send),
                color: Colors.blue),
            ],
          ),
        ),
      ],
    );
  }
}
