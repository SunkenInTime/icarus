// Run with flutter test tool/audit_vision_boundaries_test.dart.
// This exports diagnostics from the real asset loader. It does not certify
// agreement with live gameplay, and it never changes map assets.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

List<double> _point(Offset p) => [p.dx, p.dy];
List<List<double>> _segment(VisionSegment s) =>
    [_point(s.start), _point(s.end)];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('exports runtime boundary evidence for every map', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final output = Directory('build/vision-audit')..createSync(recursive: true);
    final summaries = <Map<String, dynamic>>[];
    const selected = String.fromEnvironment('VISION_MAP', defaultValue: 'all');
    for (final map in MapValue.values) {
      if (selected != 'all' && selected != map.name) continue;
      if (!Maps.hasVisionGeometry(map)) continue;
      final name = Maps.mapNames[map]!;
      final rawSource =
          await rootBundle.loadString('assets/maps/${name}_vision.json');
      final raw = VisionGeometryMap.fromCompactJson(
          map, jsonDecode(rawSource) as Map<String, dynamic>);
      final runtime =
          await container.read(viewConeGeometryProvider(map).future);
      expect(runtime, isNotNull,
          reason: 'Runtime loader failed for ${map.name}');
      final fingerprints = <String, String>{};
      for (final file in [
        '${name}_vision.json',
        '${name}_map.svg',
        '${name}_map_defense.svg',
        'vision_boundary_edits.json',
        'vision_boundary_additions.json',
        'vision_contour_overrides.json'
      ]) {
        final hash =
            await Sha256().hash(File('assets/maps/$file').readAsBytesSync());
        fingerprints[file] = hash.bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
      }
      final sides = <Map<String, dynamic>>[];
      for (final attack in [true, false]) {
        final layers = attack ? runtime!.attackLayers : runtime!.defenseLayers;
        final rawLayers = attack ? raw.attackLayers : raw.defenseLayers;
        final groups = layers.first.debugCollisionGroups;
        final groupReports = <Map<String, dynamic>>[];
        for (final group in groups) {
          final unsupportedLayers = [
            for (var i = 0; i < layers.length; i++)
              if (group.activeInLayer(i) && !group.hasEvidenceInLayer(i))
                layers[i].elevation
          ];
          final flags = <String>[];
          if (!group.isOuterBoundary && group.layerMask != 0) {
            if (group.evidenceLayerMask == 0)
              flags.add('active-without-contour-match');
            if (group.evidenceLayerMask != 0 && unsupportedLayers.isNotEmpty) {
              flags.add('active-beyond-matched-elevations');
            }
            if (group.observerExclusionLayerMask != 0)
              flags.add('observer-dependent-blocker');
          }
          groupReports.add({
            'id': group.id,
            'kind': group.kind.name,
            'outer': group.isOuterBoundary,
            'closed': group.isClosed,
            'bounds': [
              group.bounds.left,
              group.bounds.top,
              group.bounds.right,
              group.bounds.bottom
            ],
            'paths':
                group.paths.map((path) => path.map(_point).toList()).toList(),
            'perimeter': group.perimeter,
            'activeMask': group.layerMask,
            'evidenceMask': group.evidenceLayerMask,
            'observerExclusionMask': group.observerExclusionLayerMask,
            'coverageByLayer': group.coverageByLayer,
            'confidence': group.confidence.name,
            'overrideApplied': group.overrideApplied,
            'activeWithoutMatchAt': unsupportedLayers,
            'flags': flags,
          });
        }
        sides.add({
          'side': attack ? 'attack' : 'defense',
          'groups': groupReports,
          'layers': [
            for (var i = 0; i < layers.length; i++)
              {
                'elevation': layers[i].elevation,
                'runtimeSegments': layers[i].segments.map(_segment).toList(),
                'sourceSegments':
                    rawLayers[i].riotSegments.map(_segment).toList(),
                'unmatchedSourceCount': layers[i].rejectedSegments.length,
              }
          ],
        });
      }
      final attackGroups = sides.first['groups'] as List<Map<String, dynamic>>;
      final summary = <String, dynamic>{
        'map': map.name,
        'layers': runtime!.elevations,
        'groups': attackGroups.length,
        'observerHeight': runtime.observerHeight,
        'heightSampleCount': runtime.heightField?.samples.length ?? 0,
        'attackSegmentCounts':
            runtime.attackLayers.map((l) => l.segments.length).toList(),
        'distinctAttackSegmentSets': runtime.attackLayers
            .map((l) => jsonEncode(l.segments.map(_segment).toList()))
            .toSet()
            .length,
        'activeWithoutMatch': attackGroups
            .where((g) =>
                (g['flags'] as List).contains('active-without-contour-match'))
            .length,
        'activeBeyondMatchedElevations': attackGroups
            .where((g) => (g['flags'] as List)
                .contains('active-beyond-matched-elevations'))
            .length,
        'observerDependent': attackGroups
            .where((g) =>
                (g['flags'] as List).contains('observer-dependent-blocker'))
            .length,
      };
      summaries.add(summary);
      final report = {
        'schemaVersion': 1,
        'status': 'diagnostic-only',
        'independentlyVerifiedSightlines': 0,
        'limitations': [
          'Contour matches use the current UV projection; registration errors can create mismatches.',
          'Minimap contours are not player-camera visibility or a complete 3D collision mesh.',
          'Flags identify candidates, not confirmed gameplay bugs. Do not remove blockers automatically.',
          'Per-layer segments are before observer-specific exclusions.',
        ],
        'summary': summary,
        'sourceHashes': fingerprints,
        'sides': sides,
      };
      File('${output.path}/${map.name}.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(report));
      // Keep the console useful without dumping thousands of vertices.
      // ignore: avoid_print
      print(jsonEncode(summary));
    }
    expect(summaries, isNotEmpty, reason: 'Unknown VISION_MAP selection');
    File('${output.path}/summary.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(summaries));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
