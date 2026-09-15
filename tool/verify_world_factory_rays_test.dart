import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

class _WorldBundle extends CachingAssetBundle {
  _WorldBundle(this.directory);
  final String directory;

  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
      await File('$directory/${key.split('/').last}').readAsBytes());
}

/// Local integration audit, using independent material-aware 3D source rays.
/// Source disagreement is reported for offline refinement, not hidden by an
/// assertion threshold. Structural, projection, and polygon regressions fail.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('automatic world factory matches independent standing source rays',
      () async {
    const directory = String.fromEnvironment('WORLD_DIRECTORY');
    const referenceDirectory = String.fromEnvironment('REFERENCE_DIRECTORY');
    const mapName = String.fromEnvironment('WORLD_MAP', defaultValue: 'split');
    const binary = bool.fromEnvironment('WORLD_BINARY', defaultValue: true);
    const chunked = bool.fromEnvironment('WORLD_CHUNKED');
    const validateAllChunks = bool.fromEnvironment('WORLD_VALIDATE_ALL_CHUNKS');
    const outputDirectory = String.fromEnvironment('WORLD_OUTPUT_DIRECTORY',
        defaultValue: 'build/vision-audit');
    final map = MapValue.values.byName(mapName);
    final references = jsonDecode(
            await File('$referenceDirectory/$mapName.json').readAsString())
        as Map<String, dynamic>;
    expect(references['map'], mapName);
    final originalRss = ProcessInfo.currentRss;
    final watch = Stopwatch()..start();
    final geometry = await loadWorldViewConeGeometry(map,
        bundle: _WorldBundle(directory), binary: binary, chunked: chunked);
    final loadMicros = watch.elapsedMicroseconds;
    final rssAfterLoad = ProcessInfo.currentRss;
    if (validateAllChunks) geometry.worldData!.validateAllChunks();
    final origins = {
      for (final origin in references['origins'] as List)
        origin['id'] as int: origin as Map<String, dynamic>
    };
    final rejectedOrigins = <int>{};
    final otherFloorOrigins = <int>{};
    final unexplainedFloorOrigins = <int>{};
    final otherFloorDetails = <int, Map<String, dynamic>>{};
    final comparedOrigins = <int>{};
    final errors = <double>[];
    final certainErrors = <double>[];
    final exactHeightErrors = <double>[];
    final planeErrors = <double>[];
    final planeOutliers = <Map<String, dynamic>>[];
    final planeMismatches = <Map<String, dynamic>>[];
    final outliers = <Map<String, dynamic>>[];
    final coldLayerMicros = <int>[];
    final knownLayers = <double>{};
    final polygonMicros = <int>[];
    final polygonBoundaryErrors = <double>[];
    final polygonBoundaryOutliers = <Map<String, dynamic>>[];
    var polygonSample = -1;
    List<Offset>? sampledPolygon;
    var maximumMirrorError = 0.0;
    var maximumPolygonCenterError = 0.0;
    var planeMatches = 0;
    Offset project(List uv) => VisionGeometryMap.projectUv(
        map, Offset((uv[0] as num).toDouble(), (uv[1] as num).toDouble()));
    Offset flip(Offset point) =>
        Offset(1000 * 16 / 9 - point.dx, 1000 - point.dy);

    for (final ray in references['rays'] as List) {
      final sample = ray['sample'] as int;
      final originMetadata = origins[sample]!;
      final origin = project(ray['startUv'] as List);
      final end = project(ray['endUv'] as List);
      final selectedHeight =
          geometry.inferredHeightAt(isAttack: true, position: origin);
      final sourceHeight = (ray['startMeters'][2] as num).toDouble() * 100;
      if (selectedHeight == null) {
        rejectedOrigins.add(sample);
        continue;
      }
      if ((selectedHeight - sourceHeight).abs() > .01) {
        otherFloorOrigins.add(sample);
        final alternatives = originMetadata['floorAlternatives'];
        final matchesAlternative = alternatives is List &&
            alternatives.any((alternative) =>
                alternative is Map &&
                alternative['floorHeightCm'] is num &&
                ((alternative['floorHeightCm'] as num).toDouble() +
                            geometry.worldData!.observerHeightCm -
                            selectedHeight)
                        .abs() <=
                    .01);
        if (!matchesAlternative) unexplainedFloorOrigins.add(sample);
        otherFloorDetails[sample] = {
          'origin': sample,
          'selectedEyeHeightCm': selectedHeight,
          'referenceEyeHeightCm': sourceHeight,
          'matchesSourceFloorAlternative': matchesAlternative,
        };
        continue;
      }
      comparedOrigins.add(sample);
      watch.reset();
      final layer = geometry.layerForPosition(isAttack: true, position: origin);
      if (knownLayers.add(layer.elevation))
        coldLayerMicros.add(watch.elapsedMicroseconds);
      expect(layer.contains(origin), isTrue);
      final projection = layer.worldProjection!;
      final metricOrigin = projection.toMeters(origin);
      final vector = projection.vectorToMeters(end - origin);
      final range = math.min(
          vector.distance, layer.metricLayer!.maximumRange ?? double.infinity);
      final direction = vector / vector.distance;
      final distance = layer.metricLayer!.worldIndex!.nearestHit(
              origin: metricOrigin, direction: direction, range: range) ??
          range;
      // Probe the polygon between its authored angular events as well as its
      // center ray. The range-circle chords may differ by less than 2 cm.
      if (sample % 8 == 0) {
        if (polygonSample != sample) {
          polygonSample = sample;
          sampledPolygon = VisionPolygon.compute(
              layer: layer.metricLayer!,
              origin: metricOrigin,
              facingAngle: 0,
              coneAngle: 2 * math.pi,
              range: range);
        }
        final polygonDistance = _polygonRayDistance(
            sampledPolygon!, metricOrigin, direction, range);
        polygonBoundaryErrors.add((polygonDistance - distance).abs());
        if ((polygonDistance - distance).abs() >= .02) {
          polygonBoundaryOutliers.add({
            'ray': ray['id'],
            'elevationCm': layer.elevation,
            'originMeters': [metricOrigin.dx, metricOrigin.dy],
            'direction': [direction.dx, direction.dy],
            'rangeMeters': range,
            'rayDistanceMeters': distance,
            'polygonDistanceMeters': polygonDistance,
            'pointsMeters': [
              for (final point in sampledPolygon) [point.dx, point.dy]
            ],
          });
        }
      }
      final referenceDistance =
          math.min((ray['distanceMeters'] as num).toDouble(), range);
      final error = (distance - referenceDistance).abs();
      final planeReference = ray['planeReference'];
      final planeHeight = ray['planeElevationCm'];
      if (planeReference is Map && planeHeight is num) {
        if ((layer.elevation - planeHeight).abs() <= .01) {
          final referencePlaneDistance = math.min(
              (planeReference['distanceMeters'] as num).toDouble(), range);
          final planeError = (distance - referencePlaneDistance).abs();
          planeErrors.add(planeError);
          if (planeError > .02) {
            planeOutliers.add({
              'ray': ray['id'],
              'errorMeters': planeError,
              'elevationCm': layer.elevation,
              'referenceDistanceMeters': referencePlaneDistance,
              'bakedDistanceMeters': distance,
              'materialCertain': planeReference['materialCertain']
            });
          }
        } else {
          planeMismatches.add({
            'ray': ray['id'],
            'referencePlaneCm': planeHeight,
            'bakedPlaneCm': layer.elevation
          });
        }
      }
      errors.add(error);
      if (ray['materialCertain'] == true &&
          originMetadata['floorAgreesWithin1Cm'] == true) {
        certainErrors.add(error);
      }
      final exactHeight = (layer.elevation - sourceHeight).abs() <= .01;
      if (exactHeight) {
        planeMatches++;
        exactHeightErrors.add(error);
      }
      if (error > .02) {
        outliers.add({
          'ray': ray['id'],
          'errorMeters': error,
          'referenceDistanceMeters': referenceDistance,
          'bakedDistanceMeters': distance,
          'eyeHeightCm': sourceHeight,
          'bakedHeightCm': layer.elevation,
          'exactHeight': exactHeight,
          'materialCertain': ray['materialCertain'],
          'floorAgreesWithin1Cm': originMetadata['floorAgreesWithin1Cm'],
        });
      }

      if (sample % 32 == 0 && (ray['id'] as String).endsWith('-0')) {
        final defenseOrigin = flip(origin);
        final defense =
            geometry.layerForPosition(isAttack: false, position: defenseOrigin);
        expect(defense.elevation, layer.elevation);
        final defenseMetricOrigin =
            defense.worldProjection!.toMeters(defenseOrigin);
        final defenseVector =
            defense.worldProjection!.vectorToMeters(flip(end) - defenseOrigin);
        final defenseDistance = defense.metricLayer!.worldIndex!.nearestHit(
                origin: defenseMetricOrigin,
                direction: defenseVector / defenseVector.distance,
                range: range) ??
            range;
        maximumMirrorError =
            math.max(maximumMirrorError, (defenseDistance - distance).abs());
        watch.reset();
        final points = VisionPolygon.compute(
            layer: layer,
            origin: origin,
            facingAngle: math.atan2((end - origin).dy, (end - origin).dx),
            coneAngle: 103 * math.pi / 180,
            range: (end - origin).distance);
        polygonMicros.add(watch.elapsedMicroseconds);
        final centerVertices = points
            .skip(1)
            .map(projection.toMeters)
            .map((point) => point - metricOrigin)
            .where((delta) =>
                visionCross(delta, direction).abs() < 1e-7 &&
                delta.dx * direction.dx + delta.dy * direction.dy >= 0);
        expect(centerVertices, isNotEmpty);
        final centerError = centerVertices
            .map((delta) => (delta.distance - distance).abs())
            .reduce(math.min);
        maximumPolygonCenterError =
            math.max(maximumPolygonCenterError, centerError);
      }
    }
    Map<String, dynamic> stats(List<double> values) {
      if (values.isEmpty) return {'count': 0};
      values.sort();
      double percentile(double p) => values[((values.length - 1) * p).round()];
      return {
        'count': values.length,
        'within2Cm': values.where((x) => x <= .02).length,
        'within10Cm': values.where((x) => x <= .1).length,
        'medianMeters': percentile(.5),
        'p95Meters': percentile(.95),
        'p99Meters': percentile(.99),
        'maximumMeters': values.last
      };
    }

    final result = {
      'map': mapName,
      'source': directory,
      'referenceSource': referenceDirectory,
      'referenceFingerprints': references['source'],
      'binary': binary,
      'loadMicros': loadMicros,
      'processRssBeforeLoadBytes': originalRss,
      'processRssAfterLoadBytes': rssAfterLoad,
      'processRssAfterQueriesBytes': ProcessInfo.currentRss,
      'origins': origins.length,
      'comparedOrigins': comparedOrigins.length,
      'outsideNavigationOrigins': rejectedOrigins.toList()..sort(),
      'differentSelectedFloorOrigins': otherFloorOrigins.toList()..sort(),
      'differentSelectedFloorDetails': otherFloorDetails.values.toList(),
      'unexplainedSelectedFloorOrigins': unexplainedFloorOrigins.toList()
        ..sort(),
      'validatedAllChunks': validateAllChunks,
      'allComparedRays': stats(errors),
      'certainMaterialAndFloorRays': stats(certainErrors),
      'exactHeightRays': stats(exactHeightErrors),
      'samePlane3dReferenceRays': stats(planeErrors),
      'differentSelectedPlaneRays': planeMismatches,
      'planeOutliersAbove2Cm': planeOutliers,
      'residentChunkBlocks': geometry.worldData!.residentChunks.blocks,
      'residentChunkBytes': geometry.worldData!.residentChunks.bytes,
      'exactPlaneMatches': planeMatches,
      'maximumDefenseDistanceErrorMeters': maximumMirrorError,
      'maximumPolygonCenterErrorMeters': maximumPolygonCenterError,
      'polygonBoundaryAgainstExactRays': stats(polygonBoundaryErrors),
      'polygonBoundaryOutliers': polygonBoundaryOutliers,
      'coldLayerMicros': coldLayerMicros,
      'polygonMicros': polygonMicros,
      'outliersAbove2Cm': outliers,
      'profile':
          'Flutter test JIT; source-scene comparison, not live gameplay certification',
    };
    final output = File('$outputDirectory/$mapName-factory-rays.json');
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(jsonEncode(result));
    // ignore: avoid_print
    print(jsonEncode(Map.of(result)
      ..remove('outliersAbove2Cm')
      ..remove('polygonBoundaryOutliers')
      ..remove('planeOutliersAbove2Cm')));
    expect(comparedOrigins, isNotEmpty);
    expect(unexplainedFloorOrigins, isEmpty);
    expect(maximumMirrorError, lessThan(1e-6));
    expect(maximumPolygonCenterError, lessThan(1e-6));
    expect(polygonBoundaryErrors, isNotEmpty);
    expect(polygonBoundaryErrors.reduce(math.max), lessThan(.02));
  }, timeout: const Timeout(Duration(minutes: 10)));
}

double _polygonRayDistance(
    List<Offset> points, Offset origin, Offset direction, double range) {
  var nearest = range;
  for (var index = 1; index + 1 < points.length; index++) {
    final start = points[index] - origin;
    final edge = points[index + 1] - points[index];
    final denominator = visionCross(direction, edge);
    if (denominator.abs() <= 1e-12) continue;
    final distance = visionCross(start, edge) / denominator;
    final position = visionCross(start, direction) / denominator;
    if (distance > 1e-9 &&
        distance < nearest &&
        position >= -1e-9 &&
        position <= 1 + 1e-9) {
      nearest = distance;
    }
  }
  return nearest;
}
