import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:window_manager/window_manager.dart';

class _FixtureMap extends MapProvider {
  _FixtureMap(this.map);
  final MapValue map;
  @override
  MapState build() => MapState(currentMap: map, isAttack: true);
}

class _Scenario {
  const _Scenario(this.name, this.zoom, this.moveAll);

  final String name;
  final double zoom;
  final bool moveAll;
}

const _scenarios = [
  _Scenario('one-observer-zoom-1', 1, false),
  _Scenario('ten-observers-zoom-1', 1, true),
  _Scenario('one-observer-zoom-4', 4, false),
  _Scenario('ten-observers-zoom-4', 4, true),
];

Map<String, Object> _summary(Iterable<int> input) {
  final values = input.toList()..sort();
  if (values.isEmpty) return {'samples': 0};
  int percentile(double p) => values[((values.length - 1) * p).round()];
  return {
    'samples': values.length,
    'medianMicros': percentile(.5),
    'p95Micros': percentile(.95),
    'maximumMicros': values.last,
    // Timestamps use whole microseconds: 144 Hz alternates 6944/6945 us.
    'within144Hz':
        values.where((value) => value <= (1000000 / 144).ceil()).length,
  };
}

class _Probe extends StatefulWidget {
  const _Probe({
    required this.container,
    required this.runtime,
    required this.fixture,
    required this.output,
    required this.movingIndex,
  });

  final ProviderContainer container;
  final SvgHeightRuntime runtime;
  final Map<String, dynamic> fixture;
  final File output;
  final int movingIndex;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  static const _warmupFixtureFrames = 30;
  static const _measurement = Duration(seconds: 3);
  static const _timingTail = Duration(milliseconds: 250);

  final boundary = GlobalKey();
  final reports = <Map<String, Object?>>[];
  final inputEvents = <Map<String, Object>>[];
  final scenarioTimings = <ui.FrameTiming>[];
  late final Ticker ticker;
  var scenarioIndex = 0;
  var frame = 0;
  var recording = false;
  var advancing = false;
  var scenarioStoppedMicros = 0;
  (int, int, int, double) queryStart = (0, 0, 0, 0);

  List<dynamic> get frames => widget.fixture['frames'] as List<dynamic>;
  int get simulatedHz => widget.fixture['simulatedHz'] as int;
  Duration get warmup => Duration(
        microseconds: _warmupFixtureFrames * 1000000 ~/ simulatedHz,
      );
  Duration get scenarioDuration => warmup + _measurement + _timingTail;
  _Scenario get scenario => _scenarios[scenarioIndex];

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_recordTimings);
    ticker = createTicker(_tick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScenario());
  }

  void _recordTimings(List<ui.FrameTiming> timings) {
    if (recording) scenarioTimings.addAll(timings);
  }

  void _tick(Duration elapsed) {
    final desired = (elapsed.inMicroseconds * simulatedHz / 1000000).floor();
    if (elapsed >= scenarioDuration) {
      if (!advancing) {
        advancing = true;
        unawaited(_completeScenario());
      }
      return;
    }
    if (desired == frame) return;
    final moved = scenario.moveAll
        ? List<int>.generate(10, (index) => index)
        : [widget.movingIndex];
    inputEvents.add({
      'scenario': scenario.name,
      'frameIndex': desired,
      'fixtureFrame': desired % frames.length,
      'clockMicros': developer.Timeline.now,
      'observers': moved,
    });
    setState(() => frame = desired);
  }

  Future<void> _startScenario() async {
    widget.container
        .read(screenZoomProvider.notifier)
        .updateZoom(scenario.zoom);
    setState(() => frame = 0);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    scenarioTimings.clear();
    recording = true;
    advancing = false;
    scenarioStoppedMicros = 0;
    final cache = widget.runtime.attackCache;
    queryStart = (
      cache.queryCount,
      cache.reuseCount,
      cache.totalQueryMicroseconds,
      cache.totalNativeQueryMicroseconds
    );
    ticker.start();
  }

  Future<void> _completeScenario() async {
    ticker.stop(canceled: true);
    scenarioStoppedMicros = developer.Timeline.now;
    // FrameTiming delivery can trail the frame that stopped the ticker. Keep
    // accepting callbacks until the pending engine batch has arrived.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    recording = false;
    final firstVsync = scenarioTimings.isEmpty
        ? 0
        : scenarioTimings.first
            .timestampInMicroseconds(ui.FramePhase.vsyncStart);
    final warmupCutoff = firstVsync + warmup.inMicroseconds;
    final measured = scenarioTimings.where((timing) {
      final vsync = timing.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      return vsync >= warmupCutoff && vsync <= scenarioStoppedMicros;
    }).toList();
    final vsyncStarts = [
      for (final timing in measured)
        timing.timestampInMicroseconds(ui.FramePhase.vsyncStart),
    ];
    final vsyncIntervals = [
      for (var index = 1; index < vsyncStarts.length; index++)
        vsyncStarts[index] - vsyncStarts[index - 1],
    ];
    final scenarioInputs = inputEvents
        .where((event) => event['scenario'] == scenario.name)
        .toList();
    final inputIntervals = [
      for (var index = 1; index < scenarioInputs.length; index++)
        (scenarioInputs[index]['clockMicros'] as int) -
            (scenarioInputs[index - 1]['clockMicros'] as int),
    ];
    reports.add({
      'name': scenario.name,
      'zoom': scenario.zoom,
      'movingObservers': scenario.moveAll ? 10 : 1,
      'queryWorkIncludingWarmup': {
        'computedCones': widget.runtime.attackCache.queryCount - queryStart.$1,
        'reusedCones': widget.runtime.attackCache.reuseCount - queryStart.$2,
        'totalQueryMicros':
            widget.runtime.attackCache.totalQueryMicroseconds - queryStart.$3,
        'nativeQueryMicros':
            widget.runtime.attackCache.totalNativeQueryMicroseconds -
                queryStart.$4,
      },
      'requestedInputEvents': scenarioInputs.length,
      'inputEvents': scenarioInputs.length,
      'deliveredFrames': measured.length,
      'timingCallbacks': scenarioTimings.length,
      'measuredTimings': measured.length,
      'warmupFixtureFrames': _warmupFixtureFrames,
      'warmupMicros': warmup.inMicroseconds,
      'requestedMeasurementMicros': _measurement.inMicroseconds,
      'actualMeasuredVsyncSpanMicros':
          vsyncStarts.length < 2 ? 0 : vsyncStarts.last - vsyncStarts.first,
      'inputIntervals': _summary(inputIntervals),
      'vsyncIntervals': _summary(vsyncIntervals),
      'build':
          _summary(measured.map((row) => row.buildDuration.inMicroseconds)),
      'raster':
          _summary(measured.map((row) => row.rasterDuration.inMicroseconds)),
      'totalSpan':
          _summary(measured.map((row) => row.totalSpan.inMicroseconds)),
      'frames': [
        for (var index = 0; index < measured.length; index++)
          {
            'callbackIndex': index,
            'vsyncStartMicros': measured[index]
                .timestampInMicroseconds(ui.FramePhase.vsyncStart),
            'buildStartMicros': measured[index]
                .timestampInMicroseconds(ui.FramePhase.buildStart),
            'buildMicros': measured[index].buildDuration.inMicroseconds,
            'rasterMicros': measured[index].rasterDuration.inMicroseconds,
            'totalSpanMicros': measured[index].totalSpan.inMicroseconds,
          },
      ],
    });
    if (scenarioIndex + 1 < _scenarios.length) {
      scenarioIndex++;
      await _startScenario();
    } else {
      await _finish();
    }
  }

  Future<void> _finish() async {
    try {
      final renderBoundary =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final ratio = WidgetsBinding
          .instance.platformDispatcher.views.first.devicePixelRatio;
      final image = await renderBoundary.toImage(pixelRatio: ratio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final screenshot = File('${widget.output.path}.png');
      await screenshot.writeAsBytes(png!.buffer.asUint8List());
      final report = {
        'status': reports.every((row) =>
                (row['measuredTimings'] as int) > 0 &&
                (row['actualMeasuredVsyncSpanMicros'] as int) >=
                    _measurement.inMicroseconds - 100000)
            ? 'passed'
            : 'failed',
        'scope':
            'Production ${widget.runtime.map.name} provider and ten real ViewConeWidget instances. '
                'FrameTiming measures Flutter build, raster and total frame span; '
                'it does not measure physical display presentation.',
        'windowPhysicalPixels': [image.width, image.height],
        'fixture': Platform.environment['ICARUS_HEIGHT_FIXTURE'],
        'fixtureFrames': frames.length,
        'movingIndex': widget.movingIndex,
        'cacheEntries': widget.runtime.attackCache.observerCount,
        'nativeAcceleration': widget.runtime.attack.usesNativeAcceleration &&
            widget.runtime.defense.usesNativeAcceleration,
        'residentBytes': ProcessInfo.currentRss,
        'scenarios': reports,
        'inputTraffic': inputEvents,
        'screenshot': screenshot.path,
      };
      image.dispose();
      report['exitProtocol'] =
          'Standalone probe terminates after flushing its report; native plugin teardown is outside this measurement.';
      await widget.output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true);
      // This standalone measurement process owns no user data. Exit after the
      // flushed report; unmounting the Windows plugin tree can throw in native
      // teardown and must not discard an otherwise complete measurement.
      _exitProbe(0);
    } catch (error, stack) {
      await widget.output.writeAsString(jsonEncode({
        'status': 'failed',
        'error': '$error',
        'stack': '$stack',
      }));
      exit(1);
    }
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_recordTimings);
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: ColoredBox(
          color: Settings.tacticalVioletTheme.background,
          child: LayoutBuilder(builder: (context, constraints) {
            CoordinateSystem(playAreaSize: constraints.biggest);
            return RepaintBoundary(
              key: boundary,
              child: ClipRect(
                child: Transform.scale(
                  scale: scenario.zoom,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Center(
                        child: SizedBox(
                          width: constraints.maxHeight * 1.24,
                          height: constraints.maxHeight,
                          child: SvgPicture.asset(
                              'assets/maps/${widget.runtime.map.name}_map.svg'),
                        ),
                      ),
                      for (var index = 0; index < 10; index++) _cone(index),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      );

  Widget _cone(int index) {
    final moving = scenario.moveAll || index == widget.movingIndex;
    final fixtureFrame = moving ? frame % frames.length : 0;
    final fixture = frames[fixtureFrame] as Map<String, dynamic>;
    final point = (fixture['positionsSvg'] as List<dynamic>)[index] as List;
    final pose = (fixture['poses'] as List<dynamic>)[index] as List;
    final source = Offset(
      (point[0] as num).toDouble(),
      (point[1] as num).toDouble(),
    );
    final transform = SvgHeightMapTransform.forMap(widget.runtime.map);
    final world = transform.sideWorldFromSource(source, isAttack: true);
    final direction =
        ((fixture['directionsSvg'] as List)[index] as num).toDouble();
    final rotation = direction + math.pi / 2;
    final coordinates = CoordinateSystem.instance;
    final sourceRange = (pose[5] as num).toDouble() *
        (widget.fixture['metersToSvg'] as num).toDouble();
    final worldRange = sourceRange * transform.scale;
    final length = worldRange / coordinates.virtualLengthToWorld(1);
    final anchor = ViewConeWidget.anchorPointVirtual * coordinates.scaleFactor;
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
          angle: (pose[6] as num).toDouble() * 180 / math.pi,
          rotation: rotation,
          length: length,
          showCenterMarker: false,
        ),
      ),
    );
  }
}

Never _exitProbe(int code) {
  if (Platform.isWindows) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final current = kernel.lookupFunction<Pointer<Void> Function(),
        Pointer<Void> Function()>('GetCurrentProcess');
    final terminate = kernel.lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)>('TerminateProcess');
    terminate(current(), code);
  }
  exit(code);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final environment = Platform.environment;
  final output = File(environment['ICARUS_AUDIT_OUTPUT']!);
  await output.parent.create(recursive: true);
  try {
    final fixture = jsonDecode(
      await File(environment['ICARUS_HEIGHT_FIXTURE']!).readAsString(),
    ) as Map<String, dynamic>;
    final map = MapValue.values.byName(fixture['map'] as String);
    if (fixture['agentCount'] != 10 || fixture['metersToSvg'] is! num) {
      throw const FormatException(
          'Expected a frozen ten-observer map fixture.');
    }
    final movingIndex = int.parse(environment['ICARUS_MOVING_INDEX'] ?? '4');
    if (movingIndex < 0 || movingIndex >= 10) {
      throw RangeError.range(movingIndex, 0, 9, 'ICARUS_MOVING_INDEX');
    }
    final container = ProviderContainer(
      overrides: [mapProvider.overrideWith(() => _FixtureMap(map))],
    );
    final keepAlive =
        container.listen(svgHeightRuntimeProvider(map), (_, __) {});
    final runtime = await container.read(svgHeightRuntimeProvider(map).future);
    if (runtime == null)
      throw StateError('${map.name} SVG runtime did not load.');
    await _setPhysicalClientSize(const Size(1920, 1080));
    await windowManager.setTitle('Icarus ${map.name} SVG sightline profile');
    runApp(UncontrolledProviderScope(
      container: container,
      child: _Probe(
        container: container,
        runtime: runtime,
        fixture: fixture,
        output: output,
        movingIndex: movingIndex,
      ),
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) => keepAlive.close());
  } catch (error, stack) {
    await output.writeAsString(jsonEncode({
      'status': 'failed',
      'error': '$error',
      'stack': '$stack',
    }));
    exit(1);
  }
}

Future<void> _setPhysicalClientSize(Size target) async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final ratio = view.devicePixelRatio;
  await windowManager.setSize(target / ratio);
  for (var attempt = 0; attempt < 5; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final physical = view.physicalSize;
    final deltaWidth = target.width - physical.width;
    final deltaHeight = target.height - physical.height;
    if (deltaWidth.abs() < 1 && deltaHeight.abs() < 1) return;
    final outer = await windowManager.getSize();
    await windowManager.setSize(Size(
      outer.width + deltaWidth / ratio,
      outer.height + deltaHeight / ratio,
    ));
  }
}
