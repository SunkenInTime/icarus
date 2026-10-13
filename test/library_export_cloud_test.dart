import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/archive_manifest.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final _png = Uint8List.fromList(
  img.encodePng(
    img.fill(img.Image(width: 4, height: 4), color: img.ColorRgb8(1, 2, 3)),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    appProviderContainer = ProviderContainer();
    registerIcarusAdapters(Hive);
  });

  tearDownAll(() {
    appProviderContainer.dispose();
  });

  late Directory tempDir;
  late _CloudRepository repository;
  late _Queue queue;
  late _Uploads uploads;
  late _MediaCache mediaCache;

  ProviderContainer signedIn({bool connected = true}) {
    final container = ProviderContainer(overrides: [
      authProvider.overrideWith(_SignedIn.new),
      // Signed in, My Library's workspace is the cloud one.
      libraryWorkspaceProvider.overrideWith(_CloudWorkspace.new),
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      convexConnectionSnapshotProvider.overrideWithValue(connected),
      strategyOpQueueProvider.overrideWith(() => queue),
      cloudMediaUploadQueueProvider.overrideWith(() => uploads),
      cloudMediaCacheProvider.overrideWith(() => mediaCache),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-cloud-export-');
    // Cloud images are cached, and imports write theirs, under the app's
    // support folder; keep both inside this test's directory.
    final support =
        await Directory(path.join(tempDir.path, 'support')).create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => support.path);
    Hive.init(path.join(tempDir.path, 'hive'));
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    await MapThemeProfilesProvider.bootstrap();

    repository = _CloudRepository();
    queue = _Queue();
    uploads = _Uploads();
    mediaCache = _MediaCache({
      for (final id in ['cloud-picture', 'lineup-picture']) id: _png,
    });
  });

  tearDown(() async {
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await tempDir.delete(recursive: true);
  });

  test('library backup holds the cloud library and restores all of it',
      () async {
    await _storeLocalLibrary();
    final container = signedIn();

    final backup = await _zip(
      await StrategyImportExportService(container)
          .buildLibraryExportDirectoryForTest(),
      path.join(tempDir.path, 'library-backup.zip'),
    );
    expect(repository.scopes, everyElement('owned'));
    await _emptyLocalLibrary();

    final result = await StrategyImportExportService(container)
        .loadFromFileDrop([XFile(backup.path)]);

    expect(result.issues, isEmpty);
    expect(result.strategiesImported, 4);
    expect(result.foldersCreated, 3);

    // Everything lands in the local library, at the level it had.
    final cloudFolder = _folderByName('Cloud Plays');
    final retakes = _folderByName('Retakes');
    final localFolder = _folderByName('Local Plays');
    expect(cloudFolder.parentID, isNull);
    expect(cloudFolder.color, FolderColor.blue);
    expect(retakes.parentID, cloudFolder.id);
    expect(localFolder.parentID, isNull);
    expect(_strategyByName('Cloud Root').folderID, isNull);
    expect(_strategyByName('Cloud Deep').folderID, retakes.id);
    expect(_strategyByName('Local Root').folderID, isNull);
    expect(_strategyByName('Local In Folder').folderID, localFolder.id);

    await _expectCloudRootRestored(_strategyByName('Cloud Root'));
  });

  test('cloud folder export restores the folder and everything under it',
      () async {
    final container = signedIn();

    final export = await _zip(
      await StrategyImportExportService(container)
          .buildFolderExportDirectoryForTest(
        'cloud-folder',
        store: LibraryWorkspace.cloud,
      ),
      path.join(tempDir.path, 'folder-export.zip'),
    );
    // A folder may be one shared with the user, so it reads whatever they
    // can open.
    expect(repository.scopes, everyElement('all'));

    final result = await StrategyImportExportService(container)
        .loadFromFileDrop([XFile(export.path)]);

    expect(result.issues, isEmpty);
    expect(result.foldersCreated, 2);
    expect(result.strategiesImported, 1);
    final cloudFolder = _folderByName('Cloud Plays');
    final retakes = _folderByName('Retakes');
    expect(cloudFolder.parentID, isNull);
    expect(retakes.parentID, cloudFolder.id);
    expect(_strategyByName('Cloud Deep').folderID, retakes.id);
    expect(
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .values
          .where((strategy) => strategy.name == 'Cloud Root'),
      isEmpty,
    );
  });

  test('local folder export still finds the folder while signed in', () async {
    await _storeLocalLibrary();
    final container = signedIn();
    final localFolder = _folderByName('Local Plays');

    final export = await _zip(
      await StrategyImportExportService(container)
          .buildFolderExportDirectoryForTest(localFolder.id),
      path.join(tempDir.path, 'local-folder-export.zip'),
    );
    expect(repository.scopes, isEmpty);
    await _emptyLocalLibrary();

    final result = await StrategyImportExportService(container)
        .loadFromFileDrop([XFile(export.path)]);

    expect(result.issues, isEmpty);
    expect(result.foldersCreated, 1);
    expect(result.strategiesImported, 1);
    expect(
      _strategyByName('Local In Folder').folderID,
      _folderByName('Local Plays').id,
    );
  });

  test('a cloud strategy that cannot be read stops the backup', () async {
    repository.unreadable.add('cloud-deep');
    final container = signedIn();

    await expectLater(
      StrategyImportExportService(container)
          .buildLibraryExportDirectoryForTest(),
      throwsA(isA<LibraryExportIncomplete>()),
    );
  });

  test('a cloud image that cannot be downloaded stops the backup', () async {
    mediaCache = _MediaCache({'cloud-picture': _png});
    final container = signedIn();

    await expectLater(
      StrategyImportExportService(container)
          .buildLibraryExportDirectoryForTest(),
      throwsA(isA<LibraryExportIncomplete>()),
    );
  });

  test('a cloud library that cannot be listed stops the backup', () async {
    repository.listingFails = true;
    final container = signedIn();

    await expectLater(
      StrategyImportExportService(container)
          .buildLibraryExportDirectoryForTest(),
      throwsA(isA<LibraryExportIncomplete>()),
    );
  });

  test('offline, a signed-in backup stops before asking the cloud', () async {
    final container = signedIn(connected: false);

    await expectLater(
      StrategyImportExportService(container)
          .buildLibraryExportDirectoryForTest(),
      throwsA(isA<LibraryExportIncomplete>()),
    );
    expect(repository.scopes, isEmpty);
  });

  test('a backup waits for unsent cloud changes to land', () async {
    queue.unsent = {'cloud-root': _unsent('cloud-root')};
    final container = signedIn();

    final building = StrategyImportExportService(container)
        .buildLibraryExportDirectoryForTest();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(repository.snapshotsRead, isEmpty);
    queue.land();

    final directory = await building;
    addTearDown(() => directory.delete(recursive: true));
    expect(repository.snapshotsRead, containsAll(['cloud-root', 'cloud-deep']));
  });

  test('cloud changes held for review stop the backup', () async {
    queue.unsent = {'cloud-root': _unsent('cloud-root', paused: 1)};
    final container = signedIn();

    await expectLater(
      StrategyImportExportService(container)
          .buildLibraryExportDirectoryForTest(),
      throwsA(
        isA<LibraryExportIncomplete>().having(
          (error) => error.userMessage,
          'userMessage',
          contains("haven't synced"),
        ),
      ),
    );
    expect(repository.snapshotsRead, isEmpty);
  });

  test('unreadable saved cloud work stops the backup', () async {
    // After a restart, a saved change that cannot be decoded is only a
    // load issue: it names no strategy, so none can be shown to be synced.
    queue.loadIssues = const [
      DurableOutboxLoadIssue(storageKey: 'unreadable', error: 'bad record'),
    ];
    final container = signedIn();

    await expectLater(
      StrategyImportExportService(container)
          .buildLibraryExportDirectoryForTest(),
      throwsA(
        isA<LibraryExportIncomplete>().having(
          (error) => error.userMessage,
          'userMessage',
          contains("can't read some cloud changes"),
        ),
      ),
    );
    expect(repository.snapshotsRead, isEmpty);
  });

  test('an unreadable saved image upload stops the backup', () async {
    uploads.loadIssues = const [
      DurableCloudMediaOutboxLoadIssue(
        storageKey: 'unreadable',
        error: 'bad record',
      ),
    ];
    final container = signedIn();

    await expectLater(
      StrategyImportExportService(container)
          .buildLibraryExportDirectoryForTest(),
      throwsA(isA<LibraryExportIncomplete>()),
    );
    expect(repository.snapshotsRead, isEmpty);
  });

  test('a strategy moved between folders mid-backup stops the backup',
      () async {
    // Once "Cloud Plays" is listed, another device moves "Cloud Deep" out of
    // "Retakes", not yet listed, into it: neither listing holds it.
    repository.afterListing = (folderId) {
      if (folderId == 'cloud-folder') {
        repository.afterListing = null;
        repository.move('cloud-deep', 'cloud-folder');
      }
    };
    final container = signedIn();

    await expectLater(
      StrategyImportExportService(container)
          .buildLibraryExportDirectoryForTest(),
      throwsA(
        isA<LibraryExportIncomplete>().having(
          (error) => error.userMessage,
          'userMessage',
          contains('changed while exporting'),
        ),
      ),
    );
  });

  test('a strategy moved mid-export stops a cloud folder export', () async {
    repository.afterListing = (folderId) {
      if (folderId == 'cloud-folder') {
        repository.afterListing = null;
        repository.move('cloud-deep', 'cloud-folder');
      }
    };
    final container = signedIn();

    await expectLater(
      StrategyImportExportService(container).buildFolderExportDirectoryForTest(
        'cloud-folder',
        store: LibraryWorkspace.cloud,
      ),
      throwsA(isA<LibraryExportIncomplete>()),
    );
  });

  test('signed out, the backup is the local library and asks no cloud',
      () async {
    await _storeLocalLibrary();
    final container = ProviderContainer(overrides: [
      authProvider.overrideWith(_SignedOut.new),
      convexStrategyRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);

    final directory = await StrategyImportExportService(container)
        .buildLibraryExportDirectoryForTest();
    addTearDown(() => directory.delete(recursive: true));

    expect(repository.scopes, isEmpty);
    final manifest = await _manifest(directory);
    expect(
      manifest.strategies.map((entry) => entry.name),
      unorderedEquals(['Local Root', 'Local In Folder']),
    );
  });
}

Future<void> _expectCloudRootRestored(StrategyData restored) async {
  expect(restored.mapData, MapValue.ascent);
  expect(restored.pages.map((page) => page.name), ['Opening', 'Retake']);

  final opening = restored.pages.first;
  expect(opening.imageData.single.pictureId, 'cloud-picture');

  final retake = restored.pages.last;
  final link = retake.lineUpLinks.single;
  expect(link.name, 'Garage smoke');
  expect(link.notes, 'jump throw');
  expect(link.images.single.id, 'lineup-picture');
  expect(retake.lineUpOrigins.single.id, 'origin-1');
  expect(retake.lineUpLandings.single.id, 'landing-1');

  final images = await PlacedImageProvider.getImageFolder(restored.id);
  for (final picture in ['cloud-picture', 'lineup-picture']) {
    final file = File(path.join(images.path, '$picture.png'));
    expect(await file.readAsBytes(), _png, reason: picture);
  }
}

/// A local folder "Local Plays" holding "Local In Folder", and "Local Root"
/// beside it.
Future<void> _storeLocalLibrary() async {
  final folder = Folder(
    id: 'local-folder',
    name: 'Local Plays',
    dateCreated: DateTime.utc(2026, 1, 1),
  );
  await Hive.box<Folder>(HiveBoxNames.foldersBox).put(folder.id, folder);
  for (final (id, name, folderId) in [
    ('local-root', 'Local Root', null),
    ('local-in-folder', 'Local In Folder', folder.id),
  ]) {
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
      id,
      StrategyData(
        id: id,
        name: name,
        mapData: MapValue.bind,
        versionNumber: Settings.versionNumber,
        lastEdited: DateTime.utc(2026, 1, 1),
        folderID: folderId,
        pages: const [],
      ),
    );
  }
}

Future<void> _emptyLocalLibrary() async {
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();
  await Hive.box<Folder>(HiveBoxNames.foldersBox).clear();
}

/// Zips [stagingDirectory] as the export actions do, then removes it.
Future<File> _zip(Directory stagingDirectory, String zipPath) async {
  final encoder = ZipFileEncoder()..create(zipPath);
  await encoder.addDirectory(stagingDirectory, includeDirName: false);
  await encoder.close();
  await stagingDirectory.delete(recursive: true);
  return File(zipPath);
}

Future<ArchiveManifest> _manifest(Directory stagingDirectory) async {
  final file = File(path.join(
    stagingDirectory.path,
    libraryBackupRootDirectoryName,
    archiveMetadataFileName,
  ));
  return ArchiveManifest.fromJson(
    jsonDecode(await file.readAsString()) as Map<String, dynamic>,
  );
}

Folder _folderByName(String name) => Hive.box<Folder>(HiveBoxNames.foldersBox)
    .values
    .singleWhere((folder) => folder.name == name);

StrategyData _strategyByName(String name) =>
    Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .singleWhere((strategy) => strategy.name == name);

StrategyOutboxSummary _unsent(String strategyId, {int paused = 0}) =>
    StrategyOutboxSummary(
      strategyPublicId: strategyId,
      queuedCount: paused == 0 ? 1 : 0,
      inFlightCount: 0,
      pausedCount: paused,
      attentionCount: 0,
      successorCount: 0,
    );

class _SignedIn extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );
}

class _CloudWorkspace extends LibraryWorkspaceNotifier {
  @override
  LibraryWorkspace build() => LibraryWorkspace.cloud;
}

/// This device's op queue, holding [unsent] of the account's work when it
/// is first read.
class _Queue extends StrategyOpQueueNotifier {
  Map<String, StrategyOutboxSummary> unsent = const {};
  List<DurableOutboxLoadIssue> loadIssues = const [];

  static StrategyOpQueueState _holding(
    Map<String, StrategyOutboxSummary> unsent,
  ) =>
      StrategyOpQueueState(
        durableLoaded: true,
        accountOutbox: AccountStrategyOutboxSummary(strategies: unsent),
      );

  @override
  StrategyOpQueueState build() => StrategyOpQueueState(
        durableLoaded: true,
        loadIssues: loadIssues,
        accountOutbox: AccountStrategyOutboxSummary(strategies: unsent),
      );

  /// Everything still to send lands.
  void land() => state = _holding(const {});
}

class _Uploads extends CloudMediaUploadQueueNotifier {
  List<DurableCloudMediaOutboxLoadIssue> loadIssues = const [];

  @override
  CloudMediaUploadQueueState build() => CloudMediaUploadQueueState(
        jobs: const [],
        isProcessing: false,
        loadIssues: loadIssues,
      );
}

/// Serves the pictures in [bytesById] as downloads; any other fails.
class _MediaCache extends CloudMediaCacheNotifier {
  _MediaCache(this.bytesById);

  final Map<String, Uint8List> bytesById;

  @override
  Future<File?> ensureAssetCached({
    required String strategyId,
    required String strategyPublicId,
    required RemoteImageAsset asset,
  }) async {
    final bytes = bytesById[asset.publicId];
    if (bytes == null) return null;
    final file = File(await localAssetPath(
      strategyId: strategyId,
      assetId: asset.publicId,
      fileExtension: asset.fileExtension,
    ));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }
}

/// The signed-in user's cloud library: "Cloud Root" at the top level, with
/// two pages, an image and a lineup, and the folder "Cloud Plays" holding
/// "Retakes", which holds "Cloud Deep".
class _CloudRepository extends Fake implements ConvexStrategyRepository {
  final scopes = <String>[];
  final snapshotsRead = <String>[];
  final unreadable = <String>{};
  var listingFails = false;

  /// Runs after each folder's strategies are listed, as another device
  /// might change the library between two listings.
  void Function(String? folderPublicId)? afterListing;

  static final _created = DateTime.utc(2026, 9, 1);

  static final _folders = <CloudFolderEntry>[
    _folderEntry(Folder(
      id: 'cloud-folder',
      name: 'Cloud Plays',
      dateCreated: _created,
      color: FolderColor.blue,
    )),
    _folderEntry(Folder(
      id: 'cloud-subfolder',
      name: 'Retakes',
      dateCreated: _created,
      parentID: 'cloud-folder',
    )),
  ];

  final _strategies = <CloudStrategyEntry>[
    _strategyEntry('cloud-root', 'Cloud Root', null),
    _strategyEntry('cloud-deep', 'Cloud Deep', 'cloud-subfolder'),
  ];

  static CloudFolderEntry _folderEntry(Folder folder) => (
        folder: folder,
        role: 'owner',
        strategyCount: 1,
        mapPeeks: const <MapValue>[],
        agentTypes: const <AgentType>[],
      );

  static CloudStrategyEntry _strategyEntry(
    String id,
    String name,
    String? folderId,
  ) =>
      (
        strategy: StrategyData(
          id: id,
          name: name,
          mapData: MapValue.ascent,
          versionNumber: Settings.versionNumber,
          lastEdited: _created,
          folderID: folderId,
        ),
        revision: 1,
        role: 'owner',
        attackLabel: 'attack',
      );

  @override
  Future<List<CloudFolderEntry>> fetchFolders({String scope = 'owned'}) async {
    scopes.add(scope);
    if (listingFails) throw StateError('offline');
    return _folders;
  }

  @override
  Future<List<CloudStrategyEntry>> fetchStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) async {
    scopes.add(scope);
    final listed = [
      for (final entry in _strategies)
        if (entry.strategy.folderID == folderPublicId) entry,
    ];
    afterListing?.call(folderPublicId);
    return listed;
  }

  /// Another device moves [strategyId] into [folderId].
  void move(String strategyId, String? folderId) {
    final index =
        _strategies.indexWhere((entry) => entry.strategy.id == strategyId);
    final entry = _strategies[index];
    _strategies[index] = _strategyEntry(
      strategyId,
      entry.strategy.name,
      folderId,
    );
  }

  @override
  Future<RemoteFullStrategySnapshot> fetchFullSnapshot(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    if (unreadable.contains(strategyPublicId)) throw StateError('offline');
    snapshotsRead.add(strategyPublicId);
    final name = _strategies
        .singleWhere((entry) => entry.strategy.id == strategyPublicId)
        .strategy
        .name;
    final isRoot = strategyPublicId == 'cloud-root';

    RemoteFullPage page(String id, String name, int sortIndex) =>
        RemoteFullPage(
          page: RemotePage(
            publicId: id,
            strategyPublicId: strategyPublicId,
            name: name,
            sortIndex: sortIndex,
            isAttack: true,
            revision: 1,
            createdAt: _created,
            updatedAt: _created,
          ),
          content: RemotePageContent(
            revision: 1,
            createdAt: _created,
            updatedAt: _created,
          ),
        );

    RemoteImageAsset asset(String id) => RemoteImageAsset(
          publicId: id,
          fileExtension: '.png',
          width: 4,
          height: 4,
          url: 'https://media.example.com/$id.png',
          legacyStoragePath: null,
        );

    if (!isRoot) {
      return RemoteFullStrategySnapshot(
        header: _header(strategyPublicId, name),
        pages: [page('$strategyPublicId-page', 'Page 1', 0)],
        elementsByPage: const {},
        lineupsByPage: const {},
        assetsById: const {},
      );
    }

    final lineups = cloudLineupRows(LineUpGraph(
      origins: [
        LineUpOrigin(
          id: 'origin-1',
          agent: PlacedAgent(
            id: 'agent-1',
            type: AgentType.sova,
            position: const Offset(10, 20),
            lineUpID: 'origin-1',
          ),
        ),
      ],
      landings: [
        LineUpLanding(
          id: 'landing-1',
          ability: PlacedAbility(
            id: 'ability-1',
            data: AgentData.agents[AgentType.sova]!.abilities[2],
            position: const Offset(30, 40),
            lineUpID: 'landing-1',
          ),
        ),
      ],
      links: [
        LineUpLink(
          id: 'link-1',
          originId: 'origin-1',
          landingId: 'landing-1',
          name: 'Garage smoke',
          notes: 'jump throw',
          images: [
            SimpleImageData(id: 'lineup-picture', fileExtension: '.png'),
          ],
        ),
      ],
    )).rows;

    return RemoteFullStrategySnapshot(
      header: _header(strategyPublicId, name),
      // Out of order on purpose: the backup keeps the strategy's order.
      pages: [page('retake', 'Retake', 1), page('opening', 'Opening', 0)],
      elementsByPage: {
        'opening': [
          RemoteElement(
            publicId: 'cloud-picture',
            strategyPublicId: strategyPublicId,
            pagePublicId: 'opening',
            elementType: 'image',
            payload: cloudElementPayload(
              kind: 'image',
              data: cloudImagePayloadFromPlacedImage(PlacedImage(
                id: 'cloud-picture',
                position: const Offset(500, 500),
                aspectRatio: 1,
                scale: 100,
                fileExtension: '.png',
              )),
            ),
            sortIndex: 0,
            revision: 1,
            deleted: false,
          ),
        ],
      },
      lineupsByPage: {
        'retake': [
          for (final row in lineups)
            RemoteLineup(
              publicId: row.publicId,
              strategyPublicId: strategyPublicId,
              pagePublicId: 'retake',
              payload: row.payload,
              sortIndex: 0,
              revision: 1,
              deleted: false,
            ),
        ],
      },
      assetsById: {
        for (final id in ['cloud-picture', 'lineup-picture']) id: asset(id),
      },
    );
  }

  RemoteStrategyHeader _header(String id, String name) => RemoteStrategyHeader(
        publicId: id,
        name: name,
        mapData: Maps.mapNames[MapValue.ascent]!,
        revision: 1,
        createdAt: _created,
        updatedAt: _created,
      );
}
