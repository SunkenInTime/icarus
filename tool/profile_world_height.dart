import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/height_render.dart';
import 'package:icarus/view_cone/receiver_compositor.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/tactical_ground_field.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';
import 'package:window_manager/window_manager.dart';

import 'world_height_native.dart';
import 'world_height_cached_queries.dart';

Future<String> _sha(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

Map<String, Object> summarize(Iterable<num> source) {
  final values = source.toList()..sort();
  if (values.isEmpty) return {'samples': 0};
  num p(double fraction) => values[((values.length - 1) * fraction).round()];
  return {
    'samples': values.length,
    'median': p(.5),
    'p95': p(.95),
    'maximum': values.last,
    'within144Hz': values.where((v) => v <= 1e6 / 144).length,
    'within240Hz': values.where((v) => v <= 1e6 / 240).length
  };
}

class HeightProbe extends StatefulWidget {
  const HeightProbe(
      {super.key,
      required this.worker,
      required this.fixture,
      required this.queries,
      required this.receiver,
      required this.art,
      required this.program,
      required this.output,
      required this.projection,
      this.displayWarp});
  final HeightNativeWorker worker;
  final Map<String, dynamic> fixture;
  final Float64List queries;
  final WorldReceiverMask receiver;
  final ui.Picture art;
  final ui.FragmentProgram program;
  final File output;
  final VisionWorldProjection projection;
  final DisplayWarp? displayWarp;
  @override
  State<HeightProbe> createState() => _HeightProbeState();
}

class _HeightProbeState extends State<HeightProbe>
    with SingleTickerProviderStateMixin {
  late final Ticker ticker;
  late final painter = _HeightPainter(widget);
  late final scene = HeightSceneComputer(widget.worker.compute);
  final boundary = GlobalKey();
  final frameTimings = <ui.FrameTiming>[];
  final computations = <Map<String, num>>[];
  var desired = -1;
  var lastSubmitted = -1;
  final requested = <int>{};
  var busy = false;
  var finishing = false;
  Future<void>? active;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    ticker = createTicker((elapsed) {
      desired = (elapsed.inMicroseconds *
              (widget.fixture['simulatedHz'] as int) /
              1000000)
          .floor();
      if (desired >= widget.fixture['frames']) {
        if (!finishing) {
          finishing = true;
          unawaited(_finish().catchError(
              (Object error, StackTrace stack) => _fail(error, stack)));
        }
        return;
      }
      requested.add(desired);
      if (!busy && desired > lastSubmitted) active = _compute(desired);
    })
      ..start();
  }

  void _timings(List<ui.FrameTiming> values) => frameTimings.addAll(values);

  Future<void> _compute(int stamp) async {
    busy = true;
    lastSubmitted = stamp;
    final started = developer.Timeline.now;
    try {
      final count = widget.fixture['conesPerFrame'] as int;
      final input = Float64List.sublistView(
          widget.queries, stamp * count * 7, (stamp + 1) * count * 7);
      final result = await scene.compute(stamp, input);
      computations.add({
        'stamp': stamp,
        'submittedMicros': started,
        'roundTripMicros': developer.Timeline.now - started,
        'outputBytes': result.transferredBytes,
        'changedCones': result.changedCones,
        ...result.timings
      });
      painter.frame = result;
      painter.submitted = started;
      painter.input = input;
      painter.updated();
    } catch (error, stack) {
      await _fail(error, stack);
    } finally {
      busy = false;
      if (!finishing && desired > stamp) active = _compute(desired);
    }
  }

  Future<void> _fail(Object error, StackTrace stack) async {
    ticker.stop();
    await widget.output.writeAsString(
        jsonEncode({'status': 'failed', 'error': '$error', 'stack': '$stack'}));
    await windowManager.close();
  }

  Future<void> _finish() async {
    ticker.stop();
    await active;
    await Future<void>.delayed(const Duration(seconds: 2));
    final rows = <Map<String, num>>[];
    for (final row in painter.records) {
      final matching = frameTimings.where((timing) =>
          timing.timestampInMicroseconds(ui.FramePhase.buildStart) <=
              row['paintClockMicros']! &&
          timing.timestampInMicroseconds(ui.FramePhase.buildFinish) >=
              row['paintClockMicros']!);
      if (matching.length != 1) continue;
      final timing = matching.single;
      rows.add({
        ...row,
        'buildMicros': timing.buildDuration.inMicroseconds,
        'rasterMicros': timing.rasterDuration.inMicroseconds,
        'pipelineMicros': math.max(timing.buildDuration.inMicroseconds,
            timing.rasterDuration.inMicroseconds),
        'submitToRasterFinishMicros':
            timing.timestampInMicroseconds(ui.FramePhase.rasterFinish) -
                row['submittedMicros']!
      });
    }
    final image = await (boundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary)
        .toImage();
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('${widget.output.path}.png')
        .writeAsBytes(png.buffer.asUint8List());
    image.dispose();
    final warmup = widget.fixture['warmupFrames'] as int? ?? 60;
    final steady = rows.where((row) => row['stamp']! >= warmup).toList();
    final compute =
        computations.where((row) => row['stamp']! >= warmup).toList();
    final drawIntervals = <num>[
      for (var i = 1; i < steady.length; i++)
        steady[i]['paintClockMicros']! - steady[i - 1]['paintClockMicros']!
    ];
    final residentBeforeClose = ProcessInfo.currentRss;
    await widget.worker.close();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final report = <String, Object?>{
      'status': 'complete',
      'map': widget.fixture['map'],
      'fixturePath': Platform.environment['ICARUS_HEIGHT_FIXTURE'],
      'nativeInfo': widget.worker.info,
      'displayRefreshRate': view.display.refreshRate,
      'requestedReplayHz': widget.fixture['simulatedHz'],
      'warmupFrames': warmup,
      'frozenReplay': widget.fixture['frozenReplay'] ?? false,
      'displayWarpEnabled': widget.displayWarp != null,
      'inputBindings': widget.fixture['profileInputBindings'],
      'effectiveQueriesSha256': await _sha(widget.queries.buffer.asUint8List()),
      'sourceMeshSha256': [
        for (final mesh in painter.frame!.meshes)
          await _sha(
              mesh.buffer.asUint8List(mesh.offsetInBytes, mesh.lengthInBytes))
      ],
      'sourceMeshBytes': painter.frame!.meshBytes,
      'steadyDrawIntervalsMicros': summarize(drawIntervals),
      'steadyDrawIntervalsOver144Hz':
          drawIntervals.where((v) => v > 1e6 / 144).length,
      'steadyDrawIntervalsOverTwo144HzFrames':
          drawIntervals.where((v) => v > 2e6 / 144).length,
      'steadyDistinctDrawStamps': steady.map((r) => r['stamp']).toSet().length,
      'devicePixelRatio': view.devicePixelRatio,
      'resolution': [view.physicalSize.width, view.physicalSize.height],
      'movingCones': widget.fixture['movingCones'],
      'unchangedQueriesReuseExactMeshes': true,
      'cachedShadowImages': painter.cacheImages,
      'imageCache': {
        'hits': painter.cachedRenderer.cacheHits,
        'misses': painter.cachedRenderer.cacheMisses,
        'residentImages': painter.cachedRenderer.residentImages,
        'estimatedRgbaBytes': painter.cachedRenderer.estimatedRgbaBytes
      },
      'receiverMaskIncluded': true,
      'ffiTransferIncluded': true,
      'precomputedShadowMeshes': false,
      'oneComputationInFlight': true,
      'markersUseCompletedPose': true,
      'fixturePoseCount': widget.fixture['frames'],
      'requestedPoseCount': requested.length,
      'coalescedPoseCount': requested
          .difference(computations.map((r) => r['stamp']!.toInt()).toSet())
          .length,
      'completedPoseCount': computations.length,
      'paintedPoseCount': rows.map((row) => row['stamp']).toSet().length,
      'matchedPaintTimings': rows.length,
      'paintRecords': painter.records.length,
      'computeSummaries': {
        for (final key in [
          'roundTripMicros',
          'computeWallMicros',
          'computeAndCopyMicros',
          'outputBytes'
        ])
          key: summarize(compute.map((r) => r[key]!))
      },
      'renderSummaries': {
        for (final key in [
          'buildMicros',
          'rasterMicros',
          'pipelineMicros',
          'submitToRasterFinishMicros'
        ])
          key: summarize(steady.map((r) => r[key]!))
      },
      'residentBeforeCloseBytes': residentBeforeClose,
      'residentAfterCloseBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
      'computations': computations,
      'renderFrames': rows,
      'scope':
          'Isolated actual Windows production-renderer profile. Frozen replay reuses the same ten native meshes. FrameTiming and draw intervals describe Flutter scheduling, not measured physical display presentation. Source-floor policy remains provisional. No library is opened.',
    };
    runApp(const SizedBox());
    await WidgetsBinding.instance.endOfFrame;
    report['residentImagesAfterClose'] = painter.cachedRenderer.residentImages;
    report['disposedImagesAfterClose'] = painter.cachedRenderer.disposedImages;
    await widget.output
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) => Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
          color: Settings.abilityBGColor,
          child: RepaintBoundary(
              key: boundary,
              child: CustomPaint(painter: painter, size: Size.infinite))));

  @override
  void dispose() {
    ticker.dispose();
    painter.disposeShaders();
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    super.dispose();
  }
}

class _Pulse extends ChangeNotifier {
  void update() => notifyListeners();
}

class _HeightPainter extends CustomPainter {
  _HeightPainter(HeightProbe probe) : this._(probe, _Pulse());
  _HeightPainter._(this.probe, this.pulse)
      : shaders = List.generate(10, (_) => probe.program.fragmentShader()),
        super(repaint: pulse);
  final HeightProbe probe;
  final _Pulse pulse;
  final List<ui.FragmentShader> shaders;
  final renderer = WorldHeightRenderer();
  final cachedRenderer = WorldHeightCachedRenderer();
  final cacheImages = Platform.environment['ICARUS_CACHE_IMAGES'] != '0';
  final records = <Map<String, num>>[];
  HeightSceneFrame? frame;
  Float64List? input;
  int submitted = 0;
  void updated() => pulse.update();
  @override
  void paint(Canvas canvas, Size size) {
    final current = frame, queries = input;
    final box = probe.receiver.viewBox;
    final screenScale =
        math.min(size.width / (1000 * 16 / 9), size.height / 1000);
    final scale = math.min(1240 / box.width, 1000 / box.height) * screenScale;
    final physicalScale = scale *
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    canvas.save();
    canvas.translate((size.width - box.width * scale) / 2,
        (size.height - box.height * scale) / 2);
    canvas.scale(scale);
    canvas.drawPicture(probe.art);
    if (current != null && queries != null) {
      paintWorldReceiverVisibility(
          canvas: canvas,
          receiver: probe.receiver,
          paintVisibility: (canvas) {
            for (var i = 0; i < current.meshes.length; i++) {
              final at = i * 7;
              final origin = probe.projection
                  .toCanvas(Offset(queries[at], queries[at + 1]));
              final color =
                  (i < 5 ? Settings.allyBGColor : Settings.enemyBGColor)
                      .withValues(alpha: .5);
              if (cacheImages) {
                cachedRenderer.paintCone(
                    canvas,
                    current.meshes[i],
                    probe.projection,
                    origin,
                    math.atan2(queries[at + 4], queries[at + 3]),
                    queries[at + 5],
                    queries[at + 6],
                    physicalScale,
                    color,
                    shaders[i],
                    coneId: i,
                    meshKey: current.meshes[i],
                    viewport: probe.receiver.viewBox,
                    displayWarp: probe.displayWarp);
              } else {
                renderer.paintCone(
                    canvas,
                    current.meshes[i],
                    probe.projection,
                    origin,
                    math.atan2(queries[at + 4], queries[at + 3]),
                    queries[at + 5],
                    queries[at + 6],
                    physicalScale,
                    color,
                    shaders[i]);
              }
            }
          });
      for (var i = 0; i < current.meshes.length; i++) {
        final at = i * 7;
        canvas.drawCircle(
            probe.projection.toCanvas(probe.displayWarp
                    ?.targetAt(Offset(queries[at], queries[at + 1])) ??
                Offset(queries[at], queries[at + 1])),
            3 / scale,
            Paint()
              ..color = (i < 5 ? Settings.allyBGColor : Settings.enemyBGColor));
      }
      records.add({
        'stamp': current.stamp,
        'paintClockMicros': developer.Timeline.now,
        'submittedMicros': submitted,
        'meshBytes': current.meshBytes
      });
    }
    canvas.restore();
  }

  void disposeShaders() {
    cachedRenderer.dispose();
    for (final shader in shaders) {
      shader.dispose();
    }
    pulse.dispose();
  }

  @override
  bool shouldRepaint(covariant _HeightPainter oldDelegate) =>
      oldDelegate.frame != frame;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final output = File(environment['ICARUS_AUDIT_OUTPUT']!);
  await output.parent.create(recursive: true);
  try {
    final fixture = jsonDecode(
            await File(environment['ICARUS_HEIGHT_FIXTURE']!).readAsString())
        as Map<String, dynamic>;
    fixture['frames'] = fixture['frameCount'];
    fixture['conesPerFrame'] = fixture['agentCount'];
    fixture['queriesFile'] = fixture['queryFile'];
    fixture['svgPath'] = (fixture['provenance']['receiverSvgs'] as List)
        .firstWhere((row) => row['defense'] == false)['path'];
    final affine = fixture['projection']['nativeToSvg'] as List;
    fixture['nativeToSvg'] = {
      'origin': [affine[0][2], affine[1][2]],
      'axisU': [affine[0][0], affine[1][0]],
      'axisV': [affine[0][1], affine[1][1]]
    };
    final bytes = await File(fixture['queriesFile'] as String).readAsBytes();
    var queries = Float64List.sublistView(bytes);
    if (queries.length !=
        (fixture['frames'] as int) * (fixture['conesPerFrame'] as int) * 7)
      throw StateError('Fixture record count mismatch.');
    final moving = int.parse(environment['ICARUS_MOVING_CONES'] ?? '10');
    if (moving < 1 || moving > 10)
      throw ArgumentError('Invalid moving cone count.');
    fixture['movingCones'] = moving;
    fixture['warmupFrames'] =
        int.parse(environment['ICARUS_WARMUP_FRAMES'] ?? '60');
    fixture['frozenReplay'] = environment['ICARUS_FROZEN_REPLAY'] == '1';
    if (fixture['frozenReplay'] == true) {
      final first = Float64List.fromList(queries.take(70).toList());
      fixture['frames'] =
          int.parse(environment['ICARUS_REPLAY_FRAMES'] ?? '1440');
      queries = Float64List((fixture['frames'] as int) * 70);
      for (var frame = 0; frame < fixture['frames']; frame++) {
        queries.setRange(frame * 70, (frame + 1) * 70, first);
      }
      fixture['movingCones'] = 0;
    }
    for (var frame = 1; frame < fixture['frames']; frame++) {
      for (var i = moving; i < 10; i++) {
        queries.setRange(
            frame * 70 + i * 7, frame * 70 + i * 7 + 7, queries, i * 7);
      }
    }
    final source = await File(fixture['svgPath'] as String).readAsString();
    final receiver = WorldReceiverMask.parse(source);
    final art = await vg.loadPicture(SvgStringLoader(source), null);
    final matrix = fixture['nativeToSvg'] as Map;
    Offset pair(dynamic p) =>
        Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
    final projection = VisionWorldProjection(
        origin: pair(matrix['origin']),
        axisU: pair(matrix['axisU']),
        axisV: pair(matrix['axisV']));
    final bindingsPath = environment['ICARUS_INPUT_BINDINGS'];
    if (bindingsPath != null) {
      fixture['profileInputBindings'] =
          jsonDecode(await File(bindingsPath).readAsString());
    }
    if (environment['ICARUS_TACTICAL_GROUND_FILE'] != null) {
      final fieldBytes =
          await File(environment['ICARUS_TACTICAL_GROUND_FILE']!).readAsBytes();
      final ground = TacticalGroundField.fromJson(
          jsonDecode(utf8.decode(gzip.decode(fieldBytes)))
              as Map<String, dynamic>);
      for (var i = 0; i < queries.length; i += 7) {
        final height = ground.heightAt(Offset(queries[i], queries[i + 1]));
        if (height == null)
          throw StateError('Replay pose outside source ground field.');
        queries[i + 2] -= height;
      }
    }
    DisplayWarp? displayWarp;
    final warpPath = environment['ICARUS_DISPLAY_WARP_FILE'];
    if (warpPath != null) {
      final warpBytes = await File(warpPath).readAsBytes();
      if (await _sha(warpBytes) != environment['ICARUS_DISPLAY_WARP_SHA256']) {
        throw StateError('Display warp checksum mismatch.');
      }
      final raw = await File(
              '${environment['ICARUS_HEIGHT_DIRECTORY']}/height-source.raw')
          .open();
      late Map<String, dynamic> header;
      try {
        final prefix = await raw.read(8);
        if (ascii.decode(prefix.take(4).toList()) != 'IHD1')
          throw StateError('Invalid native pack.');
        final length = ByteData.sublistView(prefix).getUint32(4, Endian.little);
        header = jsonDecode(utf8.decode(await raw.read(length)))
            as Map<String, dynamic>;
      } finally {
        await raw.close();
      }
      final warp = DisplayWarp.fromJson(
          jsonDecode(utf8.decode(gzip.decode(warpBytes)))
              as Map<String, dynamic>,
          expectedMap: fixture['map'] as String,
          expectedProjection: projection,
          expectedSourceGeometrySha256:
              header['sourceGeometrySha256'] as String);
      final defensePath = (fixture['provenance']['receiverSvgs'] as List)
          .firstWhere((row) => row['defense'] == true)['path'] as String;
      await verifyDisplayWarpArtwork(
          warp, source, await File(defensePath).readAsString());
      if (environment['ICARUS_DISPLAY_WARP_ENABLED'] != '0') displayWarp = warp;
    }
    final program =
        await ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
    final worker = await HeightNativeWorker.open(
        environment['ICARUS_HEIGHT_DLL']!,
        environment['ICARUS_HEIGHT_DIRECTORY']!,
        4);
    await windowManager.ensureInitialized();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    await windowManager.setSize(
        Size(1920 / view.devicePixelRatio, 1080 / view.devicePixelRatio));
    await windowManager.setTitle('Icarus direct-height visibility prototype');
    runApp(HeightProbe(
        worker: worker,
        fixture: fixture,
        queries: queries,
        receiver: receiver,
        art: art.picture,
        program: program,
        output: output,
        projection: projection,
        displayWarp: displayWarp));
  } catch (error, stack) {
    await output.writeAsString(
        jsonEncode({'status': 'failed', 'error': '$error', 'stack': '$stack'}));
    await windowManager.close();
  }
}
