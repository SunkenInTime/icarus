// The gauntlet's own line to the deployment, over Convex's HTTP API: it
// reads what the server holds, and writes as a teammate on another device.
// It shares nothing with the app's client.
import 'dart:convert';
import 'dart:io';

final class ServerLine {
  ServerLine({required this.deploymentUrl, required this.accessToken});

  final String deploymentUrl;
  String accessToken;
  final HttpClient _http = HttpClient();

  Future<Object?> query(String path, Map<String, Object?> args) =>
      _call('query', path, args);

  Future<Object?> mutation(String path, Map<String, Object?> args) =>
      _call('mutation', path, args);

  Future<Object?> _call(
    String kind,
    String path,
    Map<String, Object?> args,
  ) async {
    final request = await _http.postUrl(
      Uri.parse('$deploymentUrl/api/$kind'),
    );
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    request.write(jsonEncode({'path': path, 'args': args, 'format': 'json'}));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body) as Map<String, Object?>;
    if (decoded['status'] != 'success') {
      throw StateError('$path failed: $body');
    }
    return decoded['value'];
  }

  void close() => _http.close(force: true);
}
