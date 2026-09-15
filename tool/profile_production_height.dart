import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/height_runtime_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:window_manager/window_manager.dart';

class _Map extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.split, isAttack: true);
}

Map<String, Object> _summary(Iterable<num> values, {bool frameTimes = true}) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) return {'samples': 0};
  num percentile(double value) => sorted[((sorted.length - 1) * value).round()];
  return {
    'samples': sorted.length,
    'median': percentile(.5),
    'p95': percentile(.95),
    'maximum': sorted.last,
    if (frameTimes)
      'within144Hz': sorted.where((value) => value <= 1000000 / 144).length,
  };
}

class _Probe extends StatefulWidget {
  const _Probe(this.container, this.runtime, this.queries, this.frames, this.hz,
      this.output, this.movingIndex);
  final ProviderContainer container;
  final HeightRuntime runtime;
  final Float64List queries;
  final int frames, hz, movingIndex;
  final File output;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  late final Ticker ticker;
  final boundary = GlobalKey();
  final timings = <ui.FrameTiming>[];
  final paints = <Map<String, num>>[];
  final computations = <Map<String, num>>[];
  final requests = <int>{};
  final origins = <(int, int), int>{};
  var frame = 0;
  var recording = false;
  var finishing = false;

  @override
  void initState() {
    super.initState();
    for (var index = 0; index < widget.frames; index++) {
      final at = index * 70 + widget.movingIndex * 7;
      origins[(
        (widget.queries[at] * 1000000).round(),
        (widget.queries[at + 1] * 1000000).round()
      )] = index;
    }
    widget.runtime.renderer.onPaint = (slot, mesh, origin) {
      if (!recording) return;
      final completed = origins[(
        (origin.dx * 1000000).round(),
        (origin.dy * 1000000).round()
      )];
      if (completed == null) return;
      paints.add({
        'frame': frame,
        'completedFrame': completed,
        'clockMicros': developer.Timeline.now,
        'visibleMesh': 1,
        'poseLagFrames': frame - completed
      });
    };
    SchedulerBinding.instance.addTimingsCallback(_timings);
    widget.runtime.queue.onComputed = (result, queries, elapsed) {
      if (!recording) return;
      computations.add({
        'desiredFrame': frame,
        'stamp': result.stamp,
        'cones': queries.length ~/ 7,
        'roundTripMicros': elapsed,
        'bytes': result.positions.lengthInBytes,
        ...result.timings,
      });
    };
    ticker = createTicker((elapsed) {
      final desired = (elapsed.inMicroseconds * widget.hz / 1000000).floor();
      if (desired >= widget.frames) {
        if (!finishing) {
          finishing = true;
          unawaited(_finish());
        }
        return;
      }
      if (desired == frame) return;
      requests.add(desired);
      setState(() => frame = desired);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.runtime.queue.waitIdle();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      recording = true;
      ticker.start();
    });
  }

  void _timings(List<ui.FrameTiming> rows) => timings.addAll(rows);

  Future<void> _finish() async {
    ticker.stop();
    recording = false;
    try {
      await widget.runtime.queue.waitIdle();
      await Future<void>.delayed(const Duration(seconds: 2));
      final rows = <Map<String, num>>[];
      for (final paint in paints) {
        final matching = timings.where((timing) =>
            timing.timestampInMicroseconds(ui.FramePhase.buildStart) <=
                paint['clockMicros']! &&
            timing.timestampInMicroseconds(ui.FramePhase.buildFinish) >=
                paint['clockMicros']!);
        if (matching.length != 1) continue;
        final timing = matching.single;
        rows.add({
          ...paint,
          'buildMicros': timing.buildDuration.inMicroseconds,
          'rasterMicros': timing.rasterDuration.inMicroseconds
        });
      }
      final image = await (boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${widget.output.path}.png')
          .writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
      final steady = rows.where((row) => row['frame']! >= 60).toList();
      final steadyComputes =
          computations.where((row) => row['desiredFrame']! >= 60).toList();
      final renderer = widget.runtime.renderer;
      final report = <String, Object?>{
        'status':
            steady.isNotEmpty && steady.every((row) => row['visibleMesh'] == 1)
                ? 'passed'
                : 'failed',
        'scope':
            'Real ViewConeWidget, production providers, asset loader, queue, native worker and renderer. FrameTiming is Flutter CPU/raster scheduling, not physical GPU presentation.',
        'movingIndex': widget.movingIndex,
        'fixtureFrames': widget.frames,
        'requestedFrames': requests.length,
        'steadyUniqueRequested': requests.where((frame) => frame >= 60).length,
        'steadyPaints': steady.length,
        'steadyVisiblePaints':
            steady.where((row) => row['visibleMesh'] == 1).length,
        'steadyHiddenPaints':
            steady.where((row) => row['visibleMesh'] == 0).length,
        'steadyDistinctVisibleFrames': steady
            .where((row) => row['visibleMesh'] == 1)
            .map((row) => row['frame'])
            .toSet()
            .length,
        'steadyDistinctCompletedPoses':
            steady.map((row) => row['completedFrame']).toSet().length,
        'poseLagFrames': _summary(steady.map((row) => row['poseLagFrames']!),
            frameTimes: false),
        'compute':
            _summary(steadyComputes.map((row) => row['roundTripMicros']!)),
        'build': _summary(steady.map((row) => row['buildMicros']!)),
        'raster': _summary(steady.map((row) => row['rasterMicros']!)),
        'residentBeforeClose': ProcessInfo.currentRss,
        'cacheHits': renderer.cacheHits,
        'cacheMisses': renderer.cacheMisses,
        'residentImages': renderer.residentImages,
        'estimatedImageBytes': renderer.estimatedRgbaBytes,
        'paints': rows,
        'computations': computations,
      };
      runApp(const SizedBox());
      await WidgetsBinding.instance.endOfFrame;
      await closeHeightRuntimes();
      report['residentImagesAfterClose'] = renderer.residentImages;
      report['residentAfterClose'] = ProcessInfo.currentRss;
      await widget.output
          .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      widget.container.dispose();
      await windowManager.close();
    } catch (error, stack) {
      await widget.output.writeAsString(jsonEncode(
          {'status': 'failed', 'error': '$error', 'stack': '$stack'}));
      await closeHeightRuntimes();
      await windowManager.close();
    }
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    widget.runtime.queue.onComputed = null;
    widget.runtime.renderer.onPaint = null;
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
      home: ColoredBox(
          color: Settings.tacticalVioletTheme.background,
          child: Center(
              child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: LayoutBuilder(builder: (context, constraints) {
                    CoordinateSystem(playAreaSize: constraints.biggest);
                    final coordinates = CoordinateSystem.instance;
                    final anchor = ViewConeWidget.anchorPointVirtual *
                        coordinates.scaleFactor;
                    return RepaintBoundary(
                        key: boundary,
                        child: Stack(clipBehavior: Clip.none, children: [
                          Center(
                              child: SizedBox(
                                  width: constraints.maxHeight * 1.24,
                                  height: constraints.maxHeight,
                                  child: SvgPicture.asset(
                                      'assets/maps/split_map.svg'))),
                          for (var index = 0; index < 10; index++)
                            _cone(index, coordinates, anchor),
                        ]));
                  })))));

  Widget _cone(int index, CoordinateSystem coordinates, Offset anchor) {
    final poseFrame = index == widget.movingIndex ? frame : 0;
    final at = poseFrame * 70 + index * 7;
    final query = widget.queries;
    final projection = widget.runtime.assets.projection;
    final world = projection.toCanvas(Offset(query[at], query[at + 1]));
    final direction =
        projection.axisU * query[at + 3] + projection.axisV * query[at + 4];
    final rotation = math.atan2(direction.dy, direction.dx) + math.pi / 2;
    final length = query[at + 5] *
        direction.distance /
        coordinates.virtualLengthToWorld(1);
    final position = coordinates.coordinateToScreen(world) - anchor;
    return Positioned(
        key: ValueKey(index),
        left: position.dx,
        top: position.dy,
        child: Transform.rotate(
            angle: rotation,
            alignment: Alignment.topLeft,
            origin: anchor,
            child: ViewConeWidget(
                id: null,
                worldOrigin: world,
                angle: query[at + 6] * 180 / math.pi,
                rotation: rotation,
                length: length,
                showCenterMarker: false)));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final environment = Platform.environment;
  final output = File(environment['ICARUS_AUDIT_OUTPUT']!);
  await output.parent.create(recursive: true);
  if (environment['ICARUS_EMPTY_WINDOW'] == '1') {
    runApp(const ColoredBox(color: Colors.black));
    await Future<void>.delayed(const Duration(seconds: 2));
    await output.writeAsString(jsonEncode({
      'status': 'passed',
      'scope':
          'Empty Flutter window, no assets, height runtime, shaders or library data loaded.'
    }));
    await windowManager.close();
    return;
  }
  try {
    final fixture = jsonDecode(
        await File(environment['ICARUS_HEIGHT_FIXTURE']!).readAsString());
    final queries =
        Float64List.sublistView(await File(fixture['queryFile']).readAsBytes());
    final container =
        ProviderContainer(overrides: [mapProvider.overrideWith(_Map.new)]);
    final runtimeSubscription =
        container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    final geometrySubscription =
        container.listen(viewConeGeometryProvider(MapValue.split), (_, __) {});
    final runtime =
        await container.read(heightRuntimeProvider(MapValue.split).future);
    await container.read(viewConeGeometryProvider(MapValue.split).future);
    // Keep the production providers alive until the window owns their widgets.
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    await windowManager.setSize(
        Size(1920 / view.devicePixelRatio, 1080 / view.devicePixelRatio));
    await windowManager
        .setTitle('Icarus production sightline performance check');
    runApp(UncontrolledProviderScope(
        container: container,
        child: _Probe(
            container,
            runtime,
            queries,
            fixture['frameCount'],
            fixture['simulatedHz'],
            output,
            int.parse(environment['ICARUS_MOVING_INDEX'] ?? '4'))));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      runtimeSubscription.close();
      geometrySubscription.close();
    });
  } catch (error, stack) {
    await output.writeAsString(
        jsonEncode({'status': 'failed', 'error': '$error', 'stack': '$stack'}));
    await closeHeightRuntimes();
    await windowManager.close();
  }
}
