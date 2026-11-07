import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/move_to_cloud_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/archive_manifest.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:path/path.dart' as p;

import '../collab/strategy_copy_fixtures.dart';

var _adaptersRegistered = false;

final _account = StateProvider<String?>((ref) => 'account-1');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  late Directory dir;
  late _FakeCloud cloud;
  late _HeldUploads uploads;
  late List<(String, bool)> messages;
  late MemoryCloudStrategyCopyStore offlineCopy;
  late ProviderContainer container;

  Box<StrategyData> strategies() =>
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
  Box<Folder> folders() => Hive.box<Folder>(HiveBoxNames.foldersBox);
  Box<dynamic> moves() => Hive.box<dynamic>(HiveBoxNames.cloudMovesBox);
  File imageFile(String strategyId, String imageId) =>
      File(p.join(dir.path, strategyId, 'images', '$imageId.png'));
  MoveToCloudNotifier mover() => container.read(moveToCloudProvider.notifier);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('move_to_cloud_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => dir.path);
    Hive.init(dir.path);
    if (!_adaptersRegistered) {
      registerIcarusAdapters(Hive);
      _adaptersRegistered = true;
    }
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    await Hive.openBox<dynamic>(HiveBoxNames.cloudMovesBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    cloud = _FakeCloud();
    uploads = _HeldUploads(cloud);
    messages = [];
    offlineCopy = MemoryCloudStrategyCopyStore();
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await dir.delete(recursive: true);
  });

  ProviderContainer open({StrategyProvider Function()? editor}) {
    return container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(cloud),
      authProvider.overrideWith(_CloudReadyAuth.new),
      cloudMediaAccountIdProvider.overrideWith((ref) => ref.watch(_account)),
      convexConnectionSnapshotProvider.overrideWithValue(true),
      cloudMediaUploadQueueProvider.overrideWith(() => uploads),
      strategyProvider.overrideWith(editor ?? _ClosedStrategy.new),
      cloudStrategiesProvider.overrideWith((ref) => const Stream.empty()),
      cloudFolderTreeProvider.overrideWith((ref) => const Stream.empty()),
      moveToCloudMessageProvider.overrideWithValue(
        (message, {failed = false}) => messages.add((message, failed)),
      ),
      cloudStrategyCopyStoreProvider.overrideWithValue(offlineCopy),
      cloudCopyScopeProvider.overrideWith((ref) {
        final accountId = ref.watch(_account);
        return accountId == null
            ? null
            : CloudCopyScope.begin(
                deploymentUrl: 'https://one.convex.cloud',
                accountId: accountId,
              );
      }),
    ]);
  }

  /// Waits until the move reaches its image uploads.
  Future<void> untilUploading() async {
    for (var i = 0; i < 200 && uploads.held.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(uploads.held, isNotEmpty);
  }

  /// Two pages: an agent on both (one id), an image on the first, a text on
  /// the second.
  Future<void> putStrategy(
    String id, {
    String? folderID,
    String? themeProfileId,
    String imageExtension = '.png',
  }) async {
    StrategyPage page(String pageId, int index, {bool withImage = false}) =>
        StrategyPage(
          id: pageId,
          name: 'Page ${index + 1}',
          isAutoNamed: true,
          drawingData: const [],
          agentData: [
            PlacedAgent(
              id: '$id-agent',
              type: AgentType.sova,
              position: const Offset(10, 20),
            ),
          ],
          abilityData: const [],
          textData: [
            if (!withImage)
              PlacedText(position: const Offset(5, 5), id: '$id-text'),
          ],
          imageData: [
            if (withImage)
              PlacedImage(
                position: const Offset(1, 2),
                id: '$id-image',
                aspectRatio: 1,
                scale: 1,
                fileExtension: imageExtension,
              ),
          ],
          utilityData: const [],
          sortIndex: index,
          isAttack: index == 0,
          settings: StrategySettings(),
        );
    await strategies().put(
      id,
      StrategyData(
        id: id,
        name: 'Strategy $id',
        mapData: MapValue.bind,
        versionNumber: Settings.versionNumber,
        lastEdited: DateTime.utc(2026),
        folderID: folderID,
        themeProfileId: themeProfileId,
        pages: [page('$id-p2', 1), page('$id-p1', 0, withImage: true)],
      ),
    );
    await imageFile(id, '$id-image').create(recursive: true);
    await imageFile(id, '$id-image').writeAsBytes([1, 2, 3]);
  }

  group('Import inside a cloud folder', () {
    final ica = File('test/fixtures/strategy_integrity/base-test.ica')
        .readAsBytesSync();

    Future<void> importInto(String cloudFolderId, File file) async {
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
      cloud.folders[cloudFolderId] =
          _CloudFolder(cloudFolderId, 'Plays', null, null);
      open();
      container
          .read(folderProvider.notifier)
          .openFolder(folderId: cloudFolderId, store: LibraryWorkspace.cloud);
      FilePicker.platform = _PickedFile(file.path);
      await StrategyImportExportService(container).importFromFilePicker();
    }

    File zipOf(String name, Map<String, List<int>> entries) {
      final archive = Archive();
      for (final MapEntry(:key, :value) in entries.entries) {
        archive.addFile(ArchiveFile(key, value.length, value));
      }
      return File(p.join(dir.path, name))
        ..writeAsBytesSync(ZipEncoder().encode(archive));
    }

    File folderArchive() => zipOf('Team Strats.zip', {
          'Team Strats/default.ica': ica,
          'Team Strats/Retakes/a-site.ica': ica,
        });

    _CloudFolder cloudFolder(String name) =>
        cloud.folders.values.singleWhere((folder) => folder.name == name);
    _CloudStrategy cloudStrategy(String name) =>
        cloud.strategies.values.singleWhere((s) => s.name == name);

    test('an .ica lands in that folder and leaves nothing on this device',
        () async {
      await importInto(
        'plays',
        File('test/fixtures/strategy_integrity/base-test.ica'),
      );

      final created = cloud.strategies.values.single;
      expect(created.name, 'base-test');
      expect(created.folderId, 'plays');
      expect(created.unfinished, isFalse);
      expect(strategies().values, isEmpty);
      expect(
        messages,
        [('Importing "base-test" to the cloud…', false)],
        reason: 'the import itself says it worked',
      );
    });

    test('an .ica stays on this device when it cannot reach the folder',
        () async {
      cloud.refuseBatchesOf = {'base-test'};

      await importInto(
        'plays',
        File('test/fixtures/strategy_integrity/base-test.ica'),
      );

      expect(cloud.strategies, isEmpty);
      expect(strategies().values.single.name, 'base-test');
      expect(strategies().values.single.folderID, isNull,
          reason: 'never a cloud id in the local library');
      expect(messages.last.$2, isTrue, reason: 'the user is told');
    });

    test('a folder archive lands in that folder whole', () async {
      await importInto('plays', folderArchive());

      final root = cloudFolder('Team Strats');
      expect(root.parentId, 'plays');
      expect(cloudFolder('Retakes').parentId, root.id);
      expect(cloudStrategy('default').folderId, root.id);
      expect(cloudStrategy('a-site').folderId, cloudFolder('Retakes').id);
      expect(strategies().values, isEmpty);
      expect(folders().values, isEmpty);
      expect(
        messages,
        [('Importing "Team Strats" to the cloud…', false)],
        reason: 'the import itself says it worked',
      );
    });

    test('a folder archive that cannot move stays on this device', () async {
      cloud.refuseBatchesOf = {'a-site'};

      await importInto('plays', folderArchive());

      expect(cloudStrategy('default').folderId, cloudFolder('Team Strats').id);
      Folder local(String name) =>
          folders().values.singleWhere((folder) => folder.name == name);
      expect(local('Team Strats').parentID, isNull,
          reason: 'never a cloud id in the local library');
      expect(local('Retakes').parentID, local('Team Strats').id);
      expect(strategies().values.single.folderID, local('Retakes').id);
      expect(messages.last.$2, isTrue, reason: 'the user is told');
    });

    test('a library backup puts its top level in that folder', () async {
      final manifest = {
        'schemaVersion': archiveManifestSchemaVersion,
        'archiveType': ArchiveType.libraryBackup.jsonValue,
        'exportedAt': '2026-01-01T00:00:00.000Z',
        'appVersionNumber': Settings.versionNumber,
        'folders': [
          {
            'manifestId': 'f1',
            'name': 'Defaults',
            'parentManifestId': null,
            'archivePath': 'folders/Defaults',
            'color': 'generic',
          },
        ],
        'strategies': [
          {
            'name': 'Loose',
            'archivePath': 'root_strategies/Loose.ica',
            'folderManifestId': null,
          },
          {
            'name': 'Filed',
            'archivePath': 'folders/Defaults/Filed.ica',
            'folderManifestId': 'f1',
          },
        ],
        'globals': {'themeProfiles': [], 'favoriteAgents': []},
      };
      final backup = zipOf('backup.zip', {
        archiveMetadataFileName: utf8.encode(jsonEncode(manifest)),
        'root_strategies/Loose.ica': ica,
        'folders/Defaults/Filed.ica': ica,
      });

      await importInto('plays', backup);

      expect(cloudFolder('Defaults').parentId, 'plays');
      expect(cloudStrategy('Filed').folderId, cloudFolder('Defaults').id);
      expect(cloudStrategy('Loose').folderId, 'plays');
      expect(strategies().values, isEmpty);
      expect(folders().values, isEmpty);
      expect(messages.where((m) => m.$2), isEmpty);
    });
  });

  test('a strategy lands whole in the cloud, then leaves this device',
      () async {
    await putStrategy('s1');
    open();
    await container.read(pinnedItemsProvider.notifier).togglePin('s1');

    await mover().moveStrategy('s1');

    final created = cloud.strategies.values.single;
    expect(created.name, 'Strategy s1');
    expect(created.mapData, Maps.mapNames[MapValue.bind]);
    expect(created.folderId, isNull);
    expect(created.id, isNot('s1'), reason: 'cloud ids are fresh');
    expect(created.madeUnfinished, isTrue);
    expect(created.unfinished, isFalse, reason: 'finished once checked');
    // Pages in their order, first page made with the strategy.
    expect(created.pages.map((page) => page.name), ['Page 1', 'Page 2']);
    expect(created.pages.map((page) => page.isAttack), [true, false]);
    expect(created.pages.first.id, isNot('s1-p1'));

    final elements = created.elements;
    final agents = elements.where((e) => e.kind == 'agent').toList();
    expect(agents.map((e) => e.pageId), [
      created.pages[0].id,
      created.pages[1].id,
    ]);
    // One agent on both pages keeps one root, so the page transition still
    // moves it from page to page.
    expect(agents[0].id, isNot('s1-agent'));
    expect(pageCopyRoot(agents[1].id), agents[0].id);
    expect(elements.where((e) => e.kind == 'text'), hasLength(1));

    // Its picture went up under a fresh id, from a copy in the cloud
    // strategy's folder.
    final picture =
        elements.singleWhere((e) => e.kind == 'image').data['assetId'];
    expect(picture, isNot('s1-image'));
    expect(created.activePictures, {picture});
    expect(imageFile(created.id, picture as String).existsSync(), isTrue);

    expect(strategies().containsKey('s1'), isFalse);
    expect(Directory(p.join(dir.path, 's1')).existsSync(), isFalse);
    expect(container.read(pinnedItemsProvider).keys, [created.id]);
    expect(moves().isEmpty, isTrue);
    expect(container.read(movingToCloudProvider), isEmpty);
    expect(messages, [('Moved "Strategy s1" to the cloud.', false)]);
  });

  test('a moved strategy is kept offline from the read that checked it',
      () async {
    await putStrategy('s1');
    open();

    await mover().moveStrategy('s1');

    final moved = cloud.strategies.keys.single;
    final scope = container.read(cloudCopyScopeProvider)!;
    expect(cloud.fullReads, [moved], reason: 'read once, to check it');
    expect(offlineCopy.keepsStrategy(scope, moved), isTrue);
    expect(
      offlineCopy.readShell(scope, moved)!.pages.map((page) => page.name),
      ['Page 1', 'Page 2'],
    );
    // Refreshed, so the copy's walk leaves it alone: its picture was already
    // on disk, copied there for the upload, so nothing had to download.
    expect(offlineCopy.lastFullRefresh(scope, moved), isNotNull);
  });

  test("a custom map theme's colors go with it; a built-in one by name",
      () async {
    final custom = MapThemeProfilesProvider.immutableValorantPalette;
    await Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox).put(
      'my-theme',
      MapThemeProfile(
        id: 'my-theme',
        name: 'Mine',
        palette: custom,
        isBuiltIn: false,
      ),
    );
    await putStrategy('s1', themeProfileId: 'my-theme');
    await putStrategy(
      's2',
      themeProfileId: MapThemeProfilesProvider.immutableLotusMossProfileId,
    );
    open();

    await mover().moveStrategy('s1');
    await mover().moveStrategy('s2');

    final byName = {
      for (final strategy in cloud.strategies.values) strategy.name: strategy,
    };
    expect(byName['Strategy s1']!.themeProfileId, isNull);
    expect(byName['Strategy s1']!.themePalette, custom.toJson());
    expect(
      byName['Strategy s2']!.themeProfileId,
      MapThemeProfilesProvider.immutableLotusMossProfileId,
    );
    expect(byName['Strategy s2']!.themePalette, isNull);
  });

  test('a folder made but not answered for is deleted with the rest', () async {
    await folders().put(
      'f1',
      Folder(
        id: 'f1',
        name: 'Bind',
        iconId: 0,
        color: FolderColor.red,
        dateCreated: DateTime.utc(2026),
      ),
    );
    await putStrategy('s1', folderID: 'f1');
    cloud.loseFolderAnswer = true;
    open();

    await mover().moveFolder('f1');

    expect(cloud.folders, isEmpty);
    expect(cloud.strategies, isEmpty);
    expect(folders().keys, ['f1']);
    expect(strategies().keys, ['s1']);
    expect(messages.single.$2, isTrue);
  });

  test("a moving strategy's cloud copy can't be opened", () async {
    await putStrategy('s1');
    uploads.autoUpload = false;
    open();

    final move = mover().moveStrategy('s1');
    await untilUploading();
    await expectLater(
      container
          .read(strategyProvider.notifier)
          .openCloudStrategy(cloud.strategies.keys.single),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('moving to the cloud'),
        ),
      ),
    );
    uploads.uploadAll();
    await move;
    expect(container.read(movingToCloudProvider), isEmpty);
  });

  test('an edit landing as the move finishes keeps the edited original',
      () async {
    await putStrategy('s1');
    open();
    cloud.onFinish = () async {
      final edited = strategies().get('s1')!.copyWith(name: 'Strategy s1 v2');
      await strategies().put('s1', edited);
    };

    await mover().moveStrategy('s1');

    expect(cloud.strategies.values.single.unfinished, isFalse);
    expect(strategies().get('s1')!.name, 'Strategy s1 v2');
    expect(moves().isEmpty, isTrue);
    expect(messages, [
      (
        'Moved "Strategy s1" to the cloud. It changed while moving, so this '
            'device keeps the latest version too.',
        true,
      ),
    ]);
  });

  test('a copy that could not be abandoned stays locked', () async {
    await putStrategy('s1');
    cloud.refuseBatchesOf = {'Strategy s1'};
    cloud.refuseAbandon = true;
    open();

    await mover().moveStrategy('s1');

    final copy = cloud.strategies.keys.single;
    expect(moves().keys, [copy], reason: 'cleanup will try again');
    expect(container.read(movingToCloudProvider), {copy});
    await expectLater(
      container.read(strategyProvider.notifier).openCloudStrategy(copy),
      throwsStateError,
    );
    expect(strategies().containsKey('s1'), isTrue);
  });

  test("a folder can't be deleted while something in it moves", () async {
    await folders().put(
      'f1',
      Folder(
        id: 'f1',
        name: 'Bind',
        iconId: 0,
        color: FolderColor.red,
        dateCreated: DateTime.utc(2026),
      ),
    );
    await putStrategy('s1', folderID: 'f1');
    uploads.autoUpload = false;
    open();

    final move = mover().moveStrategy('s1');
    await untilUploading();
    final result = await container
        .read(folderProvider.notifier)
        .deleteFolder('f1', workspace: LibraryWorkspace.local);
    expect(result.didSucceed, isFalse);
    expect(folders().containsKey('f1'), isTrue);
    expect(strategies().containsKey('s1'), isTrue);
    uploads.uploadAll();
    await move;
    expect(strategies().containsKey('s1'), isFalse);
  });

  test('the editor holding it lets go, saved, before the move reads it',
      () async {
    await putStrategy('s1');
    final editor = _HeldStrategy('s1');
    open(editor: () => editor);

    await mover().moveStrategy('s1');

    expect(editor.saved, isTrue);
    expect(container.read(strategyProvider).strategyId, isNull);
    expect(strategies().containsKey('s1'), isFalse);
    expect(messages.single.$2, isFalse);
  });

  test('an editor that holds it again keeps the original here', () async {
    await putStrategy('s1');
    // A load that began before the move finishes after it started.
    final editor = _HeldStrategy('s1', letsGo: false);
    open(editor: () => editor);

    await mover().moveStrategy('s1');

    expect(cloud.strategies.values.single.unfinished, isFalse);
    expect(strategies().containsKey('s1'), isTrue);
    expect(messages.single.$1, contains('keeps the latest version too'));
  });

  test('an original that vanishes meanwhile leaves its cloud copy', () async {
    await putStrategy('s1');
    uploads.autoUpload = false;
    open();

    final move = mover().moveStrategy('s1');
    await untilUploading();
    // However it went, the cloud copy is now the only one.
    await strategies().delete('s1');
    uploads.uploadAll();
    await move;

    expect(cloud.strategies.values.single.unfinished, isFalse);
    expect(cloud.deletedStrategies, isEmpty);
    expect(moves().isEmpty, isTrue);
  });

  test("deleting a moving strategy is refused", () async {
    await putStrategy('s1');
    uploads.autoUpload = false;
    open();

    final move = mover().moveStrategy('s1');
    await untilUploading();
    final result = await container
        .read(strategyProvider.notifier)
        .deleteStrategy('s1', source: StrategySource.local);
    expect(result.didSucceed, isFalse);
    expect(strategies().containsKey('s1'), isTrue);
    uploads.uploadAll();
    await move;
    expect(strategies().containsKey('s1'), isFalse);
    expect(cloud.strategies.values.single.unfinished, isFalse);
  });

  test('the original stays until its pictures have landed', () async {
    await putStrategy('s1');
    uploads.autoUpload = false;
    open();

    final move = mover().moveStrategy('s1');
    await untilUploading();
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(strategies().containsKey('s1'), isTrue);
    expect(cloud.strategies.values.single.unfinished, isTrue);
    expect(container.read(movingToCloudProvider).contains('s1'), isTrue);

    uploads.uploadAll();
    await move;
    expect(strategies().containsKey('s1'), isFalse);
    expect(cloud.strategies.values.single.unfinished, isFalse);
  });

  test('a refused item deletes the cloud copy and keeps the original',
      () async {
    await putStrategy('s1');
    cloud.refuseBatchesOf = {'Strategy s1'};
    open();

    await mover().moveStrategy('s1');

    expect(cloud.strategies, isEmpty, reason: 'the half copy is deleted');
    expect(cloud.deletedStrategies, hasLength(1));
    expect(strategies().get('s1')!.pages, hasLength(2));
    expect(imageFile('s1', 's1-image').existsSync(), isTrue);
    expect(
      Directory(p.join(dir.path, cloud.deletedStrategies.single)).existsSync(),
      isFalse,
    );
    expect(moves().isEmpty, isTrue);
    expect(messages, [
      (
        "Couldn't move \"Strategy s1\" to the cloud. It's still on this "
            'device.',
        true,
      ),
    ]);
  });

  test("a picture under a name the app can't use keeps the original here",
      () async {
    await putStrategy('s1', imageExtension: '.txt');
    final picture = File(p.join(dir.path, 's1', 'images', 's1-image.txt'));
    await picture.writeAsBytes([4, 5, 6]);
    open();

    await mover().moveStrategy('s1');

    expect(strategies().get('s1')!.pages, hasLength(2));
    expect(await picture.readAsBytes(), [4, 5, 6]);
    expect(cloud.strategies, isEmpty);
    expect(moves().isEmpty, isTrue);
    expect(messages.single.$2, isTrue);
  });

  test('a cloud copy that reads back short is deleted, not finished', () async {
    await putStrategy('s1');
    cloud.loseOneItem = true;
    open();

    await mover().moveStrategy('s1');

    expect(cloud.strategies, isEmpty);
    expect(cloud.finished, isEmpty);
    expect(strategies().containsKey('s1'), isTrue);
    expect(messages.single.$2, isTrue);
    expect(offlineCopy.entryKeys, isEmpty);
  });

  test('an edit while it moves keeps the edited original here', () async {
    await putStrategy('s1');
    uploads.autoUpload = false;
    open();

    final move = mover().moveStrategy('s1');
    await untilUploading();
    // The editor saves it again, as autosave does.
    final edited = strategies().get('s1')!.copyWith(name: 'Strategy s1 v2');
    await strategies().put('s1', edited);
    uploads.uploadAll();
    await move;

    expect(cloud.strategies, isEmpty);
    expect(cloud.finished, isEmpty);
    expect(strategies().get('s1')!.name, 'Strategy s1 v2');
    expect(offlineCopy.entryKeys, isEmpty,
        reason: 'its checking read is not kept');
    expect(messages, [
      (
        '"Strategy s1" changed while it was moving, so it stays on this '
            'device. Move it again to put the latest version in the cloud.',
        true,
      ),
    ]);
  });

  test('a folder deleted while the move runs keeps the original here',
      () async {
    await putStrategy('s1');
    cloud.folders['plays'] = _CloudFolder('plays', 'Plays', null, null);
    uploads.autoUpload = false;
    open();

    final move = mover().moveStrategy('s1', cloudFolderId: 'plays');
    await untilUploading();
    // Another device deletes the folder; the server sends the unfinished
    // strategy in it to the top level.
    cloud.folders.remove('plays');
    final copy = cloud.strategies.values.single;
    cloud.strategies[copy.id] = _CloudStrategy(
      copy.id,
      copy.name,
      copy.mapData,
      null,
    )
      ..unfinished = true
      ..pages.addAll(copy.pages)
      ..elements.addAll(copy.elements)
      ..activePictures.addAll(copy.activePictures);
    uploads.uploadAll();
    await move;

    expect(cloud.finished, isEmpty);
    expect(cloud.strategies, isEmpty, reason: 'the copy is deleted');
    expect(strategies().containsKey('s1'), isTrue);
    expect(messages.single.$2, isTrue);
    expect(offlineCopy.entryKeys, isEmpty,
        reason: 'its checking read is not kept');
  });

  test('a move waiting while the account changes stays here', () async {
    await putStrategy('s1');
    await putStrategy('s2');
    uploads.autoUpload = false;
    open();

    final first = mover().moveStrategy('s1');
    final second = mover().moveStrategy('s2');
    await untilUploading();
    container.read(_account.notifier).state = 'account-2';
    uploads.uploadAll();
    await first;
    await second;

    expect(cloud.strategies, isEmpty);
    expect(cloud.created, hasLength(1), reason: 's2 never started');
    expect(strategies().keys.toSet(), {'s1', 's2'});
    expect(
      messages.last,
      (
        'You signed in to another account, so "Strategy s2" stays on this '
            'device.',
        true,
      ),
    );
  });

  test('cleanup deletes copies moves left unfinished, and only those',
      () async {
    cloud.strategies['half'] = _CloudStrategy('half', 'Half', 'bind', null)
      ..unfinished = true;
    cloud.strategies['done'] = _CloudStrategy('done', 'Done', 'bind', null);
    await moves().put('half', {'accountId': 'account-1', 'localId': 's1'});
    // The app stopped after finishing this one, before forgetting it.
    await moves().put('done', {'accountId': 'account-1', 'localId': 's2'});
    await moves().put('other', {'accountId': 'account-2', 'localId': 's3'});
    open();

    await mover().idle();

    expect(cloud.deletedStrategies, ['half']);
    expect(cloud.strategies.keys, ['done']);
    expect(moves().keys, ['other'], reason: "another account's waits");
  });

  test("a finished move whose last answer was lost still completes", () async {
    await putStrategy('s1');
    cloud.loseFinishAnswer = true;
    open();

    await mover().moveStrategy('s1');

    expect(cloud.strategies.values.single.unfinished, isFalse);
    expect(cloud.deletedStrategies, isEmpty);
    expect(strategies().containsKey('s1'), isFalse);
    expect(
      offlineCopy.keptStrategyIds(container.read(cloudCopyScopeProvider)!),
      cloud.strategies.keys.toSet(),
      reason: 'it did finish, so what was read is on the server',
    );
    expect(moves().isEmpty, isTrue);
    expect(messages, [('Moved "Strategy s1" to the cloud.', false)]);
  });

  test("a moving strategy can't be opened", () async {
    await putStrategy('s1');
    uploads.autoUpload = false;
    open();

    final move = mover().moveStrategy('s1');
    await untilUploading();
    await expectLater(
      container.read(strategyProvider.notifier).loadFromHive('s1'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('moving to the cloud'),
        ),
      ),
    );
    uploads.uploadAll();
    await move;
  });

  test('an empty folder whose cloud twin went meanwhile stays here', () async {
    await folders().put(
      'f1',
      Folder(
        id: 'f1',
        name: 'Bind',
        iconId: 0,
        color: FolderColor.red,
        dateCreated: DateTime.utc(2026),
      ),
    );
    await folders().put(
      'f2',
      Folder(
        id: 'f2',
        name: 'Empty',
        iconId: 0,
        color: FolderColor.generic,
        dateCreated: DateTime.utc(2026),
        parentID: 'f1',
      ),
    );
    await putStrategy('s1', folderID: 'f1');
    uploads.autoUpload = false;
    open();

    final move = mover().moveFolder('f1');
    await untilUploading();
    // Another device deletes the empty cloud folder.
    cloud.folders.removeWhere((_, folder) => folder.name == 'Empty');
    uploads.uploadAll();
    await move;

    expect(strategies().isEmpty, isTrue);
    expect(folders().keys.toSet(), {'f1', 'f2'});
    expect(messages, [
      (
        'Moved the strategies in "Bind" to the cloud, but some of its '
            'folders stayed on this device.',
        true,
      ),
    ]);
  });

  test('a folder moves with its subfolders; what fails stays here', () async {
    await folders().put(
      'f1',
      Folder(
        id: 'f1',
        name: 'Bind',
        iconId: 0,
        color: FolderColor.red,
        dateCreated: DateTime.utc(2026),
      ),
    );
    await folders().put(
      'f2',
      Folder(
        id: 'f2',
        name: 'Retakes',
        iconId: 0,
        color: FolderColor.generic,
        dateCreated: DateTime.utc(2026),
        parentID: 'f1',
      ),
    );
    await putStrategy('s1', folderID: 'f1');
    await putStrategy('s2', folderID: 'f2');
    cloud.refuseBatchesOf = {'Strategy s2'};
    open();

    await mover().moveFolder('f1');

    final bind = cloud.folders.values.singleWhere((f) => f.name == 'Bind');
    expect(bind.parentId, isNull);
    expect(bind.color, 'red');
    expect(cloud.strategies.values.single.folderId, bind.id);
    // Nothing moved into Retakes, so its cloud twin went.
    expect(cloud.folders.values.map((f) => f.name), ['Bind']);
    expect(strategies().keys, ['s2'], reason: 's2 failed and stays');
    expect(folders().keys.toSet(), {'f1', 'f2'}, reason: 'they still hold s2');
    expect(messages, [
      (
        'Moved 1 of 2 strategies in "Bind". The rest are still on this '
            'device.',
        true,
      ),
    ]);

    // Once everything moves, the local folders go.
    cloud.refuseBatchesOf = {};
    messages.clear();
    await mover().moveFolder('f1', cloudParentId: bind.id);
    expect(strategies().isEmpty, isTrue);
    expect(folders().isEmpty, isTrue);
    final retakes =
        cloud.folders.values.singleWhere((f) => f.name == 'Retakes');
    expect(
      cloud.strategies.values.map((s) => s.folderId),
      contains(retakes.id),
    );
    expect(messages, [('Moved "Bind" to the cloud.', false)]);
  });
}

class _CloudReadyAuth extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

class _ClosedStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: null,
        strategyName: null,
        source: StrategySource.local,
        isOpen: false,
      );
}

/// An editor that has a local strategy loaded, as after an export.
class _HeldStrategy extends StrategyProvider {
  _HeldStrategy(this.id, {this.letsGo = true});

  final String id;
  final bool letsGo;
  bool saved = false;

  @override
  StrategyState build() => StrategyState(
        strategyId: id,
        strategyName: 'Strategy $id',
        source: StrategySource.local,
        isOpen: true,
      );

  @override
  Future<void> forceSaveNow(String id) async => saved = true;

  @override
  Future<void> clearCurrentStrategy() async {
    if (!letsGo) return;
    state = const StrategyState(
      strategyId: null,
      strategyName: null,
      source: null,
      isOpen: false,
    );
  }
}

/// Holds queued pictures until the test lets them upload, or uploads them
/// at once.
class _HeldUploads extends CloudMediaUploadQueueNotifier {
  _HeldUploads(this.cloud);

  final _FakeCloud cloud;
  bool autoUpload = true;
  final held = <CloudMediaUploadJob>[];

  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);

  @override
  Future<void> enqueueMovedImages({
    required String strategyPublicId,
    required Iterable<({String assetPublicId, String fileExtension})> images,
  }) async {
    for (final image in images) {
      held.add(
        CloudMediaUploadJob(
          jobId: image.assetPublicId,
          accountId: 'account-1',
          strategyPublicId: strategyPublicId,
          assetPublicId: image.assetPublicId,
          fileExtension: image.fileExtension,
          mimeType: 'image/png',
          state: CloudMediaJobState.pendingUpload,
          attempts: 0,
          updatedAt: DateTime.utc(2026),
        ),
      );
    }
    state = CloudMediaUploadQueueState(jobs: [...held], isProcessing: false);
    if (autoUpload) uploadAll();
  }

  void uploadAll() {
    for (final job in held) {
      cloud.strategies[job.strategyPublicId]?.activePictures
          .add(job.assetPublicId);
    }
    held.clear();
    state = const CloudMediaUploadQueueState(jobs: [], isProcessing: false);
  }

  @override
  Future<void> clearJobsForStrategy(String strategyPublicId) async {}
}

class _CloudFolder {
  _CloudFolder(this.id, this.name, this.parentId, this.color);
  final String id;
  final String name;
  final String? parentId;
  final String? color;
}

class _CloudPage {
  _CloudPage(this.id, this.name, this.isAttack);
  final String id;
  final String name;
  final bool isAttack;
}

class _CloudElement {
  _CloudElement(this.id, this.pageId, this.kind, this.data);
  final String id;
  final String pageId;
  final String kind;
  final Map<String, dynamic> data;
}

class _CloudStrategy {
  _CloudStrategy(this.id, this.name, this.mapData, this.folderId);
  final String id;
  final String name;
  final String mapData;
  final String? folderId;
  final pages = <_CloudPage>[];
  final elements = <_CloudElement>[];
  final lineups = <String>[];
  final activePictures = <String>{};
  var revision = 1;
  var unfinished = false;
  var madeUnfinished = false;
  String? themeProfileId;
  Map<String, dynamic>? themePalette;
}

class _PickedFile extends FilePicker {
  _PickedFile(this.filePath);

  final String filePath;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    return FilePickerResult([
      PlatformFile(
        path: filePath,
        name: p.basename(filePath),
        size: File(filePath).lengthSync(),
      ),
    ]);
  }
}

/// The server, as far as moving uses it.
class _FakeCloud extends ConvexStrategyRepository {
  _FakeCloud() : super(IcarusConvexApi(_NoTransport()));

  final folders = <String, _CloudFolder>{};
  final strategies = <String, _CloudStrategy>{};
  final created = <String>[];
  final finished = <String>[];
  final deletedStrategies = <String>[];
  final fullReads = <String>[];
  Set<String> refuseBatchesOf = {};
  bool loseOneItem = false;
  bool loseFinishAnswer = false;
  bool loseFolderAnswer = false;
  bool refuseAbandon = false;
  Future<void> Function()? onFinish;

  @override
  Future<void> createFolder({
    required String publicId,
    required String name,
    String? parentFolderPublicId,
    int? iconId,
    int? iconCodePoint,
    String? iconFontFamily,
    String? iconFontPackage,
    String? color,
    int? customColorValue,
  }) async {
    folders[publicId] =
        _CloudFolder(publicId, name, parentFolderPublicId, color);
    if (loseFolderAnswer) throw StateError('connection lost');
  }

  @override
  Future<void> deleteFolder(
    String folderPublicId, {
    String? withinFolderPublicId,
  }) async {
    if (folders.values.any((f) => f.parentId == folderPublicId) ||
        strategies.values.any((s) => s.folderId == folderPublicId)) {
      throw StateError('Folder is not empty');
    }
    folders.remove(folderPublicId);
  }

  @override
  Future<void> createStrategyWithInitialPage({
    required String publicId,
    required String name,
    required String mapData,
    required String initialPagePublicId,
    required String initialPageName,
    bool? initialPageIsAutoNamed,
    required bool initialPageIsAttack,
    String? folderPublicId,
    String? themeProfileId,
    Map<String, dynamic>? themeOverridePalette,
    Map<String, dynamic>? initialPageSettings,
    bool unfinishedMove = false,
  }) async {
    created.add(publicId);
    strategies[publicId] =
        _CloudStrategy(publicId, name, mapData, folderPublicId)
          ..themeProfileId = themeProfileId
          ..themePalette = themeOverridePalette
          ..unfinished = unfinishedMove
          ..madeUnfinished = unfinishedMove
          ..pages.add(
            _CloudPage(
              initialPagePublicId,
              initialPageName,
              initialPageIsAttack,
            ),
          );
  }

  @override
  Future<void> finishMove(
    String strategyPublicId, {
    String? folderPublicId,
  }) async {
    final strategy = strategies[strategyPublicId]!;
    if (strategy.folderId != folderPublicId ||
        (folderPublicId != null && !folders.containsKey(folderPublicId))) {
      throw StateError('The strategy is no longer where the move put it');
    }
    strategies[strategyPublicId]!.unfinished = false;
    finished.add(strategyPublicId);
    await onFinish?.call();
    if (loseFinishAnswer) throw StateError('connection lost');
  }

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async =>
      RemoteStrategyShell(header: _header(strategyPublicId), pages: const []);

  RemoteStrategyHeader _header(String strategyPublicId) {
    final strategy = strategies[strategyPublicId];
    if (strategy == null) throw StateError('not found');
    return RemoteStrategyHeader(
      publicId: strategy.id,
      name: strategy.name,
      mapData: strategy.mapData,
      revision: strategy.revision,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
  }

  @override
  Future<RemoteFullStrategySnapshot> fetchFullSnapshot(
    String strategyPublicId, {
    String? shareToken,
    bool forOfflineCopy = false,
  }) async {
    fullReads.add(strategyPublicId);
    final strategy = strategies[strategyPublicId]!;
    final at = DateTime.utc(2026);
    final elements = [...strategy.elements];
    if (loseOneItem) elements.removeLast();
    return RemoteFullStrategySnapshot(
      header: _header(strategyPublicId),
      pages: [
        for (final (index, page) in strategy.pages.indexed)
          RemoteFullPage(
            page: RemotePage(
              publicId: page.id,
              strategyPublicId: strategy.id,
              name: page.name,
              sortIndex: index,
              isAttack: page.isAttack,
              revision: 1,
              createdAt: at,
              updatedAt: at,
            ),
            content: RemotePageContent(
              revision: 1,
              createdAt: at,
              updatedAt: at,
            ),
          ),
      ],
      elementsByPage: {
        for (final page in strategy.pages)
          page.id: [
            for (final element in elements)
              if (element.pageId == page.id)
                RemoteElement(
                  publicId: element.id,
                  strategyPublicId: strategy.id,
                  pagePublicId: page.id,
                  elementType: element.kind,
                  payload: const {},
                  sortIndex: 0,
                  revision: 1,
                  deleted: false,
                ),
          ],
      },
      lineupsByPage: const {},
      assetsById: {
        for (final picture in strategy.activePictures)
          picture: RemoteImageAsset(
            publicId: picture,
            fileExtension: '.png',
            width: null,
            height: null,
            url: 'https://example.test/$picture.png',
            legacyStoragePath: null,
          ),
      },
      // What the offline copy keeps of it: the strategy, its pages and its
      // pictures.
      serverAnswer: ConvexValue.fromDart({
        'header': {...headerRow(name: strategy.name), 'publicId': strategy.id},
        'pages': [
          for (final (index, page) in strategy.pages.indexed)
            {
              ...pageRow(page.id, sortIndex: index, name: page.name),
              'strategyPublicId': strategy.id,
              'settings': null,
              'contentRevision': 1,
              'contentCreatedAt': 1.0,
              'contentUpdatedAt': 1.0,
            },
        ],
        'elements': const <Object?>[],
        'lineups': const <Object?>[],
        'assets': [
          for (final picture in strategy.activePictures) assetRow(picture),
        ],
      }) as ConvexObject,
    );
  }

  @override
  Stream<List<CloudStrategyEntry>> watchStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) {
    if (folderPublicId != null && !folders.containsKey(folderPublicId)) {
      return Stream.error(
        ConvexFunctionException(
          code: ConvexErrorCode.notFound,
          rawCode: ConvexErrorCode.notFound.wireName,
          message: 'Folder not found',
        ),
      );
    }
    return Stream.value([
      for (final strategy in strategies.values)
        if (!strategy.unfinished && strategy.folderId == folderPublicId)
          (
            strategy: StrategyData(
              id: strategy.id,
              name: strategy.name,
              mapData: MapValue.bind,
              versionNumber: Settings.versionNumber,
              lastEdited: DateTime.utc(2026),
              folderID: folderPublicId,
              pages: const [],
            ),
            revision: strategy.revision,
            role: 'owner',
            attackLabel: 'Attack',
            agentTypes: const [],
          ),
    ]);
  }

  @override
  Future<AbandonedMove> abandonMove(
    String strategyPublicId,
  ) async {
    if (refuseAbandon) throw StateError('offline');
    final strategy = strategies[strategyPublicId];
    if (strategy == null) return AbandonedMove.missing;
    if (!strategy.unfinished) return AbandonedMove.finished;
    strategies.remove(strategyPublicId);
    deletedStrategies.add(strategyPublicId);
    return AbandonedMove.deleted;
  }

  @override
  Stream<List<CloudFolderEntry>> watchAllFolders() => Stream.value([
        for (final folder in folders.values)
          (
            folder: Folder(
              id: folder.id,
              name: folder.name,
              iconId: 0,
              color: FolderColor.generic,
              dateCreated: DateTime.utc(2026),
              parentID: folder.parentId,
            ),
            role: 'owner',
            strategyCount: 0,
            mapPeeks: const <MapValue>[],
            agentTypes: const [],
          ),
      ]);

  @override
  Future<void> addPage({
    required String strategyPublicId,
    required String pagePublicId,
    required String name,
    bool? isAutoNamed,
    required int sortIndex,
    required bool isAttack,
    required int expectedRevision,
    Map<String, dynamic>? settings,
  }) async {
    final strategy = strategies[strategyPublicId]!;
    if (expectedRevision != strategy.revision) {
      throw StateError('revision mismatch');
    }
    strategy.revision++;
    strategy.pages.insert(sortIndex, _CloudPage(pagePublicId, name, isAttack));
  }

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    final strategy = strategies[strategyPublicId]!;
    if (refuseBatchesOf.contains(strategy.name)) {
      return [
        for (final op in ops)
          RejectedOpAck(
            opId: op.opId,
            rejectionReason: OpRejectionReason.alreadyExists,
          ),
      ];
    }
    for (final op in ops) {
      if (op is ElementAddOp) {
        strategy.elements.add(
          _CloudElement(
            op.elementPublicId,
            op.pagePublicId,
            op.payload['kind'] as String,
            cloudPayloadData(op.payload),
          ),
        );
      } else if (op is LineupAddOp) {
        strategy.lineups.add(op.lineupPublicId);
      }
    }
    return [
      for (final op in ops) AppliedOpAck(opId: op.opId, revision: 1),
    ];
  }

  @override
  Future<void> deleteStrategy({
    required String strategyPublicId,
    required int expectedRevision,
    String? withinFolderPublicId,
  }) async {
    strategies.remove(strategyPublicId);
    deletedStrategies.add(strategyPublicId);
  }
}

class _NoTransport implements ConvexTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
