import 'dart:convert';
import 'dart:io';

const _defaultPort = 14317;

Future<void> main(List<String> arguments) async {
  final port = _readPort(arguments);
  final root = Directory.current.absolute;
  final index = File(
    _join(root.path, 'tool/vision_collision_audit/index.html'),
  );
  final manifest = File(
    _join(root.path, 'assets/maps/vision_boundary_additions.json'),
  );
  if (!index.existsSync() || !manifest.existsSync()) {
    stderr.writeln('Run this tool from the Icarus repository root.');
    exitCode = 66;
    return;
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('Vision collision audit: http://127.0.0.1:$port');
  stdout.writeln('Saving to ${manifest.path}');
  await for (final request in server) {
    try {
      if (request.method == 'GET' && request.uri.path == '/') {
        await _sendFile(request.response, index, 'text/html; charset=utf-8');
      } else if (request.method == 'GET' && request.uri.path == '/api/state') {
        await _sendJson(request.response, {
          'manifest': jsonDecode(await manifest.readAsString()),
          'maps': await _readMaps(root),
        });
      } else if (request.method == 'POST' && request.uri.path == '/api/state') {
        final body = await utf8.decoder.bind(request).join();
        if (body.length > 1024 * 1024) {
          throw const FormatException('Manifest exceeds 1 MB.');
        }
        final decoded = jsonDecode(body);
        _validateManifest(decoded);
        const encoder = JsonEncoder.withIndent('  ');
        await manifest.writeAsString('${encoder.convert(decoded)}\n');
        await _sendJson(request.response, {'saved': true});
      } else if (request.method == 'GET' &&
          request.uri.path.startsWith('/assets/maps/')) {
        final relative = request.uri.path.substring(1).replaceAll('/', '\\');
        final file = File(_join(root.path, relative)).absolute;
        final assetRoot = Directory(_join(root.path, 'assets/maps')).absolute;
        if (!file.path.toLowerCase().startsWith(
              '${assetRoot.path.toLowerCase()}${Platform.pathSeparator}',
            ) ||
            !file.existsSync()) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        await _sendFile(
          request.response,
          file,
          file.path.endsWith('.svg')
              ? 'image/svg+xml; charset=utf-8'
              : 'application/json; charset=utf-8',
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } on Object catch (error) {
      request.response.statusCode = HttpStatus.badRequest;
      await _sendJson(request.response, {'error': error.toString()});
    }
  }
}

int _readPort(List<String> arguments) {
  for (var index = 0; index < arguments.length; index += 1) {
    if (arguments[index] == '--port' && index + 1 < arguments.length) {
      return int.parse(arguments[index + 1]);
    }
  }
  return _defaultPort;
}

Future<List<Map<String, Object>>> _readMaps(Directory root) async {
  final directory = Directory(_join(root.path, 'assets/maps'));
  final result = <Map<String, Object>>[];
  await for (final entry in directory.list()) {
    if (entry is! File || !entry.path.endsWith('_vision.json')) continue;
    final name = entry.uri.pathSegments.last.replaceFirst('_vision.json', '');
    final decoded = jsonDecode(await entry.readAsString());
    if (decoded is! Map<String, dynamic> || decoded['layers'] is! List)
      continue;
    final layers = decoded['layers'] as List;
    result.add({
      'name': name,
      'elevations': [
        for (final layer in layers)
          if (layer is Map<String, dynamic> && layer['elevation'] is num)
            layer['elevation'],
      ],
    });
  }
  result.sort(
    (left, right) =>
        (left['name']! as String).compareTo(right['name']! as String),
  );
  return result;
}

void _validateManifest(dynamic value) {
  if (value is! Map<String, dynamic> ||
      value['version'] != 1 ||
      value['maps'] is! Map<String, dynamic>) {
    throw const FormatException('Invalid boundary additions root.');
  }
  final seenIds = <String>{};
  final maps = value['maps'] as Map<String, dynamic>;
  for (final mapEntry in maps.entries) {
    final map = mapEntry.value;
    if (map is! Map<String, dynamic>) {
      throw FormatException('Invalid additions for ${mapEntry.key}.');
    }
    for (final scope in const ['shared', 'attack', 'defense']) {
      final entries = map[scope] ?? const [];
      if (entries is! List) throw FormatException('$scope must be a list.');
      for (final entry in entries) {
        if (entry is! Map<String, dynamic> ||
            entry['id'] is! String ||
            !RegExp(
              r'^[a-z0-9][a-z0-9_-]{1,63}$',
            ).hasMatch(entry['id'] as String) ||
            entry['label'] is! String ||
            entry['closed'] is! bool ||
            entry['points'] is! List) {
          throw FormatException('Invalid $scope boundary addition.');
        }
        final scopedId = '${mapEntry.key}:$scope:${entry['id']}';
        if (!seenIds.add(scopedId)) {
          throw FormatException('Duplicate boundary id ${entry['id']}.');
        }
        final points = entry['points'] as List;
        final minimum = entry['closed'] == true ? 3 : 2;
        if (points.length < minimum ||
            points.any(
              (point) =>
                  point is! List ||
                  point.length != 2 ||
                  point.any(
                    (coordinate) =>
                        coordinate is! num || coordinate < 0 || coordinate > 1,
                  ),
            )) {
          throw FormatException('Invalid points for ${entry['id']}.');
        }
      }
    }
  }
}

Future<void> _sendJson(HttpResponse response, Object value) async {
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(value));
  await response.close();
}

Future<void> _sendFile(
  HttpResponse response,
  File file,
  String contentType,
) async {
  response.headers.set(HttpHeaders.contentTypeHeader, contentType);
  await response.addStream(file.openRead());
  await response.close();
}

String _join(String left, String right) =>
    '$left${Platform.pathSeparator}${right.replaceAll('/', Platform.pathSeparator)}';
