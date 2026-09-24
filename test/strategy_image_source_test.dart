import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/local_image_file_native.dart' as native;
import 'package:icarus/services/local_image_file_stub.dart' as web;
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:path/path.dart' as path;

const _imageId = 'image-1';
const _remoteUrl = 'https://media.example.com/image-1.png';

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

Widget _imageApp({
  required StrategySource source,
  required String? storageDirectory,
  List<RemoteImageAsset> assets = const [],
}) {
  return ProviderScope(
    overrides: [
      strategyProvider.overrideWith(
        () => _FixedStrategy(source: source, storageDirectory: storageDirectory),
      ),
      remoteEditorSnapshotProvider.overrideWith(() => _FixedSnapshot(assets)),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
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
  );
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
      final storage = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('icarus_image_widget');
        await File(path.join(dir.path, 'images', '$_imageId.png'))
            .create(recursive: true);
        return dir;
      });
      addTearDown(() => storage!.deleteSync(recursive: true));

      await tester.pumpWidget(_imageApp(
        source: StrategySource.local,
        storageDirectory: storage!.path,
      ));
      await tester.pump();

      final image = _paintedImage(tester);
      expect(image, isA<FileImage>());
      expect(
        (image as FileImage).file.path,
        path.join(storage.path, 'images', '$_imageId.png'),
      );
    });

    testWidgets('a cloud image already cached on desktop paints from its file',
        (tester) async {
      final storage = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('icarus_image_widget');
        await File(path.join(dir.path, 'images', '$_imageId.png'))
            .create(recursive: true);
        return dir;
      });
      addTearDown(() => storage!.deleteSync(recursive: true));

      await tester.pumpWidget(_imageApp(
        source: StrategySource.cloud,
        storageDirectory: storage!.path,
        assets: [_asset()],
      ));
      await tester.pump();

      expect(_paintedImage(tester), isA<FileImage>());
    });
  });
}
