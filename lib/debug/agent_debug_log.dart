import 'dart:convert';
import 'dart:io';

void writeAgentDebugLog({
  required String hypothesisId,
  required String location,
  required String message,
  Map<String, Object?> data = const <String, Object?>{},
}) {
  try {
    File('/opt/cursor/logs/debug.log').writeAsStringSync(
      '${jsonEncode({
            'hypothesisId': hypothesisId,
            'location': location,
            'message': message,
            'data': data,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          })}\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}
