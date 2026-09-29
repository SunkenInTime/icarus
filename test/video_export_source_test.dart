import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/services/video_export/video_export_source.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;

const _strategyId = 'strategy-1';
const _imageUrl = 'https://media.example.com/image-1.png';

final _png = Uint8List.fromList(
  img.encodePng(
    img.fill(img.Image(width: 4, height: 4), color: img.ColorRgb8(1, 2, 3)),
  ),
);

PlacedImage _image(String id) => PlacedImage(
      position: const Offset(500, 500),
      id: id,
      aspectRatio: 1,
      scale: 100,
      fileExtension: '.png',
    );

class _OpenStrategy extends StrategyProvider {
  _OpenStrategy(this.source, {this.storageDirectory});

  final StrategySource source;
  final String? storageDirectory;
  int saves = 0;

  @override
  StrategyState build() => StrategyState(
        strategyId: _strategyId,
        strategyName: 'Strategy',
        source: source,
        storageDirectory: storageDirectory,
        isOpen: true,
      );

  @override
  Future<void> forceSaveNow(String id) async => saves++;
}

/// This device's op queue, set by the test.
class _Queue extends StrategyOpQueueNotifier {
  _Queue(this.initial);

  final StrategyOpQueueState initial;
  var flushes = 0;

  @override
  StrategyOpQueueState build() => initial;

  @override
  Future<void> flushNow() async => flushes++;

  /// Everything this device queued has landed.
  void settle() => state = const StrategyOpQueueState(durableLoaded: true);
}

class _NoUploads extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);
}

class _Repository extends Fake implements ConvexStrategyRepository {
  int fetches = 0;
  final shareTokens = <String?>[];

  @override
  Future<RemoteFullStrategySnapshot> fetchFullSnapshot(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    fetches++;
    shareTokens.add(shareToken);
    final now = DateTime.utc(2026);
    RemotePage page(String id, int sortIndex) => RemotePage(
          publicId: id,
          strategyPublicId: _strategyId,
          name: 'Page $id',
          sortIndex: sortIndex,
          isAttack: true,
          revision: 1,
          createdAt: now,
          updatedAt: now,
        );
    RemoteFullPage fullPage(String id, int sortIndex) => RemoteFullPage(
          page: page(id, sortIndex),
          content:
              RemotePageContent(revision: 1, createdAt: now, updatedAt: now),
        );
    return RemoteFullStrategySnapshot(
      header: RemoteStrategyHeader(
        publicId: _strategyId,
        name: 'Strategy',
        mapData: Maps.mapNames[MapValue.ascent]!,
        revision: 1,
        createdAt: now,
        updatedAt: now,
      ),
      pages: [fullPage('b', 1), fullPage('a', 0)],
      elementsByPage: {
        for (final (pageId, imageId) in [('a', 'image-a'), ('b', 'image-b')])
          pageId: [
            RemoteElement(
              publicId: imageId,
              strategyPublicId: _strategyId,
              pagePublicId: pageId,
              elementType: 'image',
              payload: cloudElementPayload(
                kind: 'image',
                data: cloudImagePayloadFromPlacedImage(_image(imageId)),
              ),
              sortIndex: 0,
              revision: 1,
              deleted: false,
            ),
          ],
      },
      lineupsByPage: const {},
      assetsById: {
        for (final imageId in ['image-a', 'image-b'])
          imageId: RemoteImageAsset(
            publicId: imageId,
            fileExtension: '.png',
            width: 4,
            height: 4,
            url: '$_imageUrl?$imageId',
            legacyStoragePath: null,
            uploadStatus: 'active',
          ),
      },
    );
  }
}

Future<WidgetRef> _pumpRef(
    WidgetTester tester, List<Override> overrides) async {
  late WidgetRef ref;
  await tester.pumpWidget(ProviderScope(
    overrides: overrides,
    child: Consumer(builder: (context, widgetRef, _) {
      ref = widgetRef;
      return const SizedBox.shrink();
    }),
  ));
  return ref;
}

void main() {
  group('a cloud strategy', () {
    List<Override> cloud(
      _Queue queue,
      _Repository repository, {
      List<Override> more = const [],
    }) =>
        [
          strategyProvider
              .overrideWith(() => _OpenStrategy(StrategySource.cloud)),
          strategyOpQueueProvider.overrideWith(() => queue),
          cloudMediaUploadQueueProvider.overrideWith(_NoUploads.new),
          convexStrategyRepositoryProvider.overrideWithValue(repository),
          ...more,
        ];

    testWidgets('waits for queued work, then reads the whole strategy',
        (tester) async {
      final queue = _Queue(const StrategyOpQueueState(
        durableLoaded: true,
        isFlushing: true,
      ));
      final repository = _Repository();
      final ref = await _pumpRef(tester, cloud(queue, repository));
      final requested = <String>[];

      final source = await tester.runAsync(
        () => http.runWithClient(
          () async {
            final loading = loadVideoExportSource(ref, pageIds: {'a'});
            await Future<void>.delayed(const Duration(milliseconds: 250));
            // The edits were pushed, but nothing is read until they land.
            expect(queue.flushes, 1);
            expect(repository.fetches, 0);
            queue.settle();
            return loading;
          },
          () => MockClient((request) async {
            requested.add(request.url.query);
            return http.Response.bytes(_png, 200);
          }),
        ),
      );
      addTearDown(source!.images.release);

      expect(repository.fetches, 1);
      expect(source.strategy.id, _strategyId);
      expect(source.strategy.mapData, MapValue.ascent);
      expect(
        [for (final page in source.strategy.pages) page.id],
        containsAll(['a', 'b']),
      );
      // Only the exported page's image is fetched and decoded.
      expect(requested, ['image-a']);
      expect(source.images.sources.keys, ['image-a']);
      expect(source.images.sources['image-a'], isA<ImageBytes>());
    });

    testWidgets(
        'with nothing to send, reads at once and leaves the save chip alone',
        (tester) async {
      final repository = _Repository();
      final ref = await _pumpRef(
        tester,
        cloud(
          _Queue(const StrategyOpQueueState(durableLoaded: true)),
          repository,
        ),
      );

      final source = await tester.runAsync(
        () => http.runWithClient(
          () => loadVideoExportSource(ref, pageIds: {'a'}),
          () => MockClient((_) async => http.Response.bytes(_png, 200)),
        ),
      );
      addTearDown(source!.images.release);

      expect(repository.fetches, 1);
      // A save that sends nothing must not leave the chip saying syncing.
      final saveState = ref.read(strategySaveStateProvider);
      expect(saveState.hasPendingCloudSync, isFalse);
      expect(saveState.isDirty, isFalse);
    });

    testWidgets('stops when this device has not synced in time',
        (tester) async {
      final repository = _Repository();
      final ref = await _pumpRef(
        tester,
        cloud(
          _Queue(const StrategyOpQueueState(
            durableLoaded: true,
            isFlushing: true,
          )),
          repository,
        ),
      );

      Object? error;
      loadVideoExportSource(ref, pageIds: {'a'}).then<void>(
        (_) {},
        onError: (Object caught) => error = caught,
      );
      await tester.pump(videoExportSyncTimeout + const Duration(seconds: 1));

      expect(error, isA<VideoExportNotSynced>());
      expect(repository.fetches, 0);
    });

    testWidgets('stops at once when work waits for review', (tester) async {
      final repository = _Repository();
      final ref = await _pumpRef(
        tester,
        cloud(
          _Queue(const StrategyOpQueueState(
            durableLoaded: true,
            hasDurabilityFailure: true,
          )),
          repository,
        ),
      );

      Object? error;
      loadVideoExportSource(ref, pageIds: {'a'}).then<void>(
        (_) {},
        onError: (Object caught) => error = caught,
      );
      await tester.pump(const Duration(milliseconds: 1));

      expect(error, isA<VideoExportNotSynced>());
    });

    testWidgets('stops waiting when the export is cancelled', (tester) async {
      final repository = _Repository();
      final ref = await _pumpRef(
        tester,
        cloud(
          _Queue(const StrategyOpQueueState(
            durableLoaded: true,
            isFlushing: true,
          )),
          repository,
        ),
      );
      var cancelled = false;

      Object? error;
      loadVideoExportSource(
        ref,
        pageIds: {'a'},
        isCancelled: () => cancelled,
      ).then<void>((_) {}, onError: (Object caught) => error = caught);
      await tester.pump(const Duration(seconds: 1));
      cancelled = true;
      await tester.pump(const Duration(milliseconds: 200));

      expect(error, isA<VideoExportCancelled>());
      expect(repository.fetches, 0);
    });

    testWidgets('stops between images when the export is cancelled',
        (tester) async {
      final ref = await _pumpRef(
        tester,
        cloud(
          _Queue(const StrategyOpQueueState(durableLoaded: true)),
          _Repository(),
        ),
      );
      var cancelled = false;
      final requested = <String>[];

      Object? error;
      await tester.runAsync(() async {
        try {
          await http.runWithClient(
            () => loadVideoExportSource(
              ref,
              pageIds: {'a', 'b'},
              isCancelled: () => cancelled,
            ),
            () => MockClient((request) async {
              requested.add(request.url.query);
              // The user cancels while the first image downloads.
              cancelled = true;
              return http.Response.bytes(_png, 200);
            }),
          );
        } catch (caught) {
          error = caught;
        }
      });

      // Downloads start together; the cancel stops the export before the
      // next image is decoded and held.
      expect(error, isA<VideoExportCancelled>());
      expect(requested, isNotEmpty);
    });

    testWidgets('refuses a selection naming a page that no longer exists',
        (tester) async {
      final repository = _Repository();
      final ref = await _pumpRef(
        tester,
        cloud(
          _Queue(const StrategyOpQueueState(durableLoaded: true)),
          repository,
        ),
      );

      Object? error;
      await tester.runAsync(() async {
        try {
          await loadVideoExportSource(ref, pageIds: {'a', 'deleted'});
        } catch (caught) {
          error = caught;
        }
      });

      expect(error, isA<VideoExportPagesChanged>());
    });

    testWidgets('reads through the link a signed-out reader opened',
        (tester) async {
      final repository = _Repository();
      final ref = await _pumpRef(
        tester,
        cloud(
          _Queue(const StrategyOpQueueState(durableLoaded: true)),
          repository,
          more: [
            shareLinkViewProvider.overrideWith(
              (ref) => (strategyPublicId: _strategyId, token: 'link-token'),
            ),
          ],
        ),
      );

      final source = await tester.runAsync(
        () => http.runWithClient(
          () => loadVideoExportSource(ref, pageIds: {'a'}),
          () => MockClient((_) async => http.Response.bytes(_png, 200)),
        ),
      );
      addTearDown(source!.images.release);

      expect(repository.shareTokens, ['link-token']);
    });

    testWidgets('offers the pages the editor lists, in order', (tester) async {
      final ref = await _pumpRef(tester, [
        strategyProvider
            .overrideWith(() => _OpenStrategy(StrategySource.cloud)),
        remoteEditorSnapshotProvider.overrideWith(_TwoPageSnapshot.new),
      ]);
      await tester.runAsync(
        () => ProviderScope.containerOf(tester.element(find.byType(Consumer)))
            .read(remoteEditorSnapshotProvider.future),
      );

      expect(videoExportPageChoices(ref), [
        (id: 'first', name: 'First'),
        (id: 'second', name: 'Second'),
      ]);
    });
  });

  group('a local strategy', () {
    late Directory dir;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('icarus_video_source');
      Hive.init(dir.path);
      registerIcarusAdapters(Hive);
      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    });

    tearDownAll(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    testWidgets('is read back from the library with its image files',
        (tester) async {
      final storage = path.join(dir.path, 'storage');
      await tester.runAsync(() async {
        final file = File(path.join(storage, 'images', 'image-a.png'));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(_png);
        await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
          _strategyId,
          StrategyData(
            id: _strategyId,
            name: 'Strategy',
            mapData: MapValue.bind,
            versionNumber: 1,
            lastEdited: DateTime(2026),
            folderID: null,
            pages: [
              StrategyPage(
                id: 'a',
                name: 'A',
                drawingData: const [],
                agentData: const [],
                abilityData: const [],
                textData: const [],
                imageData: [_image('image-a'), _image('image-missing')],
                utilityData: const [],
                sortIndex: 0,
                isAttack: true,
                settings: StrategySettings(),
              ),
            ],
          ),
        );
      });
      final strategy = _OpenStrategy(
        StrategySource.local,
        storageDirectory: storage,
      );
      final ref = await _pumpRef(tester, [
        strategyProvider.overrideWith(() => strategy),
      ]);

      final source = await tester.runAsync(
        () => loadVideoExportSource(ref, pageIds: {'a'}),
      );
      addTearDown(source!.images.release);

      expect(strategy.saves, 1);
      expect(source.strategy.mapData, MapValue.bind);
      expect(source.images.sources['image-a'], isA<LocalImageFile>());
      // A file the editor cannot find is exported as it shows: unavailable.
      expect(source.images.sources['image-missing'], isA<ImageFailed>());
    });
  });
}

class _TwoPageSnapshot extends RemoteEditorSnapshotNotifier {
  @override
  Future<RemoteEditorSnapshot?> build() async {
    final now = DateTime.utc(2026);
    RemotePage page(String id, String name, int sortIndex) => RemotePage(
          publicId: id,
          strategyPublicId: _strategyId,
          name: name,
          sortIndex: sortIndex,
          isAttack: true,
          revision: 1,
          createdAt: now,
          updatedAt: now,
        );
    return RemoteEditorSnapshot(
      shell: RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: _strategyId,
          name: 'Strategy',
          mapData: Maps.mapNames[MapValue.ascent]!,
          revision: 1,
          createdAt: now,
          updatedAt: now,
          role: 'owner',
        ),
        pages: [page('second', 'Second', 1), page('first', 'First', 0)],
      ),
      activePage: null,
    );
  }
}
