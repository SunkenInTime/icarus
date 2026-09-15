// Offline, fixed-pose evidence. Never opens the user's library.
// flutter test --no-pub tool/export_visibility_audit_gallery_test.dart
// ICARUS_AUDIT_MAPS, ICARUS_AUDIT_OUTPUT, ICARUS_AUDIT_LIBRARY are env overrides.
// ICARUS_AUDIT_CANDIDATE optionally names JSON with maps -> map -> folder,
// library and queriesById. Only explicitly listed queries are candidate cases.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/height_native.dart';
import 'package:icarus/view_cone/height_render.dart';
import 'package:icarus/view_cone/receiver_compositor.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/tactical_ground_field.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

const _root = 'E:/IcarusWorldAudit/2026-09-06';
const _audit = '$_root/tactical-visibility-revision';
const _baseline = '$_audit/baseline-world';
const _pixelScale = 2.0;

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
      await File('$_baseline/${key.split('/').last}').readAsBytes());
}

Future<String> _sha(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

List<double> _xy(ui.Offset p) => [p.dx, p.dy];

VisionWorldProjection _fromRows(List rows) {
  expect(rows.length, 2);
  final x = (rows[0] as List).cast<num>();
  final y = (rows[1] as List).cast<num>();
  expect(x.length, 3);
  expect(y.length, 3);
  return VisionWorldProjection(
      origin: ui.Offset(x[2].toDouble(), y[2].toDouble()),
      axisU: ui.Offset(x[0].toDouble(), y[0].toDouble()),
      axisV: ui.Offset(x[1].toDouble(), y[1].toDouble()));
}

List<Map<String, dynamic>> _select(
    HeightAssets assets, NavigationGeometry nav, WorldReceiverMask mask) {
  final centers = [
    for (final p in nav.polygons)
      p.map((i) => nav.vertices[i].position).reduce((a, b) => a + b) /
          p.length.toDouble()
  ];
  final rows = <Map<String, dynamic>>[];
  final selected = <ui.Offset>[];
  bool admit(ui.Offset p) =>
      nav.floorHeightsAt(p).length == 1 &&
      mask.containsReceiver(assets.svgProjection.toCanvas(p));
  void add(String id, String category, ui.Offset p, ui.Offset d,
      Map<String, dynamic> details) {
    if (!admit(p) || d.distance < .001) return;
    d /= d.distance;
    final floor = nav.floorHeightsAt(p).single;
    final scale =
        (assets.projection.axisU * d.dx + assets.projection.axisV * d.dy)
            .distance;
    rows.add({
      'id': id,
      'category': category,
      'query': [
        p.dx,
        p.dy,
        (floor + 175) / 100,
        d.dx,
        d.dy,
        361 / scale,
        103 * math.pi / 180
      ],
      'originSvg': _xy(assets.svgProjection.toCanvas(p)),
      'floorCm': floor,
      ...details
    });
    selected.add(p);
  }

  final slopes = <({int a, int b, double delta})>[];
  for (final link in nav.links) {
    if (link.from >= link.to ||
        !admit(centers[link.from]) ||
        !admit(centers[link.to])) continue;
    final a = nav.floorHeightsAt(centers[link.from]).single;
    final b = nav.floorHeightsAt(centers[link.to]).single;
    if ((a - b).abs() < 10) continue;
    slopes.add((a: link.from, b: link.to, delta: (a - b).abs()));
  }
  slopes.sort((a, b) {
    final order = b.delta.compareTo(a.delta);
    return order == 0 ? a.a.compareTo(b.a) : order;
  });
  final used = <int>{};
  var count = 0;
  for (final s in slopes) {
    if (used.contains(s.a) || used.contains(s.b)) continue;
    if (selected.any((p) => (p - centers[s.a]).distance < 3)) continue;
    for (final (from, to, suffix) in [
      (s.a, s.b, 'forward'),
      (s.b, s.a, 'reverse')
    ]) {
      add('ramp-$count-$suffix', 'adjacent floor height change', centers[from],
          centers[to] - centers[from], {
        'parentPolygons': [from, to],
        'floorDifferenceCm': s.delta
      });
    }
    used.addAll([s.a, s.b]);
    if (++count == 3) break;
  }
  final corners = <({int polygon, int vertex, double angle})>[];
  for (var i = 0; i < nav.polygons.length; i++) {
    if (!nav.walkable[i] || !admit(centers[i])) continue;
    final p = nav.polygons[i];
    for (var j = 0; j < p.length; j++) {
      final at = nav.vertices[p[j]].position;
      final a = nav.vertices[p[(j + p.length - 1) % p.length]].position - at;
      final b = nav.vertices[p[(j + 1) % p.length]].position - at;
      if (a.distance * b.distance < .01) continue;
      final angle = math.acos(
          ((a.dx * b.dx + a.dy * b.dy) / (a.distance * b.distance))
              .clamp(-1.0, 1.0));
      corners.add((polygon: i, vertex: p[j], angle: angle));
    }
  }
  corners.sort((a, b) {
    final order = a.angle.compareTo(b.angle);
    return order == 0 ? a.polygon.compareTo(b.polygon) : order;
  });
  count = 0;
  for (final c in corners) {
    final p = centers[c.polygon];
    if (selected.any((other) => (p - other).distance < 6)) continue;
    add(
        'corner-$count',
        'sharp navigation corner',
        p,
        nav.vertices[c.vertex].position - p,
        {'parentPolygon': c.polygon, 'angleDegrees': c.angle * 180 / math.pi});
    if (++count == 3) break;
  }
  for (var i = 0; i < 3; i++) {
    var best = -1, distance = -1.0;
    for (var j = 0; j < centers.length; j++) {
      if (!nav.walkable[j] || !admit(centers[j])) continue;
      final nearest = selected.isEmpty
          ? 0.0
          : selected
              .map((p) => (p - centers[j]).distanceSquared)
              .reduce(math.min);
      if (nearest > distance) {
        best = j;
        distance = nearest;
      }
    }
    if (best < 0) break;
    final toward = centers.reduce((a, b) => a + b) / centers.length.toDouble();
    add('distributed-$i', 'farthest unselected floor region', centers[best],
        toward - centers[best], {'parentPolygon': best});
  }
  return rows;
}

Future<void> _png(
    String file, ui.Picture picture, int width, int height) async {
  final image = await picture.toImage(width, height);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(file).writeAsBytes(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> _render(
    String prefix,
    String source,
    WorldReceiverMask receiver,
    VisionWorldProjection projection,
    List<double> q,
    Float32List mesh,
    ui.FragmentProgram program,
    {DisplayWarp? displayWarp}) async {
  final artwork = await vg.loadPicture(SvgStringLoader(source), null);
  final origin = projection.toCanvas(ui.Offset(q[0], q[1]));
  final displayedOrigin = projection.toCanvas(
      displayWarp?.targetAt(ui.Offset(q[0], q[1])) ?? ui.Offset(q[0], q[1]));
  final cachedRenderer =
      displayWarp == null ? null : WorldHeightCachedRenderer();
  final width = (receiver.viewBox.width * _pixelScale).ceil();
  final height = (receiver.viewBox.height * _pixelScale).ceil();
  for (final kind in ['overlay', 'visibility', 'unclipped']) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..scale(_pixelScale);
    if (kind == 'overlay') {
      canvas.drawColor(const ui.Color(0xff101014), ui.BlendMode.src);
      canvas.drawPicture(artwork.picture);
    }
    final shader = program.fragmentShader();
    void draw(ui.Canvas c) {
      if (cachedRenderer != null) {
        cachedRenderer.paintCone(
            c,
            mesh,
            projection,
            origin,
            math.atan2(q[4], q[3]),
            q[5],
            q[6],
            _pixelScale,
            kind == 'overlay'
                ? const ui.Color(0xa000dfba)
                : const ui.Color(0xffffffff),
            shader,
            coneId: prefix,
            meshKey: mesh,
            viewport: receiver.viewBox,
            displayWarp: displayWarp,
            radialFalloff: kind == 'overlay' ? 1 : 0);
        return;
      }
      WorldHeightRenderer().paintCone(
          c,
          mesh,
          projection,
          origin,
          math.atan2(q[4], q[3]),
          q[5],
          q[6],
          _pixelScale,
          kind == 'overlay'
              ? const ui.Color(0xa000dfba)
              : const ui.Color(0xffffffff),
          shader,
          radialFalloff: kind == 'overlay' ? 1 : 0);
    }

    if (kind == 'unclipped') {
      draw(canvas);
    } else {
      paintWorldReceiverVisibility(
          canvas: canvas, receiver: receiver, paintVisibility: draw);
    }
    if (kind == 'overlay') {
      canvas.drawCircle(
          displayedOrigin, 2.3, ui.Paint()..color = const ui.Color(0xffffffff));
      final vector = projection.axisU * q[3] + projection.axisV * q[4];
      canvas.drawLine(
          displayedOrigin,
          displayedOrigin + vector / vector.distance * 9,
          ui.Paint()
            ..color = const ui.Color(0xffffffff)
            ..strokeWidth = 1);
    }
    await _png('$prefix-$kind.png', recorder.endRecording(), width, height);
    shader.dispose();
  }
  artwork.picture.dispose();
  cachedRenderer?.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('export fixed native poses through actual SVG and production renderer',
      () async {
    final env = Platform.environment;
    final output =
        Directory(env['ICARUS_AUDIT_OUTPUT'] ?? '$_audit/gallery-v1');
    await output.create(recursive: true);
    final library = File(env['ICARUS_AUDIT_LIBRARY'] ??
            'build/windows/x64/runner/Release/icarus_height.dll')
        .absolute
        .path;
    final candidate = env['ICARUS_AUDIT_CANDIDATE'] == null
        ? <String, dynamic>{}
        : jsonDecode(await File(env['ICARUS_AUDIT_CANDIDATE']!).readAsString())
            as Map<String, dynamic>;
    final candidateOnly = env['ICARUS_AUDIT_CANDIDATE_ONLY'] == '1';
    if (candidateOnly && candidate.isEmpty) {
      throw StateError('Candidate-only export requires a candidate config.');
    }
    final program =
        await ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
    final reports = <Map<String, dynamic>>[];
    final manifestFile = File('${output.path}/manifest.json');
    final previous = await manifestFile.exists()
        ? jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>
        : null;
    final libraryHash = await _sha(await File(library).readAsBytes());
    if (previous != null) {
      expect(previous['baselineLibrarySha256'], libraryHash,
          reason: 'A gallery cannot silently replace its native baseline.');
      expect(previous['candidateOnly'] ?? false, candidateOnly,
          reason: 'Do not mix baseline policies in a resumed gallery.');
      reports.addAll((previous['cases'] as List).cast<Map<String, dynamic>>());
    }
    Future<void> checkpoint() async {
      final pending = File('${manifestFile.path}.pending');
      await pending.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'candidateOnly': candidateOnly,
        if (candidateOnly)
          'baselineOmissionReason':
              'Explicit candidate-only replay. Frozen baseline query metadata is retained, but the old absolute-height pack is not computed or rendered.',
        'baselineLibrary': library,
        'baselineLibrarySha256': libraryHash,
        'physicalPixelsPerSvgUnit': _pixelScale,
        'scope':
            'Offline production rendering. Baseline native poses are frozen; explicit candidate side transforms preserve saved SVG marker positions. No live-game or complete wall correctness certification.',
        if (candidate['scope'] != null) 'candidateScope': candidate['scope'],
        'cases': reports
      }));
      await pending.rename(manifestFile.path);
    }

    for (final map in MapValue.values.where((m) =>
        env['ICARUS_AUDIT_MAPS'] == null ||
        env['ICARUS_AUDIT_MAPS']!.split(',').contains(m.name))) {
      final assets = await loadHeightAssets(map,
          bundle: _Bundle(), cacheRoot: Directory('$_audit/baseline-cache'));
      final bytes = await loadVerifiedHeightNavigation(map, bundle: _Bundle());
      final data =
          jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>;
      final t = assets.entry.uiTransform;
      ui.Offset native(ui.Offset uv) => ui.Offset(
          (uv.dy - t['YScalarToAdd']!) / (100 * t['YMultiplier']!),
          -(uv.dx - t['XScalarToAdd']!) / (100 * t['XMultiplier']!));
      final nav = NavigationGeometry.fromJson(data, projectUv: native);
      final source =
          await File('assets/maps/${map.name}_map.svg').readAsString();
      final fixtures = File('${output.path}/${map.name}-fixtures.json');
      late List<Map<String, dynamic>> rows;
      if (await fixtures.exists()) {
        final frozen = jsonDecode(await fixtures.readAsString()) as Map;
        expect(frozen['navigationSha256'], assets.entry.navigationSha256);
        expect(frozen['packSha256'], assets.entry.packSha256);
        rows = (frozen['cases'] as List).cast<Map<String, dynamic>>();
      } else {
        rows = _select(assets, nav, WorldReceiverMask.parse(source));
        if (map == MapValue.split) {
          final walking = jsonDecode(await File(
                  '$_root/compact-prototype/native-walking-fixtures-v1/split/walking-144hz.json')
              .readAsString());
          for (final (index, name) in [
            (4, 'clove'),
            (6, 'iso'),
            (8, 'deadlock')
          ]) {
            rows.insert(0, {
              'id': 'annotated-$name',
              'category': 'user annotated screenshot',
              'query': walking['frames'][0]['poses'][index],
              'originSvg': walking['frames'][0]['positionsSvg'][index],
              'agentIndex': index
            });
          }
        }
        await fixtures
            .writeAsString(const JsonEncoder.withIndent('  ').convert({
          'map': map.name,
          'navigationSha256': assets.entry.navigationSha256,
          'packSha256': assets.entry.packSha256,
          'policy':
              'Deterministic floor transitions, sharp nav polygon corners, farthest floor regions. These are stress cases, not claimed game ground truth. Annotated Split origins preserved exactly.',
          'cases': rows
        }));
      }
      final baselineWorker =
          await HeightNativeWorker.open(library, assets.folder, 4);
      final config =
          (candidate['maps'] as Map?)?[map.name] as Map<String, dynamic>?;
      DisplayWarp? displayWarp;
      String? displayWarpSha256;
      if (config?['displayWarpFile'] != null) {
        final compressed =
            await File(config!['displayWarpFile'] as String).readAsBytes();
        displayWarpSha256 = await _sha(compressed);
        expect(displayWarpSha256, config['displayWarpSha256'],
            reason: 'Candidate display warp bytes must be explicitly frozen.');
        final raw = await File('${config['folder']}/height-source.raw').open();
        late Map<String, dynamic> header;
        try {
          final prefix = await raw.read(8);
          expect(ascii.decode(prefix.take(4).toList()), 'IHD1');
          final length =
              ByteData.sublistView(prefix).getUint32(4, Endian.little);
          header = jsonDecode(utf8.decode(await raw.read(length)))
              as Map<String, dynamic>;
        } finally {
          await raw.close();
        }
        displayWarp = DisplayWarp.fromJson(
            jsonDecode(utf8.decode(gzip.decode(compressed)))
                as Map<String, dynamic>,
            expectedMap: map.name,
            expectedSourceGeometrySha256:
                header['sourceGeometrySha256'] as String,
            expectedProjection: assets.svgProjection);
        await verifyDisplayWarpArtwork(
            displayWarp,
            source,
            await File('assets/maps/${map.name}_map_defense.svg')
                .readAsString());
      }
      final sideMetadata = config?['projectionFile'] == null
          ? null
          : jsonDecode(await File(config!['projectionFile'] as String)
              .readAsString()) as Map<String, dynamic>;
      final candidateGround = config?['groundFieldFile'] == null
          ? null
          : TacticalGroundField.fromJson(jsonDecode(utf8.decode(gzip.decode(
              await File(config!['groundFieldFile'] as String)
                  .readAsBytes()))) as Map<String, dynamic>);
      final candidateNavigation = config?['navigationFile'] == null
          ? null
          : NavigationGeometry.fromJson(
              jsonDecode(utf8.decode(gzip.decode(
                  await File(config!['navigationFile'] as String)
                      .readAsBytes()))) as Map<String, dynamic>,
              projectUv: (uv) => assets.projection.toCanvas(native(uv)));
      final candidateWorker = config == null
          ? null
          : await HeightNativeWorker.open(
              config['library'] as String? ?? library,
              config['folder'] as String,
              4);
      final upperConfig = config?['upperChart'] as Map<String, dynamic>?;
      final upperGround = upperConfig == null
          ? null
          : TacticalGroundField.fromJson(jsonDecode(utf8.decode(gzip.decode(
              await File(upperConfig['groundFieldFile'] as String)
                  .readAsBytes()))) as Map<String, dynamic>);
      final upperWorker = upperConfig == null
          ? null
          : await HeightNativeWorker.open(
              upperConfig['library'] as String? ?? library,
              upperConfig['folder'] as String,
              4);
      try {
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i], id = row['id'] as String;
          final q =
              (row['query'] as List).map((v) => (v as num).toDouble()).toList();
          final frame = candidateOnly
              ? null
              : await baselineWorker.compute(i, Float64List.fromList(q));
          final mesh =
              frame == null ? null : Float32List.fromList(frame.cone(0));
          for (final defense in [false, true]) {
            final side = defense ? 'defense' : 'attack';
            final svgPath =
                'assets/maps/${map.name}_map${defense ? '_defense' : ''}.svg';
            final svg = await File(svgPath).readAsString();
            final mask = WorldReceiverMask.parse(svg);
            final p = assets.svgProjection;
            final projection = defense
                ? VisionWorldProjection(
                    origin: ui.Offset(mask.viewBox.width - p.origin.dx,
                        mask.viewBox.height - p.origin.dy),
                    axisU: -p.axisU,
                    axisV: -p.axisV)
                : p;
            final candidateRows =
                (config?['projectionsBySide'] as Map?)?[side] as List? ??
                    sideMetadata?[defense
                        ? 'nativeToDefenseSvg'
                        : 'nativeToAttackSvg'] as List?;
            final candidateProjection =
                candidateRows == null ? projection : _fromRows(candidateRows);
            final candidateQuery = ((config?['queriesBySide'] as Map?)?[side]
                    as Map?)?[id] as List? ??
                (config?['queriesById'] as Map?)?[id] as List?;
            var cq = candidateQuery?.map((v) => (v as num).toDouble()).toList();
            String? candidateFloorMode;
            var candidateChart = 0;
            var queryWorker = candidateWorker;
            if (config?['automaticQueries'] == true) {
              final displayPoint = candidateProjection
                  .toMeters(projection.toCanvas(ui.Offset(q[0], q[1])));
              final sourcePoint =
                  displayWarp?.sourceAt(displayPoint) ?? displayPoint;
              final fixedAbsolute = row['liveExactPoseVerified'] != null ||
                  row['eyeHeightMode'] == 'absolute';
              final selectedFloor = row['pairedFloor'] != null;
              final preferredFloor = selectedFloor || fixedAbsolute
                  ? q[2] * 100 - 175
                  : assets.entry.defaultFloorElevationCm;
              final navigationPoint = assets.projection.toCanvas(displayPoint);
              final floor = candidateNavigation!.floorHeightAt(navigationPoint,
                  preferredElevation: preferredFloor);
              if (upperWorker != null) {
                candidateChart = candidateNavigation.groundChartAt(
                    navigationPoint,
                    preferredElevation: preferredFloor);
                expect(candidateChart, anyOf(0, 1));
                if (row['expectedGroundVariant'] != null) {
                  expect(candidateChart, row['expectedGroundVariant'],
                      reason:
                          '$id must retain the authored navigation sheet on $side');
                }
              }
              queryWorker = candidateChart == 0 ? candidateWorker : upperWorker;
              final ground =
                  candidateChart == 0 ? candidateGround : upperGround;
              final reference = ground!.heightAt(sourcePoint);
              final eye = fixedAbsolute
                  ? q[2]
                  : ((floor ??
                              (reference == null
                                  ? assets.entry.defaultFloorElevationCm
                                  : reference * 100)) +
                          175) /
                      100;
              candidateFloorMode = fixedAbsolute
                  ? 'fixed-absolute-eye'
                  : floor == null
                      ? 'inferred-local-ground'
                      : selectedFloor
                          ? 'selected-floor-branch'
                          : 'automatic-floor';
              cq = reference == null
                  ? null
                  : [
                      sourcePoint.dx,
                      sourcePoint.dy,
                      eye - reference,
                      ...q.skip(3)
                    ];
              if (reference == null)
                candidateFloorMode = 'outside-ground-field';
              if (floor == null &&
                  !mask.containsReceiver(
                      projection.toCanvas(ui.Offset(q[0], q[1])))) {
                cq = null;
                candidateFloorMode = 'outside-observer-domain';
              }
            }
            Float32List? candidateMesh;
            if (cq != null) {
              expect(cq.length, 7);
              expect(cq.skip(3).toList(), q.skip(3).toList(),
                  reason: 'The viewing direction, range and angle stay fixed.');
              if (candidateRows == null && displayWarp == null) {
                expect(cq.take(2).toList(), q.take(2).toList(),
                    reason:
                        'Without a declared side projection, native XY stays fixed.');
              }
              expect((candidateProjection.axisU - projection.axisU).distance,
                  lessThan(1e-8));
              expect((candidateProjection.axisV - projection.axisV).distance,
                  lessThan(1e-8));
              final originalApex = projection.toCanvas(ui.Offset(q[0], q[1]));
              final candidateApex = candidateProjection.toCanvas(
                  displayWarp?.targetAt(ui.Offset(cq[0], cq[1])) ??
                      ui.Offset(cq[0], cq[1]));
              final physicalSideControl =
                  config?['samePhysicalPoseAcrossSides'] == true;
              final sideDelta = physicalSideControl && defense
                  ? ui.Offset(
                      (sideMetadata!['defenseDeltaAfterReflectionSvg'][0]
                              as num)
                          .toDouble(),
                      (sideMetadata['defenseDeltaAfterReflectionSvg'][1] as num)
                          .toDouble())
                  : ui.Offset.zero;
              expect((originalApex + sideDelta - candidateApex).distance,
                  lessThan(1e-6),
                  reason: physicalSideControl
                      ? 'Same-source control uses the actual authored side point; saved-marker replay is separate.'
                      : 'Side registration must keep the exact saved SVG marker.');
              candidateMesh = Float32List.fromList((await queryWorker!.compute(
                      i * 2 + (defense ? 1 : 0), Float64List.fromList(cq)))
                  .cone(0));
            }
            final dir = Directory('${output.path}/${map.name}/$side')
              ..createSync(recursive: true);
            if (mesh != null)
              await _render('${dir.path}/$id-before', svg, mask, projection, q,
                  mesh, program);
            if (candidateMesh != null)
              await _render('${dir.path}/$id-after', svg, mask,
                  candidateProjection, cq!, candidateMesh, program,
                  displayWarp: displayWarp);
            reports.removeWhere((r) =>
                r['map'] == map.name && r['side'] == side && r['id'] == id);
            reports.add({
              'map': map.name,
              'side': side,
              'id': id,
              'category': row['category'],
              if (row['expectedGroundVariant'] != null)
                'expectedGroundVariant': row['expectedGroundVariant'],
              if (row['parentPolygon'] != null)
                'frozenParentPolygon': row['parentPolygon'],
              if (config?['explicitGroundVariant'] != null)
                'explicitGroundVariant': config!['explicitGroundVariant'],
              if (config?['scopeLabel'] != null)
                'scopeLabel': config!['scopeLabel'],
              'before':
                  mesh == null ? null : '${dir.path}/$id-before-overlay.png',
              'after': candidateMesh == null
                  ? null
                  : '${dir.path}/$id-after-overlay.png',
              'candidateStatus':
                  candidateMesh == null ? 'unavailable' : 'experimental',
              'svgSha256': await _sha(utf8.encode(svg)),
              'baselineMeshSha256':
                  mesh == null ? null : await _sha(mesh.buffer.asUint8List()),
              'candidateMeshSha256': candidateMesh == null
                  ? null
                  : await _sha(candidateMesh.buffer.asUint8List()),
              'candidateQuery': cq,
              'candidateFloorMode': candidateFloorMode,
              'candidateGroundChart':
                  config?['explicitGroundVariant'] ?? candidateChart,
              'candidateProjectionRows': candidateRows,
              if (displayWarp != null) 'displayWarpSha256': displayWarpSha256,
              'query': q
            });
          }
        }
      } finally {
        await baselineWorker.close();
        await candidateWorker?.close();
        await upperWorker?.close();
      }
      await checkpoint();
      stdout.writeln(
          'GALLERY ${map.name}: ${rows.length} fixed poses, both actual SVG sides');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
