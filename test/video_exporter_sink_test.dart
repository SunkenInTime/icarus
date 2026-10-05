import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/video_export/ffmpeg_video_sink.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/services/video_export/video_exporter.dart';
import 'package:icarus/services/video_export/video_frame_sink.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState, Session;

/// Pure magenta, a colour no map or marker draws.
final _magentaPng = Uint8List.fromList(
  img.encodePng(
    img.fill(
      img.Image(width: 64, height: 36),
      color: img.ColorRgb8(255, 0, 255),
    ),
  ),
);

/// Records every call an export makes to the app's one Convex client.
class _RecordingConvexAuth extends Fake implements AuthProviderConvexApi {
  final calls = <String>[];

  @override
  Stream<bool> get authState => const Stream.empty();

  @override
  bool get isAuthenticated => true;

  @override
  Future<AuthProviderAuthHandle> setAuthWithRefresh({
    required Future<String?> Function() fetchToken,
    void Function(bool isAuthenticated)? onAuthChange,
  }) async {
    calls.add('setAuthWithRefresh');
    throw UnimplementedError();
  }

  @override
  Future<void> clearAuth() async => calls.add('clearAuth');
}

class _NoSupabase extends Fake implements AuthProviderSupabaseApi {
  @override
  Session? get currentSession => null;

  @override
  Stream<AuthState> get onAuthStateChange => const Stream.empty();
}

class _RecordingSink implements VideoFrameSink {
  final video = Uint8List.fromList([7, 7, 7]);
  final frames = <(Uint8List, double)>[];
  ({int width, int height, int totalFrames, double totalSeconds})? started;
  var closed = 0;

  @override
  Future<void> start({
    required int width,
    required int height,
    required int totalFrames,
    required double totalSeconds,
  }) async {
    started = (
      width: width,
      height: height,
      totalFrames: totalFrames,
      totalSeconds: totalSeconds,
    );
  }

  @override
  Future<void> addFrame(Uint8List rgba, double durationSeconds) async =>
      frames.add((rgba, durationSeconds));

  @override
  Future<Uint8List?> finish({void Function(double)? onProgress}) async => video;

  @override
  void cancel() {}

  @override
  Future<void> close() async => closed++;
}

StrategyPage _page(String id, int sortIndex, Offset imageAt) => StrategyPage(
      id: id,
      name: id,
      drawingData: const [],
      agentData: const [],
      abilityData: const [],
      textData: const [],
      imageData: [
        PlacedImage(
          position: imageAt,
          id: 'image-1',
          aspectRatio: 64 / 36,
          scale: ImageScalePolicy.defaultWidth,
          fileExtension: '.png',
          sizeVersion: PlacedImage.currentSizeVersion,
        ),
      ],
      utilityData: const [],
      sortIndex: sortIndex,
      isAttack: true,
      settings: StrategySettings(),
    );

VideoExporter _exporter(List<StrategyPage> pages) {
  return VideoExporter(
    strategy: StrategyData(
      id: 'cloud-strategy',
      name: 'Cloud strat',
      mapData: MapValue.ascent,
      versionNumber: 1,
      lastEdited: DateTime(2026),
      folderID: null,
      pages: pages,
    ),
    strategyState: const StrategyState(
      strategyId: 'cloud-strategy',
      strategyName: 'Cloud strat',
      source: StrategySource.cloud,
      storageDirectory: null,
      isOpen: true,
    ),
    mapState: MapState(currentMap: MapValue.ascent, isAttack: true),
    backgroundDotOpacity: 1,
    geometry: null,
    imageSources: {'image-1': ImageBytes(_magentaPng)},
  );
}

/// Runs the export on real time with the app's frames still coming, as in
/// the app: the offscreen tree's layout builders wait for the app's next
/// frame.
Future<Object?> _exportWithFrames(
  WidgetTester tester,
  VideoExporter exporter,
  List<StrategyPage> pages,
  VideoFrameSink sink,
) async {
  Object? outcome;
  var done = false;
  await tester.runAsync(() async {
    unawaited(
      exporter
          .export(
            pages: pages,
            stepDuration: const Duration(seconds: 2),
            sink: sink,
            quality: VideoExportQuality.social,
          )
          .then<void>((video) => outcome = video,
              onError: (Object error) => outcome = error)
          .whenComplete(() => done = true),
    );
  });
  while (!done) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 16)),
    );
    await tester.pump();
  }
  return outcome;
}

int _magentaPixels(Uint8List rgba) {
  var count = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i] > 240 && rgba[i + 1] < 20 && rgba[i + 2] > 240) count++;
  }
  return count;
}

/// A PATH ffmpeg, the development fallback of FfmpegVideoEncoder, with the
/// H.264 encoder the export asks for on this platform.
final String? _ffmpeg = () {
  final ffmpeg = _onPath('ffmpeg');
  if (ffmpeg == null) return null;
  final encoders = Process.runSync(ffmpeg, ['-hide_banner', '-encoders']);
  final h264 = Platform.isWindows ? 'h264_mf' : 'libx264';
  return '${encoders.stdout}'.contains(h264) ? ffmpeg : null;
}();
final String? _ffprobe = _onPath('ffprobe');

String? _onPath(String tool) {
  try {
    final result = Process.runSync(
      Platform.isWindows ? 'where' : 'which',
      [tool],
    );
    if (result.exitCode != 0) return null;
    return const LineSplitter().convert(result.stdout as String).first.trim();
  } on ProcessException {
    return null;
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('icarus_video_sink');
    Hive.init(hiveDir.path);
    registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  testWidgets(
      'renders every page and transition frame into the sink, images and all',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    final pages = [
      _page('one', 0, const Offset(400, 400)),
      _page('two', 1, const Offset(700, 600)),
    ];
    final exporter = _exporter(pages);
    final sink = _RecordingSink();

    final outcome = await _exportWithFrames(tester, exporter, pages, sink);

    expect(outcome, same(sink.video));
    final transitionFrames = VideoExporter.transitionFrameCountFor(30);
    expect(sink.started, (
      width: 1920,
      height: 1080,
      totalFrames: 2 + transitionFrames,
      totalSeconds: VideoExporter.plannedDurationSeconds(
        pageCount: 2,
        stepSeconds: 2,
        fps: 30,
      ),
    ));
    expect(sink.frames, hasLength(2 + transitionFrames));
    expect(sink.frames.first.$2, 2);
    expect(sink.frames.last.$2, 2);
    for (final (_, duration) in sink.frames.skip(1).take(transitionFrames)) {
      expect(duration, closeTo(1 / 30, 1e-9));
    }
    for (final (rgba, _) in sink.frames) {
      expect(rgba.length, 1920 * 1080 * 4);
    }
    expect(_magentaPixels(sink.frames.first.$1), greaterThan(500));
    expect(_magentaPixels(sink.frames.last.$1), greaterThan(500));
    expect(sink.closed, 1);
    expect(CoordinateSystem.instance.isScreenshot, isFalse);
  });

  testWidgets('an export never touches the app\'s cloud session',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    final convex = _RecordingConvexAuth();
    AuthProvider.debugConvexApi = convex;
    AuthProvider.debugSupabaseApi = _NoSupabase();
    addTearDown(AuthProvider.resetTestOverrides);
    final pages = [
      _page('one', 0, const Offset(400, 400)),
      _page('two', 1, const Offset(700, 600)),
    ];

    final outcome = await _exportWithFrames(
      tester,
      _exporter(pages),
      pages,
      _RecordingSink(),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(outcome, isA<Uint8List>());
    expect(convex.calls, isEmpty);
  });

  testWidgets('desktop encodes the frames into a playable .mp4 with ffmpeg',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    final pages = [
      _page('one', 0, const Offset(400, 400)),
      _page('two', 1, const Offset(700, 600)),
    ];
    final outputDir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('icarus_video_out'),
    ))!;
    addTearDown(() => outputDir.deleteSync(recursive: true));
    final outputPath = '${outputDir.path}${Platform.pathSeparator}out.mp4';

    final outcome = await _exportWithFrames(
      tester,
      _exporter(pages),
      pages,
      FfmpegVideoSink(
        binary: _ffmpeg!,
        outputPath: outputPath,
        quality: VideoExportQuality.social,
      ),
    );

    expect(outcome, isNull);
    final probe = (await tester.runAsync(
      () => Process.run(_ffprobe!, [
        '-v',
        'error',
        '-show_entries',
        'stream=codec_name,width,height:format=duration',
        '-of',
        'default=noprint_wrappers=1',
        outputPath,
      ]),
    ))!;
    final report = probe.stdout as String;
    expect(report, contains('codec_name=h264'));
    expect(report, contains('width=1920'));
    expect(report, contains('height=1080'));
    final seconds = double.parse(
      RegExp(r'duration=([\d.]+)').firstMatch(report)!.group(1)!,
    );
    expect(
      seconds,
      closeTo(
        VideoExporter.plannedDurationSeconds(
          pageCount: 2,
          stepSeconds: 2,
          fps: 30,
        ),
        0.1,
      ),
    );
    // Needs a PATH ffmpeg and ffprobe, as local development has.
  }, skip: _ffmpeg == null || _ffprobe == null);
}
