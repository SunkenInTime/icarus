import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final ws = await WebSocket.connect('ws://127.0.0.1:49695/OqqMw7jKLMo=/ws');
  var nextId = 1;
  ws.add(jsonEncode({'jsonrpc': '2.0', 'id': nextId++, 'method': 'getVM'}));
  await for (final raw in ws) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final result = msg['result'];
    if (result is Map && result['type'] == 'VM') {
      final isolates = result['isolates'] as List<dynamic>? ?? [];
      for (final iso in isolates) {
        final m = iso as Map<String, dynamic>;
        print('${m['id']}: ${m['name']}');
      }
      final first = isolates.isNotEmpty ? isolates.first as Map : null;
      if (first != null) {
        ws.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': nextId++,
          'method': 'getIsolate',
          'params': {'isolateId': first['id']},
        }));
      }
      continue;
    }
    if (result is Map && result['type'] == 'Isolate') {
      print('extensionRPCs: ${result['extensionRPCs']}');
      await ws.close();
      return;
    }
  }
}
