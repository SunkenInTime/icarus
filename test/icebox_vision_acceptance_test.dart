import 'dart:convert';
import 'dart:io';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

Map<String, dynamic> _fixture() => jsonDecode(
    File('test/fixtures/icebox_vision_acceptance.json').readAsStringSync());

Map<String, dynamic> _asset(String side) => jsonDecode(utf8.decode(gzip.decode(
    File('assets/maps/icebox_svg_height_$side.json.gz').readAsBytesSync())));

List<Map<String, dynamic>> _check(
    Map<String, dynamic> fixture, Map<String, dynamic> data, String side) {
  final model = SvgHeightVisibility.fromJson(data);
  final tolerance = (fixture['heightToleranceMeters'] as num).toDouble();
  final rows = <Map<String, dynamic>>[];
  for (final row in fixture['cases'] as List) {
    final xy = row['svg'][side] as List;
    final p = Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
    final expected = (row['expectedFloorMeters'] as num).toDouble();
    final ground = model.ground?.heightAt(p);
    final levels = <double>[
      if (ground != null) ground,
      for (final support in model.supportsAt(p))
        if (support.automaticStandingAllowed &&
            support.surfaceElevationAt(p) != null)
          support.surfaceElevationAt(p)!,
    ];
    final support = model.standingSupportAt(p);
    final actual = support?.surfaceElevationAt(p) ?? ground;
    final present = levels.any((z) => (z - expected).abs() <= tolerance);
    final automatic = row['selection'] == 'automatic';
    rows.add({
      'id': row['id'],
      'side': side,
      'expectedFloorMeters': expected,
      'actualAutomaticFloorMeters': actual,
      'levelPresent': present,
      'insideReceiver': model.receiverContains(p),
      'passed': present &&
          (!automatic ||
              actual != null && (actual - expected).abs() <= tolerance),
    });
  }
  return rows;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = _fixture();
  for (final side in ['attack', 'defense']) {
    test('Icebox $side reported defaults match independent source heights', () {
      final rows = _check(fixture, _asset(side), side);
      final required = rows.where((r) =>
          r['id'] == 'top-screens-reported' ||
          r['id'] == 'lower-pipe-reported');
      expect(required.length, 2);
      expect(required.where((r) => r['passed'] != true), isEmpty);
    });

    test('Icebox $side source-domain audit retains every expected position',
        () async {
      final rows = _check(fixture, _asset(side), side);
      // This is an audit export. Unresolved domain differences are retained,
      // rather than dropped or turned into a passing region-wide verdict.
      expect(rows.length, (fixture['cases'] as List).length);
      final failures = rows.where((r) => r['passed'] != true).toList();
      final hash = await Sha256().hash(
          File('assets/maps/icebox_svg_height_$side.json.gz')
              .readAsBytesSync());
      final fixtureHash = await Sha256().hash(
          File('test/fixtures/icebox_vision_acceptance.json')
              .readAsBytesSync());
      final output = Directory('work/icebox-acceptance')
        ..createSync(recursive: true);
      File('${output.path}/runtime-$side.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'scope': 'Source-defined Screens domain and reviewed local pipe pose',
        'sourceFixtureSha256': fixtureHash.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        'assetSha256':
            hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'status': failures.isEmpty ? 'passed' : 'unresolved-domain-differences',
        'cases': rows.length,
        'failures': failures,
        'rows': rows,
      }));
    });

    for (final fault in ['remove-required-floor', 'wrong-local-height']) {
      test('Icebox $side unchanged expectations detect $fault', () {
        final data = _asset(side);
        final row = (fixture['cases'] as List)
            .singleWhere((r) => r['id'] == 'top-screens-reported');
        final xy = row['svg'][side] as List;
        final p = Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
        final original = SvgHeightVisibility.fromJson(data);
        final requiredIds = original
            .supportsAt(p)
            .where((s) => ((s.surfaceElevationAt(p) ?? -1000) - 7).abs() < .02)
            .map((s) => s.id)
            .toSet();
        expect(requiredIds, isNotEmpty);
        final supports = data['supports'] as List;
        if (fault == 'remove-required-floor') {
          supports.removeWhere((s) => requiredIds.contains(s['id']));
        } else {
          for (final support in supports) {
            if (!requiredIds.contains(support['id'])) continue;
            support['surfaceElevationMeters'] += 1;
            support['heightAboveFloorMeters'] += 1;
            if (support['surfacePlane'] != null)
              support['surfacePlane'][2] += 1;
          }
        }
        final failures = _check(fixture, data, side).where(
            (r) => r['id'] == 'top-screens-reported' && r['passed'] != true);
        expect(failures, isNotEmpty,
            reason:
                'An omitted floor must fail even when no support remains to generate a test.');
      });
    }
  }
}
