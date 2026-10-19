import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/pending_media_bytes_store.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/media_bytes_source.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/screenshot/page_screenshot.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/dialogs/screenshot_dialog.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:image/image.dart' as img;
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState, Session;

const _strategyId = 'cloud-strategy';
const _pageId = 'page-1';
const _imageId = 'image-1';
const _imageUrl = 'https://media.example.com/image-1.png';

/// A cloud strategy open in the editor. Cloud strategies are never in the
/// local Hive box, which is what a capture used to read.
class _CloudStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: _strategyId,
        strategyName: 'Cloud strat',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      );
}

class _CloudSnapshot extends RemoteEditorSnapshotNotifier {
  _CloudSnapshot({required this.imageUrl});

  final String? imageUrl;

  @override
  Future<RemoteEditorSnapshot?> build() async {
    final now = DateTime.utc(2026);
    final page = RemotePage(
      publicId: _pageId,
      strategyPublicId: _strategyId,
      name: 'Retake B',
      sortIndex: 0,
      isAttack: true,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    );
    return RemoteEditorSnapshot(
      shell: RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: _strategyId,
          name: 'Cloud strat',
          mapData: Maps.mapNames[MapValue.ascent]!,
          revision: 1,
          createdAt: now,
          updatedAt: now,
          role: 'owner',
        ),
        pages: [page],
      ),
      activePage: RemotePageSnapshot(
        page: page,
        content: RemotePageContent(revision: 1, createdAt: now, updatedAt: now),
        elements: const [],
        lineups: const [],
        assetsById: {
          _imageId: RemoteImageAsset(
            publicId: _imageId,
            fileExtension: '.png',
            width: 64,
            height: 36,
            url: imageUrl,
            legacyStoragePath: null,
            uploadStatus: imageUrl == null ? 'pending' : 'active',
          ),
        },
      ),
    );
  }
}

/// Records every call a capture makes to the app's one Convex client.
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
    return _RecordingHandle(calls);
  }

  @override
  Future<void> clearAuth() async => calls.add('clearAuth');
}

class _RecordingHandle implements AuthProviderAuthHandle {
  _RecordingHandle(this.calls);
  final List<String> calls;

  @override
  void dispose() => calls.add('dispose');
}

class _NoSupabase extends Fake implements AuthProviderSupabaseApi {
  @override
  Session? get currentSession => null;

  @override
  Stream<AuthState> get onAuthStateChange => const Stream.empty();
}

/// A save dialog the test closes when it chooses.
class _PendingPicker extends FilePicker {
  final saves = <Uint8List?>[];
  final closed = Completer<String?>();

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) {
    saves.add(bytes);
    return closed.future;
  }
}

class _IdleOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState();
}

class _NoUploads extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);
}

/// Pure magenta, a colour no map or marker draws.
final _magentaPng = Uint8List.fromList(
  img.encodePng(
    img.fill(
      img.Image(width: 64, height: 36),
      color: img.ColorRgb8(255, 0, 255),
    ),
  ),
);

/// Preferences with screenshots set to a transparent background.
class _TransparentScreenshots extends AppPreferencesNotifier {
  @override
  AppPreferences build() => AppPreferences(
        defaultThemeProfileIdForNewStrategies:
            MapThemeProfilesProvider.immutableDefaultProfileId,
        transparentScreenshotBackground: true,
      );
}

/// Draws no thumbnails: the real ones render offscreen in real time, which
/// these tests drive only where they mean to.
Future<void> _noThumbnails(
  WidgetRef ref, {
  required Set<String> pageIds,
  required void Function(String pageId, ui.Image image) onThumbnail,
  required void Function(Set<String> pageIds, Object error) onUnavailable,
  required bool Function() isCancelled,
}) async {}

/// The test font draws every glyph a full em wide, so labels that fit in the
/// app overflow here; that is the font, not the dialog. Anything else fails.
void _ignoreTestFontOverflow(WidgetTester tester) {
  for (Object? error; (error = tester.takeException()) != null;) {
    expect('$error', contains('overflowed'));
  }
}

int _magentaPixels(Uint8List png) {
  final decoded = img.decodePng(png)!;
  var count = 0;
  for (final pixel in decoded) {
    if (pixel.r > 240 && pixel.g < 20 && pixel.b > 240) count++;
  }
  return count;
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('icarus_page_screenshot');
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

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    CoordinateSystem.instance.setIsScreenshot(false);
  });

  /// Opens the cloud page in a web-like editor (no image files on this
  /// device) and returns a ref to capture it with.
  Future<WidgetRef> openCloudPage(
    WidgetTester tester, {
    required String? imageUrl,
    bool transparentScreenshots = false,
  }) async {
    final container = ProviderContainer(overrides: [
      if (transparentScreenshots)
        appPreferencesProvider.overrideWith(_TransparentScreenshots.new),
      strategyProvider.overrideWith(_CloudStrategy.new),
      remoteEditorSnapshotProvider
          .overrideWith(() => _CloudSnapshot(imageUrl: imageUrl)),
      imageFilesOnDeviceProvider.overrideWithValue(false),
      pendingMediaBytesStoreProvider
          .overrideWithValue(MemoryPendingMediaBytesStore()),
      cloudMediaAccountIdProvider.overrideWithValue('account-a'),
      cloudMediaUploadQueueProvider.overrideWith(_NoUploads.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      pageThumbnailerProvider.overrideWithValue(_noThumbnails),
    ]);
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container.read(remoteEditorSnapshotProvider.future),
    );
    container.read(strategyPageSessionProvider.notifier).setStateForTest(
          container
              .read(strategyPageSessionProvider)
              .copyWith(activePageId: _pageId),
        );
    container.read(placedImageProvider.notifier).fromHive([
      PlacedImage(
        position: const Offset(500, 500),
        id: _imageId,
        aspectRatio: 64 / 36,
        scale: ImageScalePolicy.defaultWidth,
        fileExtension: '.png',
        sizeVersion: PlacedImage.currentSizeVersion,
      ),
    ]);

    late WidgetRef ref;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (context, widgetRef, _) {
        ref = widgetRef;
        return const SizedBox.shrink();
      }),
    ));
    return ref;
  }

  /// Runs [capture] as the app would: on real time, with the app's frames
  /// still coming. Offscreen layout builders wait for the app's next frame
  /// before rebuilding, so a capture that never sees one never paints what
  /// arrived after its first build.
  Future<Object?> captureWithFrames(
    WidgetTester tester,
    Future<Uint8List> Function() capture,
  ) async {
    Object? outcome;
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        capture().then<void>((png) => outcome = png, onError: (Object error) {
          outcome = error;
        }).whenComplete(() => done = true),
      );
    });
    while (!done) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
      // The editor keeps its own coordinates while the capture runs.
      expect(CoordinateSystem.instance.isScreenshot, isFalse);
    }
    return outcome;
  }

  testWidgets('a cloud page captures with its image fetched from the cloud URL',
      (tester) async {
    final ref = await openCloudPage(tester, imageUrl: _imageUrl);
    final requested = <Uri>[];

    final png = await captureWithFrames(
      tester,
      () => http.runWithClient(
        () => captureEditorPage(ref),
        () => MockClient((request) async {
          requested.add(request.url);
          return http.Response.bytes(_magentaPng, 200);
        }),
      ),
    );

    expect(png, isA<Uint8List>());
    expect(requested, [Uri.parse(_imageUrl)]);
    final decoded = img.decodePng(png! as Uint8List)!;
    expect(decoded.width, CoordinateSystem.screenShotSize.width);
    expect(decoded.height, CoordinateSystem.screenShotSize.height);
    expect(_magentaPixels(png as Uint8List), greaterThan(500));
    // The capture leaves the editor's coordinate mode as it found it.
    expect(CoordinateSystem.instance.isScreenshot, isFalse);
  });

  testWidgets('a transparent screenshot is see-through around the map only',
      (tester) async {
    Future<img.Image> capture({required bool transparent}) async {
      final ref = await openCloudPage(
        tester,
        imageUrl: _imageUrl,
        transparentScreenshots: transparent,
      );
      final png = await captureWithFrames(
        tester,
        () => http.runWithClient(
          () => captureEditorPage(ref),
          () => MockClient((_) async => http.Response.bytes(_magentaPng, 200)),
        ),
      );
      return img.decodePng(png! as Uint8List)!;
    }

    final solid = await capture(transparent: false);
    final transparent = await capture(transparent: true);

    // The corner is backdrop: painted normally, empty when transparent.
    expect(solid.getPixel(2, 2).a, 255);
    // Left of the map is only backdrop and dot grid: none of it is drawn.
    var drawnBackdrop = 0;
    for (var y = 0; y < 900; y++) {
      for (var x = 0; x < 400; x++) {
        if (transparent.getPixel(x, y).a != 0) drawnBackdrop++;
      }
    }
    expect(drawnBackdrop, 0);
    // The map and what sits on it are as opaque as ever.
    expect(
        transparent.getPixel(transparent.width ~/ 2, transparent.height ~/ 2).a,
        255);
    expect(_magentaPixels(img.encodePng(transparent)), greaterThan(500));
  });

  testWidgets('a capture never touches the app\'s cloud session',
      (tester) async {
    // A capture's own container builds a strategy provider, which listens
    // to auth. A real auth provider there would set, and on dispose tear
    // down, auth on the one Convex client the editor syncs through.
    final convex = _RecordingConvexAuth();
    AuthProvider.debugConvexApi = convex;
    AuthProvider.debugSupabaseApi = _NoSupabase();
    addTearDown(AuthProvider.resetTestOverrides);
    final ref = await openCloudPage(tester, imageUrl: _imageUrl);

    final png = await captureWithFrames(
      tester,
      () => http.runWithClient(
        () => captureEditorPage(ref),
        () => MockClient((_) async => http.Response.bytes(_magentaPng, 200)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(png, isA<Uint8List>());
    expect(convex.calls, isEmpty);
  });

  testWidgets('an image whose URL has not arrived stops the capture',
      (tester) async {
    final ref = await openCloudPage(tester, imageUrl: null);

    final error = await captureWithFrames(
      tester,
      () => captureEditorPage(ref),
    );

    expect(
      error,
      isA<CaptureImagesUnavailable>()
          .having((error) => error.cause, 'cause', isNull),
    );
  });

  testWidgets('an image that cannot be fetched stops the capture',
      (tester) async {
    final ref = await openCloudPage(tester, imageUrl: _imageUrl);

    final error = await captureWithFrames(
      tester,
      () => http.runWithClient(
        () => captureEditorPage(ref),
        () => MockClient((_) async => http.Response('down', 500)),
      ),
    );

    expect(
      error,
      isA<CaptureImagesUnavailable>()
          .having((error) => error.cause, 'cause', isNotNull),
    );
  });

  testWidgets('bytes that are not an image stop the capture', (tester) async {
    final ref = await openCloudPage(tester, imageUrl: _imageUrl);

    final error = await captureWithFrames(
      tester,
      () => http.runWithClient(
        () => captureEditorPage(ref),
        () => MockClient(
          (_) async => http.Response.bytes([1, 2, 3, 4], 200),
        ),
      ),
    );

    expect(
      error,
      isA<CaptureImagesUnavailable>()
          .having((error) => error.cause, 'cause', isNotNull),
    );
  });

  testWidgets('edits made while a capture waits never reach its copy',
      (tester) async {
    final ref = await openCloudPage(tester, imageUrl: _imageUrl);
    final live = ref.read(placedImageProvider).images.single;

    final snapshot = editorPageSnapshot(ref);
    live.scale = live.scale * 2;

    expect(snapshot.imageData.single, isNot(same(live)));
    expect(snapshot.imageData.single.scale, live.scale / 2);
    expect(snapshot.name, 'Retake B');
  });

  Finder saveButton() =>
      find.widgetWithText(ShadButton, 'Save screenshot');

  Future<void> openCamera(WidgetTester tester) async {
    await tester.tap(find.byIcon(LucideIcons.camera200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    _ignoreTestFontOverflow(tester);
  }

  testWidgets('the dialog stays up until the save panel closes',
      (tester) async {
    final ref = await openCloudPage(tester, imageUrl: _imageUrl);
    final picker = _PendingPicker();
    FilePicker.platform = picker;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShadApp(home: Scaffold(body: EditorToolbar())),
    ));
    expect(ref, isNotNull);

    await openCamera(tester);
    await tester.runAsync(
      () => http.runWithClient(
        () => tester.tap(saveButton()),
        () => MockClient(
          (_) async => http.Response.bytes(_magentaPng, 200),
        ),
      ),
    );
    // Real time with the app's frames coming, until the save panel opens.
    for (var i = 0; i < 400 && picker.saves.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
    }
    expect(picker.saves, hasLength(1));
    expect(picker.saves.single, isNotEmpty);
    // The capture is done, but the dialog waits for the panel, and nothing
    // but the panel closes it.
    expect(find.text('Saving screenshot'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Saving screenshot'), findsOneWidget);

    picker.closed.complete(null);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Saving screenshot'), findsNothing);
    expect(picker.saves, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the camera remembers whether the last shot was transparent',
      (tester) async {
    await openCloudPage(tester, imageUrl: _imageUrl);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShadApp(home: Scaffold(body: EditorToolbar())),
    ));
    Future<ShadCheckbox> transparentToggle() async {
      await openCamera(tester);
      // One page: nothing to tick but the background.
      return tester.widget<ShadCheckbox>(find.byType(ShadCheckbox));
    }

    expect((await transparentToggle()).value, isFalse);
    await tester.runAsync(
      () => tester.tap(find.text('Transparent background')),
    );
    await tester.pump();
    expect(
      container.read(appPreferencesProvider).transparentScreenshotBackground,
      isTrue,
    );

    // Closed without a shot and opened again: still ticked.
    await tester.tap(find.widgetWithText(ShadButton, 'Cancel'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ShadCheckbox), findsNothing);
    expect((await transparentToggle()).value, isTrue);

    await tester.runAsync(
      () => container
          .read(appPreferencesProvider.notifier)
          .setTransparentScreenshotBackground(false),
    );
  });

  testWidgets('a screenshot that fails while fetching closes its dialog',
      (tester) async {
    await openCloudPage(tester, imageUrl: _imageUrl);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
    );
    appProviderContainer = container;
    final response = Completer<http.Response>();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShadApp(home: Scaffold(body: EditorToolbar())),
    ));
    await openCamera(tester);
    await http.runWithClient(
      () => tester.tap(saveButton()),
      () => MockClient((_) => response.future),
    );
    await tester.pump();
    // The dialog says it is saving while the image is fetched.
    expect(find.text('Saving screenshot'), findsOneWidget);
    expect(CoordinateSystem.instance.isScreenshot, isFalse);

    response.complete(http.Response('down', 500));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Saving screenshot'), findsNothing);
    expect(find.byIcon(LucideIcons.camera200), findsOneWidget);
    expect(CoordinateSystem.instance.isScreenshot, isFalse);
    expect(tester.takeException(), isNull);
  });
}
