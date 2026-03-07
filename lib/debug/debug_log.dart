import 'dart:convert';
import 'dart:io';

void appendDebugLog({
  required String hypothesisId,
  required String location,
  required String message,
  Map<String, Object?> data = const <String, Object?>{},
}) {
  try {
    File('/workspace/debug.log').writeAsStringSync(
      '${jsonEncode(<String, Object?>{
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
