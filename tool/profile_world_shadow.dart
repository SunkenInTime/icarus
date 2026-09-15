import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';
import 'package:window_manager/window_manager.dart';

import 'world_shadow_mesh.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.directory);
  final String directory;
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
      await File('$directory/${key.split('/').last}').readAsBytes());
}

class _Route {
  _Route(Map<String, dynamic> json, VisionWorldProjection projection)
      : points = [
          for (final p in json['pointsCanvas'])
            Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())
        ] {
    for (var i = 1; i < points.length; i++) {
      distances.add(distances.last +
          projection.vectorToMeters(points[i] - points[i - 1]).distance);
    }
  }
  final List<Offset> points;
  final distances = <double>[0];

  ({Offset origin, double facing}) at(double distance) {
    var along = distance % (2 * distances.last);
    final reverse = along > distances.last;
    if (reverse) along = 2 * distances.last - along;
    var i = 1;
    while (i < distances.length - 1 && along > distances[i]) {
      i++;
    }
    final direction = points[i] - points[i - 1];
    final fraction =
        (along - distances[i - 1]) / (distances[i] - distances[i - 1]);
    return (
      origin: points[i - 1] + direction * fraction,
      facing: math.atan2(direction.dy, direction.dx) + (reverse ? math.pi : 0)
    );
  }
}

Map<String, dynamic> _summary(List<int> values) {
  if (values.isEmpty) return {'samples': 0};
  values.sort();
  int p(double value) => values[((values.length - 1) * value).round()];
  return {
    'samples': values.length,
    'medianMicros': p(.5),
    'p95Micros': p(.95),
    'maxMicros': values.last,
    'within144HzBudget': values.where((v) => v <= 1000000 / 144).length,
    'within240HzBudget': values.where((v) => v <= 1000000 / 240).length,
  };
}

class _Controller extends ChangeNotifier {
  var frame = -1;
  void advance() {
    frame++;
    notifyListeners();
  }
}

class _PreparedCone {
  _PreparedCone(this.sample, this.projection, this.facing, this.range,
      this.elevation, this.mesh, this.candidates);
  final ({Offset origin, double facing}) sample;
  final VisionWorldProjection projection;
  final double facing, range, elevation;
  final Float32List mesh;
  final int candidates;
}

List<List<_PreparedCone>> _prepare(
    VisionGeometryMap geometry, List<_Route> routes, int simulatedHz) {
  final builder = WorldShadowMeshBuilder();
  return [
    for (var frame = 0;
        frame < _ProbeState.warmupFrames + _ProbeState.measuredFrames;
        frame++)
      [
        for (var i = 0; i < routes.length; i++)
          (() {
            final sample = routes[i].at(frame * 5.4 / simulatedHz + i * .071);
            final canvasLayer = geometry.layerForPosition(
                isAttack: true, position: sample.origin);
            final layer = canvasLayer.metricLayer!;
            final projection = canvasLayer.worldProjection!;
            final origin = projection.toMeters(sample.origin);
            final direction = projection.vectorToMeters(
                Offset(math.cos(sample.facing), math.sin(sample.facing)));
            final facing = math.atan2(direction.dy, direction.dx);
            final range = 361 * direction.distance;
            if (!layer.contains(origin))
              throw StateError('Unadmitted observer.');
            final mesh = Float32List.fromList(builder.build(
                index: layer.worldIndex!,
                origin: origin,
                facingAngle: facing,
                coneAngle: 103 * math.pi / 180,
                range: range,
                clipPadding: range / 128));
            return _PreparedCone(sample, projection, facing, range,
                layer.elevation, mesh, builder.candidates);
          })(),
      ],
  ];
}

class _Probe extends StatefulWidget {
  const _Probe(
      this.geometry,
      this.routes,
      this.output,
      this.mode,
      this.simulatedHz,
      this.loadMicros,
      this.prepared,
      this.preparationMicros,
      this.program,
      this.clearancePixels);
  final VisionGeometryMap geometry;
  final List<_Route> routes;
  final File output;
  final String mode;
  final int simulatedHz, loadMicros;
  final List<List<_PreparedCone>>? prepared;
  final int preparationMicros;
  final ui.FragmentProgram? program;
  final double clearancePixels;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  final controller = _Controller();
  final boundaryKey = GlobalKey();
  final records = <int, Map<String, dynamic>>{};
  final timings = <int, ui.FrameTiming>{};
  late final Ticker ticker;
  static const warmupFrames = 60;
  static const measuredFrames = 360;
  var finishing = false;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    ticker = createTicker((elapsed) {
      controller.advance();
      if (controller.frame >= warmupFrames + measuredFrames && !finishing) {
        finishing = true;
        // Release timing reports are batched roughly once per second. Keep
        // painting the last position until the final measured batch arrives.
        unawaited(Future<void>.delayed(const Duration(seconds: 2), _finish));
      }
    })
      ..start();
  }

  void _timings(List<ui.FrameTiming> batch) {
    for (final value in batch) {
      timings[value.timestampInMicroseconds(ui.FramePhase.vsyncStart)] = value;
    }
  }

  Future<void> _finish() async {
    ticker.stop();
    try {
      final rows = <Map<String, dynamic>>[];
      final coldRows = <Map<String, dynamic>>[];
      for (final entry in records.entries) {
        final row = entry.value;
        final frame = row['frame'] as int;
        if (frame < 0 || frame >= warmupFrames + measuredFrames) {
          continue;
        }
        final paintClock = row['paintClockMicros'] as int;
        final matching = timings.values.where((value) =>
            value.timestampInMicroseconds(ui.FramePhase.buildStart) <=
                paintClock &&
            value.timestampInMicroseconds(ui.FramePhase.buildFinish) >=
                paintClock);
        final timing = matching.length == 1 ? matching.single : null;
        (frame < warmupFrames ? coldRows : rows).add({
          ...row,
          'timingMatched': timing != null,
          if (timing != null) ...{
            'buildMicros': timing.buildDuration.inMicroseconds,
            'rasterMicros': timing.rasterDuration.inMicroseconds,
            'totalSpanMicros': timing.totalSpan.inMicroseconds,
            'pipelineMicros': math.max(timing.buildDuration.inMicroseconds,
                timing.rasterDuration.inMicroseconds),
          },
        });
      }
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final capture = await boundary.toImage(pixelRatio: 1);
      final png = await capture.toByteData(format: ui.ImageByteFormat.png);
      await File('${widget.output.path}.png')
          .writeAsBytes(png!.buffer.asUint8List());
      capture.dispose();
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      await widget.output.parent.create(recursive: true);
      await widget.output.writeAsString(jsonEncode({
        'status': 'complete',
        'mode': widget.mode,
        'map': widget.geometry.map.name,
        'projectionAxes': [
          [
            widget.geometry.worldData!.projection!.axisU.dx,
            widget.geometry.worldData!.projection!.axisU.dy
          ],
          [
            widget.geometry.worldData!.projection!.axisV.dx,
            widget.geometry.worldData!.projection!.axisV.dy
          ],
        ],
        'resolutionPhysical': [
          view.physicalSize.width,
          view.physicalSize.height
        ],
        'devicePixelRatio': view.devicePixelRatio,
        'displayRefreshRate': view.display.refreshRate,
        'simulatedHz': widget.simulatedHz,
        'walkingMetersPerSecond': 5.4,
        'surfaceClearancePixels': widget.clearancePixels,
        'preparedInputs': widget.prepared != null,
        'preparationMicros': widget.preparationMicros,
        'preparedMeshBytes': widget.prepared?.fold<int>(
            0,
            (sum, frame) =>
                sum +
                frame.fold<int>(0, (n, cone) => n + cone.mesh.lengthInBytes)),
        'shaderFilterSupported': ui.ImageFilter.isShaderFilterSupported,
        'loadMicros': widget.loadMicros,
        'warmupFrames': warmupFrames,
        'requestedMeasuredFrames': measuredFrames,
        'recordedFrames': rows.length,
        'matchedTimings': rows.where((r) => r['timingMatched'] == true).length,
        'timingReportCount': timings.length,
        'rawTimingSample': [
          for (final timing in timings.values.take(5))
            {
              'frameNumber': timing.frameNumber,
              'vsyncStart':
                  timing.timestampInMicroseconds(ui.FramePhase.vsyncStart),
              'buildStart':
                  timing.timestampInMicroseconds(ui.FramePhase.buildStart),
              'buildFinish':
                  timing.timestampInMicroseconds(ui.FramePhase.buildFinish),
            }
        ],
        'summaries': {
          for (final field in [
            'buildMicros',
            'rasterMicros',
            'totalSpanMicros',
            'pipelineMicros',
            'layerMicros',
            'geometryMicros',
            'recordPaintMicros'
          ])
            field: _summary([
              for (final row in rows)
                if (row[field] is int) row[field] as int
            ]),
        },
        'coldFrames': coldRows,
        'coldSummaries': {
          for (final field in [
            'buildMicros',
            'rasterMicros',
            'pipelineMicros',
            'layerMicros',
            'geometryMicros',
            'recordPaintMicros'
          ])
            field: _summary([
              for (final row in coldRows)
                if (row[field] is int) row[field] as int
            ]),
        },
        'frames': rows,
        'finalRssBytes': ProcessInfo.currentRss,
        'peakRssBytes': ProcessInfo.maxRss,
        'limitations': [
          'Experimental renderer in an actual Flutter window, without the rest of the Icarus UI.',
          'The prepared-input mode is a renderer ceiling, not a working background data pipeline.',
          'FrameTiming measures UI and raster threads; it is not a hardware GPU timestamp or proof of physical 144/240 Hz presentation.',
        ],
      }));
    } catch (error, stack) {
      await widget.output.writeAsString(jsonEncode(
          {'status': 'failed', 'error': '$error', 'stack': '$stack'}));
    }
    exit(0);
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: boundaryKey,
          child: ColoredBox(
            color: Settings.tacticalVioletTheme.background,
            child: CustomPaint(
              painter: _Painter(
                  widget.geometry,
                  widget.routes,
                  controller,
                  widget.mode,
                  widget.simulatedHz,
                  records,
                  widget.prepared,
                  widget.program,
                  widget.clearancePixels),
              size: Size.infinite,
            ),
          ),
        ),
      );

  @override
  void dispose() {
    ticker.dispose();
    controller.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    super.dispose();
  }
}

class _Painter extends CustomPainter {
  _Painter(
      this.geometry,
      this.routes,
      this.controller,
      this.mode,
      this.simulatedHz,
      this.records,
      this.prepared,
      ui.FragmentProgram? program,
      this.clearancePixels)
      : shaders = program == null
            ? null
            : List.generate(10, (_) => program.fragmentShader()),
        super(repaint: controller);
  final VisionGeometryMap geometry;
  final List<_Route> routes;
  final _Controller controller;
  final String mode;
  final int simulatedHz;
  final Map<int, Map<String, dynamic>> records;
  final List<List<_PreparedCone>>? prepared;
  final List<ui.FragmentShader>? shaders;
  final double clearancePixels;
  final builders = List.generate(10, (_) => WorldShadowMeshBuilder());

  @override
  void paint(Canvas canvas, Size size) {
    final frame = math.min(controller.frame,
        _ProbeState.warmupFrames + _ProbeState.measuredFrames - 1);
    if (frame < 0) return;
    final vsync =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    final watch = Stopwatch()..start();
    var layerMicros = 0, geometryMicros = 0, triangles = 0, candidates = 0;
    final decodeBefore = geometry.worldData!.chunkDecodeProfile;
    final positions = <List<double>>[], elevations = <double>[];
    canvas.save();
    final scale = math.min(size.width / (1000 * 16 / 9), size.height / 1000);
    canvas.translate((size.width - (1000 * 16 / 9) * scale) / 2,
        (size.height - 1000 * scale) / 2);
    canvas.scale(scale);
    final grid = Paint()
      ..color = Settings.highlightColor
      ..strokeWidth = 1 / scale;
    for (var x = 0.0; x < 1778; x += 100) {
      canvas.drawLine(Offset(x, 0), Offset(x, 1000), grid);
    }
    for (var y = 0.0; y < 1001; y += 100) {
      canvas.drawLine(Offset(0, y), Offset(1778, y), grid);
    }
    for (var i = 0; i < routes.length; i++) {
      final ready = prepared?[frame][i];
      final sample =
          ready?.sample ?? routes[i].at(frame * 5.4 / simulatedHz + i * .071);
      final layerWatch = Stopwatch()..start();
      final canvasLayer = ready != null
          ? null
          : geometry.layerForPosition(isAttack: true, position: sample.origin);
      final layer = canvasLayer?.metricLayer;
      final projection = ready?.projection ?? canvasLayer!.worldProjection!;
      final origin = projection.toMeters(sample.origin);
      final direction = projection.vectorToMeters(
          Offset(math.cos(sample.facing), math.sin(sample.facing)));
      final facing = ready?.facing ?? math.atan2(direction.dy, direction.dx);
      final range = ready?.range ?? 361 * direction.distance;
      if (ready == null && !layer!.contains(origin)) {
        throw StateError('Unadmitted walking observer at frame $frame.');
      }
      layerMicros += layerWatch.elapsedMicroseconds;
      positions.add([sample.origin.dx, sample.origin.dy]);
      elevations.add(ready?.elevation ?? layer!.elevation);
      final geometryWatch = Stopwatch()..start();
      final color = i < 5 ? Settings.allyBGColor : Settings.enemyBGColor;
      final fill = Paint()..color = color.withValues(alpha: .5);
      const cone = 103 * math.pi / 180;
      if (mode == 'polygon') {
        final polygon = VisionPolygon.compute(
            layer: canvasLayer!,
            origin: sample.origin,
            facingAngle: sample.facing,
            coneAngle: cone,
            range: 361,
            surfaceClearance: clearancePixels / scale);
        geometryMicros += geometryWatch.elapsedMicroseconds;
        final path = Path()..addPolygon(polygon, true);
        canvas.drawPath(path, fill);
      } else {
        final mesh = ready?.mesh ??
            builders[i].build(
                index: layer!.worldIndex!,
                origin: origin,
                facingAngle: facing,
                coneAngle: cone,
                range: range,
                clipPadding: range / 128);
        geometryMicros += geometryWatch.elapsedMicroseconds;
        candidates += ready?.candidates ?? builders[i].candidates;
        triangles += mesh.length ~/ 6;
        if (shaders != null) {
          _paintRadial(canvas, mesh, projection, sample.origin, facing, range,
              cone, scale, fill.color, shaders![i]);
          canvas.drawCircle(sample.origin, 3, Paint()..color = color);
          continue;
        }
        canvas.save();
        canvas.transform(Float64List.fromList([
          projection.axisU.dx,
          projection.axisU.dy,
          0,
          0,
          projection.axisV.dx,
          projection.axisV.dy,
          0,
          0,
          0,
          0,
          1,
          0,
          sample.origin.dx,
          sample.origin.dy,
          0,
          1,
        ]));
        final bounds = Rect.fromCircle(center: Offset.zero, radius: range);
        canvas.saveLayer(bounds, Paint());
        final sector = Path()
          ..moveTo(0, 0)
          ..arcTo(bounds, facing - cone / 2, cone, false)
          ..close();
        canvas.drawPath(sector, fill);
        paintWorldShadowMesh(canvas, mesh);
        canvas.restore();
        canvas.restore();
      }
      canvas.drawCircle(sample.origin, 3, Paint()..color = color);
    }
    canvas.restore();
    if (controller.frame >=
        _ProbeState.warmupFrames + _ProbeState.measuredFrames) return;
    records[vsync] = {
      'paintClockMicros': developer.Timeline.now,
      'frame': frame,
      'layerMicros': layerMicros,
      'geometryMicros': geometryMicros,
      'recordPaintMicros': watch.elapsedMicroseconds,
      'candidates': candidates,
      'triangles': triangles,
      'originsCanvas': positions,
      'elevationsCm': elevations,
      'decodedChunks':
          geometry.worldData!.chunkDecodeProfile.count - decodeBefore.count,
      'residentBlockBytes': geometry.worldData!.residentChunks.bytes,
    };
  }

  void _paintRadial(
      Canvas canvas,
      Float32List mesh,
      VisionWorldProjection projection,
      Offset origin,
      double facing,
      double range,
      double cone,
      double scale,
      Color color,
      ui.FragmentShader shader) {
    // Resolve coverage only after shadow union and cone intersection. Applying
    // antialiasing to the cone before opaque triangle subtraction leaves seams
    // when their edges coincide. A 2x mask supplies four coverage samples.
    final canvasRadius = range *
        math.sqrt(math.max(
            projection.axisU.dx * projection.axisU.dx +
                projection.axisV.dx * projection.axisV.dx,
            projection.axisU.dy * projection.axisU.dy +
                projection.axisV.dy * projection.axisV.dy));
    final imageSize = (2 * canvasRadius * scale * 2).ceil() + 8;
    final recorder = ui.PictureRecorder();
    final mask = Canvas(recorder);
    mask.translate(imageSize / 2, imageSize / 2);
    mask.scale(scale * 2);
    mask.transform(Float64List.fromList([
      projection.axisU.dx,
      projection.axisU.dy,
      0,
      0,
      projection.axisV.dx,
      projection.axisV.dy,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ]));
    final vertices = ui.Vertices.raw(ui.VertexMode.triangles, mesh);
    mask.drawVertices(
        vertices, BlendMode.src, Paint()..color = const Color(0xffffffff));
    vertices.dispose();
    final picture = recorder.endRecording();
    final image = picture.toImageSync(imageSize, imageSize);
    picture.dispose();
    shader
      ..setFloat(0, origin.dx)
      ..setFloat(1, origin.dy)
      ..setFloat(2, imageSize / (scale * 2))
      ..setFloat(3, clearancePixels / scale * range / 361)
      ..setFloat(4, range)
      ..setFloat(5, color.r)
      ..setFloat(6, color.g)
      ..setFloat(7, color.b)
      ..setFloat(8, color.a)
      ..setFloat(9, 1 / scale)
      ..setFloat(10, imageSize.toDouble())
      ..setFloat(11, math.cos(facing))
      ..setFloat(12, math.sin(facing))
      ..setFloat(13, math.cos(cone / 2))
      ..setFloat(14, projection.vectorToMeters(const Offset(1, 0)).dx)
      ..setFloat(15, projection.vectorToMeters(const Offset(1, 0)).dy)
      ..setFloat(16, projection.vectorToMeters(const Offset(0, 1)).dx)
      ..setFloat(17, projection.vectorToMeters(const Offset(0, 1)).dy)
      ..setFloat(18, projection.axisU.dx)
      ..setFloat(19, projection.axisU.dy)
      ..setFloat(20, projection.axisV.dx)
      ..setFloat(21, projection.axisV.dy)
      ..setImageSampler(0, image);
    final bounds = Rect.fromCircle(center: origin, radius: canvasRadius);
    canvas.drawRect(
        bounds.inflate(1 / scale),
        Paint()
          ..shader = shader
          ..isAntiAlias = false);
    image.dispose();
  }

  @override
  bool shouldRepaint(covariant _Painter oldDelegate) => true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final output = File(Platform.environment['ICARUS_AUDIT_OUTPUT']!);
  await output.parent.create(recursive: true);
  try {
    final directory = Platform.environment['ICARUS_WORLD_DIRECTORY']!;
    final map = MapValue.values
        .byName(Platform.environment['ICARUS_WORLD_MAP'] ?? 'fracture');
    final mode = Platform.environment['ICARUS_SHADOW_MODE'] ?? 'shadow';
    if (!['shadow', 'polygon', 'radial'].contains(mode))
      throw ArgumentError('Invalid render mode.');
    final reference = jsonDecode(
        await File(Platform.environment['ICARUS_WALKING_REFERENCE']!)
            .readAsString()) as Map<String, dynamic>;
    if (reference['map'] != map.name) throw ArgumentError('Wrong walking map.');
    final watch = Stopwatch()..start();
    final geometry = await loadWorldViewConeGeometry(map,
        bundle: _Bundle(directory), chunked: true);
    final loadMicros = watch.elapsedMicroseconds;
    final routes = [
      for (final row in reference['routes'])
        _Route(row as Map<String, dynamic>, geometry.worldData!.projection!)
    ];
    if (routes.length != 10) throw StateError('Expected ten walking routes.');
    final simulatedHz =
        int.parse(Platform.environment['ICARUS_SIMULATED_HZ'] ?? '144');
    final prepareWatch = Stopwatch()..start();
    final prepared = Platform.environment['ICARUS_PREPARED_INPUTS'] == '1'
        ? _prepare(geometry, routes, simulatedHz)
        : null;
    final preparationMicros = prepareWatch.elapsedMicroseconds;
    final program = mode == 'radial'
        ? await ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag')
        : null;
    await windowManager.ensureInitialized();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    await windowManager.setSize(
        Size(1920 / view.devicePixelRatio, 1080 / view.devicePixelRatio));
    await windowManager.setTitle('Icarus $mode renderer prototype');
    runApp(_Probe(
        geometry,
        routes,
        output,
        mode,
        simulatedHz,
        loadMicros,
        prepared,
        preparationMicros,
        program,
        double.parse(Platform.environment['ICARUS_CLEARANCE_PIXELS'] ?? '0')));
  } catch (error, stack) {
    await output.writeAsString(
        jsonEncode({'status': 'failed', 'error': '$error', 'stack': '$stack'}));
    exit(1);
  }
}
