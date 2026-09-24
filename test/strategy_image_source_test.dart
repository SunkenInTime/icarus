import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/pending_media_bytes_store.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/media_bytes_source.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/local_image_file_native.dart' as native;
import 'package:icarus/services/local_image_file_stub.dart' as web;
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/dialogs/strategy/line_up_media_page.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';

const _imageId = 'image-1';
const _remoteUrl = 'https://media.example.com/image-1.png';
// A 1x1 PNG, still uploading from this browser.
final _pendingPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

RemoteImageAsset _asset({String? url = _remoteUrl, String status = 'active'}) {
  return RemoteImageAsset(
    publicId: _imageId,
    fileExtension: '.png',
    width: 16,
    height: 9,
    url: url,
    legacyStoragePath: null,
    uploadStatus: status,
  );
}

class _FixedStrategy extends StrategyProvider {
  _FixedStrategy({required this.source, required this.storageDirectory});

  final StrategySource source;
  final String? storageDirectory;

  @override
  StrategyState build() => StrategyState(
        strategyId: 'strategy-1',
        strategyName: 'Strategy',
        source: source,
        storageDirectory: storageDirectory,
        isOpen: true,
      );
}

class _FixedSnapshot extends RemoteEditorSnapshotNotifier {
  _FixedSnapshot(this.assets);

  final List<RemoteImageAsset> assets;

  @override
  Future<RemoteEditorSnapshot?> build() async {
    final now = DateTime.utc(2026);
    final page = RemotePage(
      publicId: 'page-1',
      strategyPublicId: 'strategy-1',
      name: 'Page 1',
      sortIndex: 0,
      isAttack: true,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    );
    return RemoteEditorSnapshot(
      shell: RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: 'strategy-1',
          name: 'Strategy',
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
        assetsById: {for (final asset in assets) asset.publicId: asset},
      ),
    );
  }
}

List<Override> _overrides({
  required StrategySource source,
  required String? storageDirectory,
  List<RemoteImageAsset> assets = const [],
  Map<String, Uint8List> pendingBytes = const {},
}) {
  return [
    strategyProvider.overrideWith(
      () => _FixedStrategy(source: source, storageDirectory: storageDirectory),
    ),
    remoteEditorSnapshotProvider.overrideWith(() => _FixedSnapshot(assets)),
    pendingMediaBytesStoreProvider.overrideWithValue(
      MemoryPendingMediaBytesStore(pendingBytes),
    ),
  ];
}

/// Bumping [rebuild] rebuilds the mounted image, as a canvas redraw would.
Widget _imageApp({
  required StrategySource source,
  required String? storageDirectory,
  List<RemoteImageAsset> assets = const [],
  Map<String, Uint8List> pendingBytes = const {},
  ValueNotifier<int>? rebuild,
}) {
  return ProviderScope(
    overrides: _overrides(
      source: source,
      storageDirectory: storageDirectory,
      assets: assets,
      pendingBytes: pendingBytes,
    ),
    child: MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: rebuild ?? ValueNotifier(0),
          // Not const: a const image would be skipped on rebuild.
          // ignore: prefer_const_constructors
          builder: (context, _, __) => Stack(
            // ignore: prefer_const_literals_to_create_immutables
            children: [
              // ignore: prefer_const_constructors
              ImageWidget(
                id: _imageId,
                aspectRatio: 16 / 9,
                scale: 320,
                fileExtension: '.png',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<Directory> _storageWithImage(WidgetTester tester) async {
  final storage = await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('icarus_image_widget');
    await _writeImage(dir);
    return dir;
  });
  addTearDown(() => storage!.deleteSync(recursive: true));
  return storage!;
}

File _imageFile(Directory storage) =>
    File(path.join(storage.path, 'images', '$_imageId.png'));

/// A real 1x1 PNG, so the file image decodes when IO is allowed to run.
Future<void> _writeImage(Directory storage) async {
  final file = _imageFile(storage);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  ));
}

ImageProvider _paintedImage(WidgetTester tester) {
  return tester.widget<Image>(find.byType(Image)).image;
}

void main() {
  group('resolveStrategyImageSource', () {
    test('a file on this device wins over the cloud URL', () {
      final source = resolveStrategyImageSource(
        localFilePath: '/images/image-1.png',
        isCloudStrategy: true,
        remoteAsset: _asset(),
      );
      expect(source, isA<LocalImageFile>());
    });

    test('a cloud image without a file paints from its URL', () {
      final source = resolveStrategyImageSource(
        localFilePath: null,
        isCloudStrategy: true,
        remoteAsset: _asset(),
      );
      expect((source as RemoteImageUrl).url, _remoteUrl);
    });

    test('a cloud image without a URL yet is loading', () {
      expect(
        resolveStrategyImageSource(
          localFilePath: null,
          isCloudStrategy: true,
          remoteAsset: null,
        ),
        isA<ImageLoading>(),
      );
      expect(
        resolveStrategyImageSource(
          localFilePath: null,
          isCloudStrategy: true,
          remoteAsset: _asset(url: null, status: 'pending'),
        ),
        isA<ImageLoading>(),
      );
    });

    test('a file on this device and the cloud URL both beat pending bytes', () {
      expect(
        resolveStrategyImageSource(
          localFilePath: '/images/image-1.png',
          isCloudStrategy: true,
          remoteAsset: null,
          pendingBytes: _pendingPng,
        ),
        isA<LocalImageFile>(),
      );
      expect(
        resolveStrategyImageSource(
          localFilePath: null,
          isCloudStrategy: true,
          remoteAsset: _asset(),
          pendingBytes: _pendingPng,
        ),
        isA<RemoteImageUrl>(),
      );
    });

    test('bytes still uploading paint until the cloud URL arrives', () {
      final uploading = resolveStrategyImageSource(
        localFilePath: null,
        isCloudStrategy: true,
        remoteAsset: _asset(url: null, status: 'pending'),
        pendingBytes: _pendingPng,
      );
      expect((uploading as PendingImageBytes).bytes, _pendingPng);
      expect(uploading.imageProvider, isA<MemoryImage>());

      // A failed attempt is retried from the same bytes; keep showing them.
      expect(
        resolveStrategyImageSource(
          localFilePath: null,
          isCloudStrategy: true,
          remoteAsset: _asset(url: null, status: 'failed'),
          pendingBytes: _pendingPng,
        ),
        isA<PendingImageBytes>(),
      );

      expect(
        resolveStrategyImageSource(
          localFilePath: null,
          isCloudStrategy: true,
          remoteAsset: _asset(),
          pendingBytes: _pendingPng,
        ),
        isA<RemoteImageUrl>(),
      );
    });

    test('a failed upload or a missing local file has failed', () {
      expect(
        resolveStrategyImageSource(
          localFilePath: null,
          isCloudStrategy: true,
          remoteAsset: _asset(url: null, status: 'failed'),
        ),
        isA<ImageFailed>(),
      );
      expect(
        resolveStrategyImageSource(
          localFilePath: null,
          isCloudStrategy: false,
          remoteAsset: null,
        ),
        isA<ImageFailed>(),
      );
    });
  });

  group('local image files', () {
    late Directory storage;

    setUp(() {
      storage = Directory.systemTemp.createTempSync('icarus_image_source');
      File(path.join(storage.path, 'images', '$_imageId.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(const [0]);
    });

    tearDown(() => storage.deleteSync(recursive: true));

    test('desktop finds the file under the storage directory', () {
      expect(
        native.findLocalImageFile(
          storageDirectory: storage.path,
          imageId: _imageId,
          fileExtension: '.png',
        ),
        path.join(storage.path, 'images', '$_imageId.png'),
      );
    });

    test('web never finds a file, even where one exists', () {
      expect(web.deviceHasImageFiles, isFalse);
      expect(
        web.findLocalImageFile(
          storageDirectory: storage.path,
          imageId: _imageId,
          fileExtension: '.png',
        ),
        isNull,
      );
    });
  });

  group('ImageWidget', () {
    setUp(() {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
    });

    testWidgets(
        'a cloud image with no storage directory paints from its URL, '
        'as on web', (tester) async {
      await tester.pumpWidget(_imageApp(
        source: StrategySource.cloud,
        storageDirectory: null,
        assets: [_asset()],
      ));
      await tester.pump();

      final image = _paintedImage(tester);
      expect(image, isA<NetworkImage>());
      expect((image as NetworkImage).url, _remoteUrl);
      // flutter_test answers every HTTP request with a 400; nothing else may
      // throw (the old path dereferenced the null storage directory).
      expect(
        tester.takeException(),
        anyOf(isNull, isA<NetworkImageLoadException>()),
      );
    });

    testWidgets('a placed image still uploading paints from memory on web',
        (tester) async {
      await tester.pumpWidget(_imageApp(
        source: StrategySource.cloud,
        storageDirectory: null,
        pendingBytes: {_imageId: _pendingPng},
      ));
      await tester.pump();

      final image = _paintedImage(tester);
      expect(image, isA<MemoryImage>());
      expect((image as MemoryImage).bytes, _pendingPng);
      expect(find.text('Syncing image'), findsNothing);
    });

    testWidgets('a cloud image whose URL has not arrived shows syncing',
        (tester) async {
      await tester.pumpWidget(_imageApp(
        source: StrategySource.cloud,
        storageDirectory: null,
      ));
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(find.text('Syncing image'), findsOneWidget);
    });

    testWidgets('a local image paints from its file on desktop',
        (tester) async {
      final storage = await _storageWithImage(tester);

      await tester.pumpWidget(_imageApp(
        source: StrategySource.local,
        storageDirectory: storage.path,
      ));
      await tester.pump();

      final image = _paintedImage(tester);
      expect(image, isA<FileImage>());
      expect((image as FileImage).file.path, _imageFile(storage).path);
    });

    testWidgets('a cloud image already cached on desktop paints from its file',
        (tester) async {
      final storage = await _storageWithImage(tester);

      await tester.pumpWidget(_imageApp(
        source: StrategySource.cloud,
        storageDirectory: storage.path,
        assets: [_asset()],
      ));
      await tester.pump();

      expect(_paintedImage(tester), isA<FileImage>());
    });

    testWidgets('a mounted image sees its file appear on the next rebuild',
        (tester) async {
      final storage = await _storageWithImage(tester);
      await tester.runAsync(() => _imageFile(storage).delete());
      final rebuild = ValueNotifier(0);
      addTearDown(rebuild.dispose);

      await tester.pumpWidget(_imageApp(
        source: StrategySource.local,
        storageDirectory: storage.path,
        rebuild: rebuild,
      ));
      await tester.pump();
      expect(find.text('Image unavailable'), findsOneWidget);

      await tester.runAsync(() => _writeImage(storage));
      rebuild.value++;
      await tester.pump();

      expect(_paintedImage(tester), isA<FileImage>());
    });

    testWidgets('a mounted image sees its file vanish on the next rebuild',
        (tester) async {
      final storage = await _storageWithImage(tester);
      final rebuild = ValueNotifier(0);
      addTearDown(rebuild.dispose);

      await tester.pumpWidget(_imageApp(
        source: StrategySource.cloud,
        storageDirectory: storage.path,
        assets: [_asset()],
        rebuild: rebuild,
      ));
      await tester.pump();
      expect(_paintedImage(tester), isA<FileImage>());

      await tester.runAsync(() => _imageFile(storage).delete());
      rebuild.value++;
      await tester.pump();

      expect(_paintedImage(tester), isA<NetworkImage>());
      expect(
        tester.takeException(),
        anyOf(isNull, isA<NetworkImageLoadException>()),
      );
    });

    testWidgets('any media cache change re-checks the disk', (tester) async {
      final storage = await _storageWithImage(tester);
      await tester.runAsync(() => _imageFile(storage).delete());

      await tester.pumpWidget(_imageApp(
        source: StrategySource.cloud,
        storageDirectory: storage.path,
        assets: [_asset()],
      ));
      await tester.pump();
      expect(_paintedImage(tester), isA<NetworkImage>());

      await tester.runAsync(() => _writeImage(storage));
      ProviderScope.containerOf(tester.element(find.byType(ImageWidget)))
          .read(cloudMediaCacheProvider.notifier)
          .resetStrategy('strategy-1');
      await tester.pump();

      expect(_paintedImage(tester), isA<FileImage>());
      expect(
        tester.takeException(),
        anyOf(isNull, isA<NetworkImageLoadException>()),
      );
    });
  });

  testWidgets(
      'a lineup media tile paints an Image, not a DecorationImage, '
      'so the web <img> fallback can draw it', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final youtube = TextEditingController();
    final notes = TextEditingController();
    addTearDown(youtube.dispose);
    addTearDown(notes.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: _overrides(
        source: StrategySource.cloud,
        storageDirectory: null,
        assets: [_asset()],
      ),
      child: ShadApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 800,
            child: LineupMediaPage(
              youtubeLinkController: youtube,
              notesController: notes,
              images: [SimpleImageData(id: _imageId, fileExtension: '.png')],
              onAddImage: () {},
              onPasteImage: () {},
              onRemoveImage: (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as NetworkImage).url, _remoteUrl);
    final decorationImages = tester
        .widgetList<Container>(find.byType(Container))
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .where((decoration) => decoration.image != null);
    expect(decorationImages, isEmpty);
    expect(
      tester.takeException(),
      anyOf(isNull, isA<NetworkImageLoadException>()),
    );
  });
}
