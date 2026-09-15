// Isolated replay of frozen gallery meshes and actual SVG ink. No app assets change.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/height_native.dart';
import 'package:icarus/view_cone/receiver_compositor.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';
import 'package:xml/xml.dart';

import 'audit_picture_raster.dart';

const revision = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';

Future<String> sha(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((v) => v.toRadixString(16).padLeft(2, '0'))
    .join();

String inkOnly(String svg) {
  final document = XmlDocument.parse(svg);
  void visit(XmlElement element, String fill, String stroke) {
    fill = element.getAttribute('fill') ?? fill;
    stroke = element.getAttribute('stroke') ?? stroke;
    if (element.getAttribute('style') != null) {
      throw StateError('Resolve styles before extracting wall ink.');
    }
    if (const {
      'path',
      'circle',
      'ellipse',
      'rect',
      'polygon',
      'polyline',
      'line'
    }.contains(element.name.local)) {
      element.setAttribute(
          'fill', fill.toLowerCase() == '#b27c40' ? '#ffffff' : 'none');
      element.setAttribute(
          'stroke', stroke.toLowerCase() == '#b27c40' ? '#ffffff' : 'none');
    }
    for (final child in element.childElements) {
      visit(child, fill, stroke);
    }
  }

  visit(document.rootElement, 'black', 'none');
  return document.toXmlString();
}

Future<void> png(String path, double scale, ui.Rect box,
    void Function(ui.Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(scale);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
      (box.width * scale).ceil(), (box.height * scale).ceil());
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('replay frozen wall-contact cases and export actual authored ink',
      () async {
    final env = Platform.environment;
    final mapName = env['ICARUS_CONTACT_MAP'] ?? 'split';
    if (!RegExp(r'^[a-z]+$').hasMatch(mapName)) {
      throw StateError('Invalid contact map name.');
    }
    final caseIds = (env['ICARUS_CONTACT_CASES'] ??
            'ramp-1-forward,annotated-deadlock,annotated-clove')
        .split(',')
        .toSet();
    final gallery =
        env['ICARUS_CONTACT_GALLERY'] ?? '$revision/gallery-display-split-v1';
    final output = Directory(
        env['ICARUS_CONTACT_OUTPUT'] ?? '$revision/wall-contact-pixels-v1');
    if (output.existsSync() && output.listSync().isNotEmpty) {
      throw StateError(
          'Use a new output folder; preserve prior contact evidence.');
    }
    output.createSync(recursive: true);
    final manifestBytes = await File('$gallery/manifest.json').readAsBytes();
    final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map;
    final baselineGallery = env['ICARUS_CONTACT_BASELINE_GALLERY'] ??
        '$revision/gallery-display-split-v1';
    final baselineManifestBytes =
        await File('$baselineGallery/manifest.json').readAsBytes();
    final baselineManifest =
        jsonDecode(utf8.decode(baselineManifestBytes)) as Map;
    final configFile = env['ICARUS_CONTACT_CANDIDATE'] ??
        '$revision/staged-display-split-v1/candidate-config.json';
    final configBytes = await File(configFile).readAsBytes();
    final config =
        (jsonDecode(utf8.decode(configBytes)) as Map)['maps'][mapName] as Map;
    final warpBytes =
        await File(config['displayWarpFile'] as String).readAsBytes();
    expect(await sha(warpBytes), config['displayWarpSha256']);
    final warp = DisplayWarp.fromJson(
        jsonDecode(utf8.decode(gzip.decode(warpBytes)))
            as Map<String, dynamic>);
    final worker = await HeightNativeWorker.open(
        config['library'] as String, config['folder'] as String, 1);
    final program =
        await ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
    final reports = <Map<String, dynamic>>[];
    final viewportFile = env['ICARUS_CONTACT_VIEWPORTS'];
    final viewportBytes =
        viewportFile == null ? null : await File(viewportFile).readAsBytes();
    final viewportConfig = viewportBytes == null
        ? null
        : jsonDecode(utf8.decode(viewportBytes)) as Map;
    final validateViewports = env['ICARUS_CONTACT_VALIDATE_VIEWPORTS'] == '1';
    if (validateViewports && viewportConfig == null)
      throw StateError('Viewport validation needs declared rectangles.');
    Future<void> checkpoint({bool complete = false}) async {
      await File('${output.path}/manifest.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert({
        'complete': complete,
        'scope':
            'Frozen gallery replay. Actual SVG ink and production cone renderer; physical XY shadow mesh retained for independent vector/raster separation. No wall semantics inferred from ink alone.',
        'map': mapName,
        'galleryManifestSha256': await sha(manifestBytes),
        'baselineGalleryManifestSha256': await sha(baselineManifestBytes),
        'candidateConfigFile': configFile,
        'candidateConfigSha256': await sha(configBytes),
        'sourceGeometrySha256': config['sourceGeometrySha256'],
        if (config['candidatePackSha256'] != null)
          'declaredCandidatePackSha256': config['candidatePackSha256'],
        'displayWarpFile': config['displayWarpFile'],
        'displayWarpSha256': await sha(warpBytes),
        'clearanceMeters': 0,
        'scales': [2, 8],
        if (viewportBytes != null)
          'viewportConfigSha256': await sha(viewportBytes),
        'rasterMode': viewportConfig == null
            ? 'full-map'
            : 'full-raster-small-native-crop-encoding',
        'viewportValidation': validateViewports,
        'overlayConsistencyFile': '${output.path}/overlay-consistency.json',
        'viewportPolicy':
            'Original full picture rasterized once, unchanged painting and receiver. Crops copy integer pixels without filtering; full2x context and native2x/8x crops are encoded. Full render target remains allocated.',
        'cases': reports
      }));
    }

    try {
      for (final side in ['attack', 'defense']) {
        final svgFile =
            'assets/maps/${mapName}_map${side == 'defense' ? '_defense' : ''}.svg';
        final svg = await File(svgFile).readAsString();
        final svgHash = await sha(utf8.encode(svg));
        final receiver = WorldReceiverMask.parse(svg);
        final ink = await vg.loadPicture(SvgStringLoader(inkOnly(svg)), null);
        final art = await vg.loadPicture(SvgStringLoader(svg), null);
        for (final scale in [2.0, 8.0]) {
          await png('${output.path}/$side-${scale.toInt()}x-ink.png', scale,
              receiver.viewBox, (c) => c.drawPicture(ink.picture));
          await png('${output.path}/$side-${scale.toInt()}x-art.png', scale,
              receiver.viewBox, (c) => c.drawPicture(art.picture));
        }
        ink.picture.dispose();
        final rows = (manifest['cases'] as List).cast<Map>().where((r) =>
            r['map'] == mapName &&
            r['side'] == side &&
            caseIds.contains(r['id']));
        for (final row in rows) {
          final baselineRow = (baselineManifest['cases'] as List)
              .cast<Map>()
              .singleWhere((r) =>
                  r['map'] == mapName &&
                  r['id'] == row['id'] &&
                  r['side'] == side);
          expect(svgHash, row['svgSha256']);
          expect(await sha(warpBytes), row['displayWarpSha256']);
          final q = (row['candidateQuery'] as List)
              .map((v) => (v as num).toDouble())
              .toList();
          expect(q, baselineRow['candidateQuery'],
              reason:
                  'Wall geometry comparisons require the same source pose.');
          final projectionRows = (row['candidateProjectionRows'] as List)
              .map(
                  (r) => (r as List).map((v) => (v as num).toDouble()).toList())
              .toList();
          final projection = VisionWorldProjection(
              origin: ui.Offset(projectionRows[0][2], projectionRows[1][2]),
              axisU: ui.Offset(projectionRows[0][0], projectionRows[1][0]),
              axisV: ui.Offset(projectionRows[0][1], projectionRows[1][1]));
          final mesh = Float32List.fromList(
              (await worker.compute(reports.length, Float64List.fromList(q)))
                  .cone(0));
          final meshBytes = mesh.buffer.asUint8List();
          // Verify against this candidate's freshly computed gallery result.
          // The old geometry hash is evidence, not an equality requirement.
          expect(await sha(meshBytes), row['candidateMeshSha256']);
          final prefix = '${output.path}/$side-${row['id']}';
          await File('$prefix-shadow.f32').writeAsBytes(meshBytes);
          final renderer = WorldHeightCachedRenderer();
          final rasterRegions = <Map<String, dynamic>>[];
          final viewports = viewportConfig == null
              ? null
              : ((viewportConfig['cases'] as Map)['$side/${row['id']}']
                      as List?)
                  ?.cast<Map>();
          if (viewportConfig != null &&
              (viewports == null || viewports.isEmpty)) {
            throw StateError('Missing viewports for $side/${row['id']}');
          }
          for (final scale in [2.0, 8.0]) {
            for (final kind in ['unclipped', 'visibility', 'overlay']) {
              final shader = program.fragmentShader();
              void draw(ui.Canvas c) => renderer.paintCone(
                  c,
                  mesh,
                  projection,
                  projection.toCanvas(ui.Offset(q[0], q[1])),
                  math.atan2(q[4], q[3]),
                  q[5],
                  q[6],
                  scale,
                  kind == 'overlay'
                      ? const ui.Color(0xa000dfba)
                      : const ui.Color(0xffffffff),
                  shader,
                  coneId: prefix,
                  meshKey: mesh,
                  viewport: receiver.viewBox,
                  displayWarp: warp,
                  clearanceMeters: 0,
                  radialFalloff: kind == 'overlay' ? 1 : 0);
              void paint(ui.Canvas c) {
                if (kind == 'overlay') {
                  c.drawColor(const ui.Color(0xff101014), ui.BlendMode.src);
                  c.drawPicture(art.picture);
                }
                if (kind != 'unclipped') {
                  paintWorldReceiverVisibility(
                      canvas: c, receiver: receiver, paintVisibility: draw);
                } else {
                  draw(c);
                }
              }

              if (viewports == null) {
                await png('$prefix-${scale.toInt()}x-$kind.png', scale,
                    receiver.viewBox, paint);
              } else {
                final picture = recordAuditPicture(scale, paint);
                final width = (receiver.viewBox.width * scale).ceil();
                final height = (receiver.viewBox.height * scale).ceil();
                ui.Image? full;
                try {
                  full = await picture.toImage(width, height);
                  if (scale == 2 || validateViewports) {
                    await writeAuditPng(
                        '$prefix-${scale.toInt()}x-$kind.png', full);
                  }
                  for (final viewport in viewports) {
                    final name = viewport['name'] as String;
                    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(name))
                      throw StateError('Invalid viewport name.');
                    final rect = (viewport['svgRect'] as List).cast<num>();
                    final pixels = auditPixelBounds(
                        ui.Rect.fromLTRB(rect[0].toDouble(), rect[1].toDouble(),
                            rect[2].toDouble(), rect[3].toDouble()),
                        scale,
                        width,
                        height);
                    final cropped = await copyAuditImagePixels(full, pixels);
                    final path = '$prefix-${scale.toInt()}x-$kind-$name.png';
                    try {
                      final differences = validateViewports
                          ? await auditCropDifferences(full, cropped, pixels)
                          : null;
                      expect(differences ?? 0, 0,
                          reason:
                              '$side/${row['id']}/$scale/$kind/$name crop differs from full render');
                      await writeAuditPng(path, cropped);
                      rasterRegions.add({
                        'name': name,
                        'scale': scale,
                        'kind': kind,
                        'path': path,
                        'pixelRect': [
                          pixels.left.toInt(),
                          pixels.top.toInt(),
                          pixels.right.toInt(),
                          pixels.bottom.toInt()
                        ],
                        if (differences != null)
                          'rgbaChannelDifferencesFromFullCrop': differences
                      });
                    } finally {
                      cropped.dispose();
                    }
                  }
                } finally {
                  full?.dispose();
                  picture.dispose();
                }
              }
              shader.dispose();
            }
          }
          renderer.dispose();
          reports.add({
            'id': row['id'],
            'side': side,
            'prefix': prefix,
            'query': q,
            'projectionRows': projectionRows,
            'meshSha256': row['candidateMeshSha256'],
            'baselineMeshSha256': baselineRow['candidateMeshSha256'],
            'geometryChangedFromBaseline': row['candidateMeshSha256'] !=
                baselineRow['candidateMeshSha256'],
            'baselineQuery': baselineRow['candidateQuery'],
            'svgSha256': svgHash,
            if (viewports != null) 'rasterRegions': rasterRegions
          });
          await checkpoint();
        }
        art.picture.dispose();
      }
    } finally {
      await worker.close();
    }
    // A prior long run produced a corrupt colored layer while its independently
    // masked white coverage stayed correct. The cause is not established.
    // Keep failed artifacts and require an explicit fresh recapture.
    final consistency = await Process.run(
        env['ICARUS_AUDIT_PYTHON'] ??
            'E:/IcarusWorldAudit/2026-09-06/venv/Scripts/python.exe',
        [
          File('scripts/validate_audit_overlay.py').absolute.path,
          '--folder',
          output.path
        ]);
    expect(consistency.exitCode, 0,
        reason: 'Colored overlay disagrees with masked coverage/artwork. '
            'Preserved failure report: ${output.path}/overlay-consistency.json. '
            '${consistency.stdout}\n${consistency.stderr}');
    await checkpoint(complete: true);
  }, timeout: const Timeout(Duration(minutes: 12)));
}
