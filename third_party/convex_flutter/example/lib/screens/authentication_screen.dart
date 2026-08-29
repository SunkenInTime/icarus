import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:convex_flutter/convex_flutter.dart';

class AuthenticationScreen extends StatefulWidget {
  const AuthenticationScreen({super.key});

  @override
  State<AuthenticationScreen> createState() => _AuthenticationScreenState();
}

class _AuthenticationScreenState extends State<AuthenticationScreen> {
  final TextEditingController _tokenController = TextEditingController();
  bool _isAuthenticated = false;
  AuthHandleWrapper? _authHandle;
  int _refreshCount = 0;
  DateTime? _lastRefreshTime;
  Map<String, dynamic>? _tokenClaims;

  @override
  void initState() {
    super.initState();
    ConvexClient.instance.authState.listen((isAuth) {
      setState(() => _isAuthenticated = isAuth);
    });
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _authHandle?.dispose();
    super.dispose();
  }

  // Decode JWT to show claims
  void _decodeToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return;
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      setState(() => _tokenClaims = jsonDecode(payload));
    } catch (e) {
      debugPrint('Error decoding token: $e');
    }
  }

  Future<void> _setAuth() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) return;
    
    try {
      await ConvexClient.instance.setAuth(token: token);
      _decodeToken(token);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Auth token set successfully')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _setAuthWithRefresh() async {
    try {
      _authHandle?.dispose();
      _authHandle = await ConvexClient.instance.setAuthWithRefresh(
        fetchToken: () async {
          setState(() {
            _refreshCount++;
            _lastRefreshTime = DateTime.now();
          });
          // Mock token generation for demo
          return 'mock_token_${DateTime.now().millisecondsSinceEpoch}';
        },
        onAuthChange: (isAuthenticated) {
          debugPrint('Auth changed: $isAuthenticated');
        },
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Auto-refresh enabled')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _clearAuth() async {
    try {
      _authHandle?.dispose();
      _authHandle = null;
      await ConvexClient.instance.clearAuth();
      setState(() {
        _tokenClaims = null;
        _refreshCount = 0;
        _lastRefreshTime = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Auth cleared')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Auth status card
          Card(
            color: _isAuthenticated ? Colors.green.shade50 : Colors.grey.shade100,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(_isAuthenticated ? Icons.verified_user : Icons.person_off,
                    color: _isAuthenticated ? Colors.green : Colors.grey, size: 32),
                  const SizedBox(width: 12),
                  Text(_isAuthenticated ? 'Authenticated' : 'Not Authenticated',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Static token auth
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Static Token Auth',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _tokenController,
                    decoration: const InputDecoration(
                      labelText: 'JWT Token',
                      border: OutlineInputBorder(),
                      hintText: 'Paste your JWT token here'),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _setAuth,
                    icon: const Icon(Icons.login),
                    label: const Text('Set Auth Token'),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Auto-refresh auth
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Auto-Refresh Auth (Recommended)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Automatically refreshes tokens before expiry',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _setAuthWithRefresh,
                    icon: const Icon(Icons.autorenew),
                    label: const Text('Enable Auto-Refresh'),
                  ),
                  if (_refreshCount > 0) ...[
                    const SizedBox(height: 12),
                    Text('Refresh count: $_refreshCount',
                      style: const TextStyle(fontFamily: 'monospace')),
                    if (_lastRefreshTime != null)
                      Text('Last refresh: ${_lastRefreshTime}',
                        style: const TextStyle(fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Token info
          if (_tokenClaims != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Token Claims',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(jsonEncode(_tokenClaims),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 16),

          // Clear auth
          OutlinedButton.icon(
            onPressed: _clearAuth,
            icon: const Icon(Icons.logout),
            label: const Text('Clear Auth'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      ),
    );
  }
}
