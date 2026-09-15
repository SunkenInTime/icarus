import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

void main() {
  const root = String.fromEnvironment('FLOOR_AUDIT_ROOT');
  const mapFilter = String.fromEnvironment('FLOOR_AUDIT_MAPS');
  test('detailed runtime floors reproduce independent interior reference casts',
      () {
    expect(root, isNotEmpty);
    final requested =
        mapFilter.isEmpty ? <String>{} : mapFilter.split(',').toSet();
    final maps = MapValue.values
        .where((map) => requested.isEmpty || requested.contains(map.name))
        .toList();
    expect(maps, isNotEmpty);
    expect(requested.difference(maps.map((map) => map.name).toSet()), isEmpty);
    final reports = <Map<String, Object>>[];
    for (final map in maps) {
      final referenceFile =
          File('$root/nav/${map.name}-floor-interpolation-audit.json');
      final detailFile = File('$root/world/${map.name}/floor-mesh.json');
      if (!referenceFile.existsSync() || !detailFile.existsSync()) continue;
      Map<String, dynamic> read(String path) =>
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      final raw = read('$root/nav/baked/${map.name}_navigation.json');
      final refined = read('$root/world/${map.name}/floor-refinement.json');
      raw['refinedFloorHeightsCm'] = refined['refinedFloorHeightsCm'];
      raw['floorMesh'] = read(detailFile.path)['floorMesh'];
      final watch = Stopwatch()..start();
      final navigation = NavigationGeometry.fromJson(raw,
          projectUv: (uv) => VisionGeometryMap.projectUv(map, uv));
      final loadUs = watch.elapsedMicroseconds;
      final ui =
          read('$root/world/${map.name}/geometry.json')['uiTransform'] as Map;
      final errors = <double>[];
      final times = <int>[];
      final differences = <Map<String, Object>>[];
      var edgeAmbiguities = 0;
      var excludedNonStanding = 0;
      for (final sample in read(referenceFile.path)['samples'] as List) {
        if (!(raw['walkable'] as List)[sample['polygon'] as int]) {
          excludedNonStanding++;
          continue;
        }
        if (sample['category'] != 'opaque' || sample['measuredZCm'] == null)
          continue;
        final xyz = (sample['originWorldCm'] as List).cast<num>();
        final uv = Offset(
            (xyz[1] * ui['XMultiplier'] + ui['XScalarToAdd']).toDouble(),
            (xyz[0] * ui['YMultiplier'] + ui['YScalarToAdd']).toDouble());
        final position = VisionGeometryMap.projectUv(map, uv);
        final expected = (sample['measuredZCm'] as num).toDouble();
        watch.reset();
        final actual =
            navigation.floorHeightAt(position, preferredElevation: expected);
        times.add(watch.elapsedMicroseconds);
        expect(actual, isNotNull);
        final error = (actual! - expected).abs();
        errors.add(error);
        if (error > 1) {
          final range =
              (sample['floorRangeWithin0_01cmCm'] as List?)?.cast<num>();
          final ambiguous = range != null &&
              range.last - range.first > 1 &&
              actual >= range.first - 1 &&
              actual <= range.last + 1;
          if (ambiguous) edgeAmbiguities++;
          differences.add({
            'triangle': sample['triangle'] as int,
            'expected': expected,
            'actual': actual,
            'errorCm': error,
            'edgeAmbiguousWithin0_01cm': ambiguous,
          });
        }
      }
      errors.sort();
      times.sort();
      final report = <String, Object>{
        'map': map.name,
        'samples': errors.length,
        'excludedNonStandingSources': excludedNonStanding,
        'p50ErrorCm': errors[errors.length ~/ 2],
        'p95ErrorCm': errors[(errors.length * .95).floor()],
        'p99ErrorCm': errors[(errors.length * .99).floor()],
        'maxErrorCm': errors.last,
        'over1cm': differences.length,
        'edgeAmbiguities': edgeAmbiguities,
        'unexplainedOver1cm': differences.length - edgeAmbiguities,
        'loadUs': loadUs,
        'p95LookupUs': times[(times.length * .95).floor()],
        'differences': differences
      };
      reports.add(report);
      // ignore: avoid_print
      print(jsonEncode({...report}..remove('differences')));
    }
    File('$root/nav/detailed-floor-runtime-audit.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(reports));
    expect(reports.length, maps.length);
    expect(reports.every((report) => report['unexplainedOver1cm'] == 0), isTrue,
        reason: 'Interior precision failures are recorded in the audit JSON.');
  });
}
