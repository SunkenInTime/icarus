// A local browser workbench backed by the production Dart height selection and
// native SVG cone engine. Run through flutter test because the model uses ui.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

const maps = [
  'abyss',
  'ascent',
  'bind',
  'breeze',
  'corrode',
  'fracture',
  'haven',
  'icebox',
  'lotus',
  'pearl',
  'split',
  'summit',
  'sunset',
];

class ReviewModel {
  ReviewModel(this.data, this.model, this.artwork, this.revision);
  final Map<String, dynamic> data;
  final SvgHeightVisibility model;
  final String artwork;
  final Map<String, String> revision;
}

Future<String> hash(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

String cssColor(Color color) =>
    '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';

void main() {
  test('serve interactive sightline review', () async {
    final port =
        int.parse(Platform.environment['ICARUS_REVIEW_PORT'] ?? '8770');
    final dll = Platform.environment['ICARUS_SVG_NATIVE_LIBRARY']!;
    final output = Directory(Platform.environment['ICARUS_REVIEW_OUTPUT']!);
    await output.create(recursive: true);
    final nativeHash = await hash(await File(dll).readAsBytes());
    final loaded = <String, ReviewModel>{};
    final loading = <String, Future<ReviewModel>>{};

    Future<ReviewModel> load(String map, String side) {
      if (!maps.contains(map) || !['attack', 'defense'].contains(side)) {
        throw const FormatException('Unknown map or side.');
      }
      final key = '$map-$side';
      return loading.putIfAbsent(key, () async {
        final bytes = await File('assets/maps/${map}_svg_height_$side.json.gz')
            .readAsBytes();
        final art = await File(
                'assets/maps/${map}_map${side == 'defense' ? '_defense' : ''}.svg')
            .readAsBytes();
        final data =
            jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>;
        final model = SvgHeightVisibility.fromJson(data);
        if (!model.enableNativeAcceleration(libraryPath: dll)) {
          throw StateError(
              'The corrected native SVG engine could not be loaded.');
        }
        final result = ReviewModel(data, model, base64Encode(art), {
          'nativeSha256': nativeHash,
          'modelSha256': await hash(bytes),
          'artworkSha256': await hash(art),
        });
        loaded[key] = result;
        return result;
      });
    }

    Map<String, dynamic> query(ReviewModel source, Map<String, dynamic> pose) {
      final model = source.model;
      double number(String key, double fallback) {
        final value = pose[key] ?? fallback;
        if (value is! num || !value.isFinite)
          throw FormatException('Invalid $key.');
        return value.toDouble();
      }

      final xy = pose['origin'];
      if (xy is! List ||
          xy.length != 2 ||
          xy.any((v) => v is! num || !v.isFinite || v.abs() > 100000)) {
        throw const FormatException('Invalid observer position.');
      }
      final point =
          Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
      final supports = model.supportsAt(point);
      final supportId = pose['supportId'] as String?;
      final requested =
          supportId != null && supports.any((s) => s.id == supportId)
              ? supportId
              : null;
      final surfaceMode =
          pose['surfaceMode'] ?? (requested == null ? 'auto' : 'support');
      if (!['auto', 'ground', 'support'].contains(surfaceMode)) {
        throw const FormatException('Unknown standing surface mode.');
      }
      final automatic = model.automaticSupportAt(point);
      final selected = surfaceMode == 'ground'
          ? null
          : surfaceMode == 'support' && requested != null
              ? requested
              : automatic?.id;
      final floor = model.ground?.heightAt(point);
      final result = <String, dynamic>{
        'id': pose['id'],
        'origin': xy,
        'supportId': surfaceMode == 'support' ? requested : null,
        'resolvedSupportId': selected,
        'automaticSupportLabel': automatic?.label ?? 'Ground',
        'floorMeters': floor,
        'eyeMeters': null,
        'polygon': <dynamic>[],
        'activeWallIds': <String>[],
        'supports': [
          for (final s in supports)
            {
              'id': s.id,
              'label': s.label ?? 'Raised surface',
              'surfaceMeters': s.surfaceElevationAt(point),
              'heightAboveFloorMeters': s.heightAboveFloorMeters,
              'automaticStandingAllowed': s.automaticStandingAllowed,
            }
        ],
        'status': 'ready',
      };
      if (!model.receiverContains(point) ||
          (floor == null && selected == null)) {
        result['status'] = 'Place the observer on the map floor.';
        return result;
      }
      final range = number('range', 90);
      final aperture = number('aperture', math.pi / 2);
      if (range < 1 ||
          range > 500 ||
          aperture < .05 ||
          aperture > math.pi * 2) {
        throw const FormatException(
            'Cone range or angle is outside the review limits.');
      }
      final cone = model.cone(
          origin: point,
          directionRadians: number('direction', 0),
          range: range,
          apertureRadians: aperture,
          supportId: selected);
      result['polygon'] = [
        for (final p in cone.polygon) [p.dx, p.dy]
      ];
      result['eyeMeters'] = cone.eyeElevationMeters;
      result['activeWallIds'] = [
        for (final wall in model.walls)
          if (wall.blocks(cone.eyeElevationMeters!)) wall.id
      ];
      if (cone.polygon.length < 3)
        result['status'] = 'Observer is inside a blocking wall.';
      return result;
    }

    Future<Map<String, dynamic>> body(HttpRequest request) async {
      final chunks = <int>[];
      await for (final chunk in request) {
        chunks.addAll(chunk);
        if (chunks.length > 12 * 1024 * 1024)
          throw const FormatException('Review is too large.');
      }
      final value = jsonDecode(utf8.decode(chunks));
      if (value is! Map<String, dynamic>)
        throw const FormatException('Expected a JSON object.');
      return value;
    }

    Future<void> json(HttpResponse response, Object value) async {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(value));
      await response.close();
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(() async {
      await server.close(force: true);
      for (final source in loaded.values)
        source.model.closeNativeAcceleration();
    });
    stdout.writeln('ICARUS_REVIEW_READY http://127.0.0.1:$port');
    stdout.writeln('Review files: ${output.path}');
    await for (final request in server) {
      try {
        final response = request.response;
        response.headers.set('Cache-Control', 'no-store');
        response.headers.set('X-Content-Type-Options', 'nosniff');
        final route = request.uri.path;
        if (request.method == 'POST') {
          // Browsers may save only through this review origin, including Serve.
          final origin = request.headers.value('origin');
          if (origin != null &&
              Uri.parse(origin).authority != request.headers.value('host')) {
            response.statusCode = HttpStatus.forbidden;
            await json(response, {'error': 'Review origin does not match.'});
            continue;
          }
        }
        if (request.method == 'GET' &&
            ['/', '/app.js', '/style.css'].contains(route)) {
          final name = route == '/' ? 'index.html' : route.substring(1);
          response.headers.contentType =
              ContentType.parse(name.endsWith('.html')
                  ? 'text/html; charset=utf-8'
                  : name.endsWith('.js')
                      ? 'text/javascript; charset=utf-8'
                      : 'text/css; charset=utf-8');
          response
              .write(await File('tool/sightline_review/$name').readAsString());
          await response.close();
        } else if (request.method == 'GET' && route == '/api/config') {
          const theme = Settings.tacticalVioletTheme;
          await json(response, {
            'maps': maps,
            'nativeSha256': nativeHash,
            'colors': {
              'bg': cssColor(theme.background),
              'panel': cssColor(theme.card),
              'raised': cssColor(theme.secondary),
              'text': cssColor(theme.foreground),
              'muted': cssColor(theme.mutedForeground),
              'line': cssColor(theme.border),
              'accent': cssColor(theme.primary),
              'ally': cssColor(Settings.allyBGColor),
              'ink': cssColor(theme.foreground),
            }
          });
        } else if (request.method == 'GET' && route == '/api/model') {
          final map = request.uri.queryParameters['map'] ?? 'icebox';
          final side = request.uri.queryParameters['side'] ?? 'attack';
          final source = await load(map, side);
          final box = (source.data['viewBox'] as List).cast<num>();
          List<num> initial = map == 'icebox' && side == 'attack'
              ? [94, 291]
              : [box[0] + box[2] / 2, box[1] + box[3] / 2];
          bool valid(List<num> xy) =>
              query(source, {'origin': xy})['status'] == 'ready';
          if (!valid(initial)) {
            search:
            for (var y = box[1] + 8; y < box[1] + box[3]; y += 12) {
              for (var x = box[0] + 8; x < box[0] + box[2]; x += 12) {
                if (valid([x, y])) {
                  initial = [x, y];
                  break search;
                }
              }
            }
          }
          await json(response, {
            'map': map,
            'side': side,
            'viewBox': box,
            'receiver': source.data['receiver'],
            'walls': source.data['walls'],
            'artwork': 'data:image/svg+xml;base64,${source.artwork}',
            'initial': initial,
            'revision': source.revision,
          });
        } else if (request.method == 'POST' && route == '/api/query') {
          final data = await body(request);
          final source =
              await load(data['map'] as String, data['side'] as String);
          final cones = data['cones'];
          if (cones is! List || cones.length > 10)
            throw const FormatException('At most ten cones.');
          await json(response, {
            'cones': [
              for (final pose in cones)
                query(source, pose as Map<String, dynamic>)
            ]
          });
        } else if (request.method == 'POST' && route == '/api/reviews') {
          final data = await body(request);
          final source =
              await load(data['map'] as String, data['side'] as String);
          final cones = data['cones'];
          if (cones is! List ||
              cones.isEmpty ||
              cones.length > 10 ||
              data['annotations'] is! List ||
              (data['annotations'] as List).length > 2000 ||
              data['note'] is! String ||
              (data['note'] as String).length > 20000) {
            throw const FormatException('Invalid review state.');
          }
          final png = data.remove('screenshotPng');
          List<int>? screenshot;
          if (png != null) {
            if (png is! String || !png.startsWith('data:image/png;base64,')) {
              throw const FormatException('Expected a PNG screenshot.');
            }
            screenshot = base64Decode(png.substring(22));
            if (screenshot.length < 8 ||
                base64Encode(screenshot.sublist(0, 8)) != 'iVBORw0KGgo=') {
              throw const FormatException('Invalid PNG screenshot.');
            }
          }
          final id =
              '${DateTime.now().toUtc().millisecondsSinceEpoch}-${math.Random.secure().nextInt(0x7fffffff).toRadixString(16)}';
          final record = {
            ...data,
            'version': 1,
            'id': id,
            'savedAt': DateTime.now().toUtc().toIso8601String(),
            'revision': source.revision,
            'computed': [
              for (final pose in cones)
                query(source, pose as Map<String, dynamic>)
            ],
          };
          // Each save gets a new file. An existing note is never overwritten.
          if (screenshot != null)
            await File('${output.path}/$id.png')
                .writeAsBytes(screenshot, flush: true);
          await File('${output.path}/$id.json')
              .writeAsString(jsonEncode(record), flush: true);
          await json(response,
              {'id': id, 'url': '/?review=$id', 'savedAt': record['savedAt']});
        } else if (request.method == 'GET' &&
            RegExp(r'^/api/reviews/[0-9]+-[0-9a-f]+$').hasMatch(route)) {
          final file = File('${output.path}/${route.split('/').last}.json');
          if (!await file.exists()) {
            response.statusCode = 404;
            await json(response, {'error': 'Review not found.'});
          } else {
            response.headers.contentType = ContentType.json;
            response.write(await file.readAsString());
            await response.close();
          }
        } else {
          response.statusCode = 404;
          await json(response, {'error': 'Not found.'});
        }
      } catch (error, stack) {
        stderr.writeln('$error\n$stack');
        request.response.statusCode = 400;
        await json(request.response, {'error': '$error'});
      }
    }
  },
      timeout: const Timeout(Duration(days: 7)),
      skip: Platform.environment['ICARUS_REVIEW_OUTPUT'] == null
          ? 'Set ICARUS_REVIEW_OUTPUT to start the local review server.'
          : false);
}
