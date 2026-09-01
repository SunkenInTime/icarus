import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/migrations/canonical_coordinates_migration.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/cloud_migration_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
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

  test('migrates legacy defense coordinates before the first cloud upload',
      () async {
    const legacyPosition = Offset(1400, 700);
    const virtualToWorld = 1000 / 831;
    final agentAnchorWorld = const Offset(
          Settings.agentSize / 2,
          Settings.agentSize / 2,
        ) *
        virtualToWorld;
    final expectedCanonicalPosition = Offset(
      1000 * (16 / 9) - legacyPosition.dx - (agentAnchorWorld.dx * 2),
      1000 - legacyPosition.dy - (agentAnchorWorld.dy * 2),
    );
    final legacyStrategy = StrategyData(
      id: 'legacy-defense-strategy',
      name: 'Legacy defense strategy',
      mapData: MapValue.ascent,
      versionNumber: CanonicalCoordinatesMigration.version - 1,
      lastEdited: DateTime.utc(2026),
      folderID: null,
      pages: [
        StrategyPage(
          id: 'defense-page',
          name: 'Defense',
          drawingData: const [],
          agentData: [
            PlacedAgent(
              id: 'agent-1',
              type: AgentType.jett,
              position: legacyPosition,
            ),
          ],
          abilityData: const [],
          textData: const [],
          imageData: const [],
          utilityData: const [],
          sortIndex: 0,
          isAttack: false,
          settings: StrategySettings(),
        ),
      ],
    );
    final strategiesBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    await strategiesBox.put(legacyStrategy.id, legacyStrategy);

    await container.read(cloudMigrationProvider.notifier).maybeMigrate();

    expect(container.read(cloudMigrationProvider), isTrue);
    final storedStrategy = strategiesBox.get(legacyStrategy.id)!;
    expect(storedStrategy.versionNumber, Settings.versionNumber);
    expect(
      storedStrategy.pages.single.agentData.single.position,
      expectedCanonicalPosition,
    );

    final uploadedOp = api.appliedBatches.single.single as ElementAddOp;
    final uploadedAgent = PlacedAgent.fromJson(
      cloudPayloadData(uploadedOp.payload),
    );
    expect(uploadedAgent.position, expectedCanonicalPosition);
  });
}

class FakeCloudMigrationApi implements CloudMigrationApi {
  int folderFailuresRemaining = 0;
  int createFolderCalls = 0;
  final List<List<StrategyOp>> appliedBatches = [];

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
    appliedBatches.add(List<StrategyOp>.from(ops));
    return [
      for (final op in ops) NoopOpAck(opId: op.opId),
    ];
  }
}
