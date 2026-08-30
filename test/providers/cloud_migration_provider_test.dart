import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/cloud_migration_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

bool _adaptersRegistered = false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late ProviderContainer container;
  late FakeCloudMigrationApi api;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('icarus-cloud-migration-');
    Hive.init(tempDirectory.path);
    if (!_adaptersRegistered) {
      registerIcarusAdapters(Hive);
      _adaptersRegistered = true;
    }
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);

    api = FakeCloudMigrationApi();
    container = ProviderContainer(
      overrides: [
        isCloudCollabEnabledProvider.overrideWithValue(true),
        cloudMigrationApiProvider.overrideWithValue(api),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('failed remote write stays incomplete and retries in the same session',
      () async {
    await Hive.box<Folder>(HiveBoxNames.foldersBox).add(
      Folder(
        name: 'Retry me',
        id: 'folder-1',
        dateCreated: DateTime.utc(2026),
      ),
    );
    api.folderFailuresRemaining = 1;

    final notifier = container.read(cloudMigrationProvider.notifier);
    await notifier.maybeMigrate();

    expect(container.read(cloudMigrationProvider), isFalse);
    expect(api.createFolderCalls, 1);

    await notifier.maybeMigrate();

    expect(container.read(cloudMigrationProvider), isTrue);
    expect(api.createFolderCalls, 2);

    await notifier.maybeMigrate();
    expect(api.createFolderCalls, 2);
  });
}

class FakeCloudMigrationApi implements CloudMigrationApi {
  int folderFailuresRemaining = 0;
  int createFolderCalls = 0;

  @override
  Future<void> createFolder({
    required String publicId,
    required String name,
    String? parentFolderPublicId,
    int? iconId,
  }) async {
    createFolderCalls += 1;
    if (folderFailuresRemaining > 0) {
      folderFailuresRemaining -= 1;
      throw StateError('temporary cloud failure');
    }
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
    required Map<String, dynamic> initialPageSettings,
    String? folderPublicId,
    String? themeProfileId,
    Map<String, dynamic>? themeOverridePalette,
  }) async {}

  @override
  Future<void> addPage({
    required String strategyPublicId,
    required String pagePublicId,
    required String name,
    bool? isAutoNamed,
    required int sortIndex,
    required bool isAttack,
    required Map<String, dynamic> settings,
    required int expectedRevision,
  }) async {}

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    return [
      for (final op in ops) NoopOpAck(opId: op.opId),
    ];
  }
}
