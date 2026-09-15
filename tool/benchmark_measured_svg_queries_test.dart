import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('measure automatic selection and native queries at source placements',
      () async {
    final root = Platform.environment['ICARUS_MEASURED_BENCHMARK']!;
    final fixturePath = Platform.environment['ICARUS_REGIONAL_FIXTURE']!;
    final library = Platform.environment['ICARUS_SVG_NATIVE_LIBRARY']!;
    final fixture = jsonDecode(File(fixturePath).readAsStringSync());
    final mapName = fixture['map'] as String? ?? 'icebox';
    final placements = fixture['defaultPlacements'] as List;
    final sampleStride = int.parse(
        Platform.environment['ICARUS_QUERY_SAMPLE_STRIDE'] ?? '7');
    expect(sampleStride, greaterThan(0));
    final rows = <Map<String, Object?>>[];
    Future<String> hash(String path) async =>
        (await Sha256().hash(File(path).readAsBytesSync()))
            .bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
    for (final side in ['attack', 'defense']) {
      final path = 'assets/maps/${mapName}_svg_height_$side.json.gz';
      final bytes = File(path).readAsBytesSync();
      final loading = Stopwatch()..start();
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(bytes))));
      expect(model.enableNativeAcceleration(libraryPath: library), isTrue);
      loading.stop();
      final points = <Offset>[];
      for (var i = 0; i < placements.length; i += sampleStride) {
        final xy = placements[i]['svg'][side] as List;
        final point =
            Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
        if (model.receiverContains(point) &&
            model.ground!.heightAt(point) != null) {
          points.add(point);
        }
      }
      expect(points.length, greaterThan(100));
      final times = <int>[];
      var vertices = 0;
      for (var pass = 0; pass < 3; pass++) {
        for (var i = 0; i < points.length; i++) {
          final watch = Stopwatch()..start();
          final support = model.standingSupportAt(points[i]);
          final cone = model.cone(
              origin: points[i],
              directionRadians: i * math.pi / 2,
              range: 90,
              apertureRadians: math.pi / 2,
              supportId: support?.id);
          watch.stop();
          vertices += cone.polygon.length;
          if (pass > 0) times.add(watch.elapsedMicroseconds);
        }
      }
      expect(vertices, greaterThan(points.length * 3));
      times.sort();
      rows.add({
        'side': side,
        'assetSha256': await hash(path),
        'compressedBytes': bytes.length,
        'loadAndNativeSetupMicros': loading.elapsedMicroseconds,
        'sourcePlacements': points.length,
        'measuredQueries': times.length,
        'medianMicros': times[times.length ~/ 2],
        'p95Micros': times[(times.length * .95).floor()],
        'maximumMicros': times.last,
      });
      model.closeNativeAcceleration();
    }
    final result = {
      'map': mapName,
      'scope': 'Flutter test process. Timings include automatic standing selection '
          'and the compiled Windows native cone query. One warmup pass and two '
          'measured passes at source placements inside the SVG. '
          'These are query costs, not desktop frame times.',
      'sourcePlacementStride': sampleStride,
      'fixtureSha256': await hash(fixturePath),
      'nativeSha256': await hash(library),
      'algorithmSha256':
          await hash('tool/benchmark_measured_svg_queries_test.dart'),
      'rows': rows,
    };
    File('$root/query-cost.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
    // ignore: avoid_print
    print(jsonEncode(result));
  });
}
