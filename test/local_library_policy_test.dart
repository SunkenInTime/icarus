import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';

/// Where the platform policy hides the on-device library, nothing may read
/// or rewrite it: its records wait, untouched, for local access to return.
void main() {
  late Directory tempDir;
  late Box<StrategyData> strategies;

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-local-policy-');
    Hive.init(tempDir.path);
    strategies = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    final old = _oldStrategy();
    await strategies.put(old.id, old);
    await strategies.flush();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  List<int> boxBytes() => File(
        '${tempDir.path}/${HiveBoxNames.strategiesBox.toLowerCase()}.hive',
      ).readAsBytesSync();

  group('startup migration', () {
    test('leaves hidden local strategies byte-identical on the web beta',
        () async {
      final before = boxBytes();

      await StrategyMigrator.migrateLocalLibrary(PlatformPolicy.webBeta);
      await strategies.flush();

      expect(boxBytes(), before);
      expect(strategies.get('old-plan')!.versionNumber, 20);
    });

    test('still migrates the local library on desktop', () async {
      final before = boxBytes();

      await StrategyMigrator.migrateLocalLibrary(PlatformPolicy.desktop);
      await strategies.flush();

      // The control: the same record does migrate where local is allowed,
      // so the web assertion above is not vacuous.
      expect(boxBytes(), isNot(before));
      expect(strategies.get('old-plan')!.versionNumber, greaterThan(20));
    });
  });

  group('strategy provider on the web beta', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          platformPolicyProvider.overrideWithValue(PlatformPolicy.webBeta),
        ],
      );
    });

    tearDown(() => container.dispose());

    test('refuses to open a local strategy and leaves it untouched', () async {
      final before = boxBytes();

      await expectLater(
        container.read(strategyProvider.notifier).loadFromHive('old-plan'),
        throwsStateError,
      );

      expect(container.read(strategyProvider).strategyId, isNull);
      await strategies.flush();
      expect(boxBytes(), before);
    });

    test('refuses to save a local strategy', () async {
      final before = boxBytes();

      await expectLater(
        container.read(strategyProvider.notifier).saveToHive('old-plan'),
        throwsStateError,
      );

      await strategies.flush();
      expect(boxBytes(), before);
    });
  });
}

StrategyData _oldStrategy() {
  return StrategyData(
    id: 'old-plan',
    name: 'Old Plan',
    mapData: MapValue.ascent,
    versionNumber: 20,
    lastEdited: DateTime.utc(2025, 1, 1),
    folderID: null,
    pages: [
      StrategyPage(
        id: 'page-1',
        sortIndex: 0,
        name: 'Page 1',
        drawingData: const [],
        agentData: const [],
        abilityData: const [],
        textData: const [],
        imageData: const [],
        utilityData: const [],
        isAttack: true,
        settings: StrategySettings(),
      ),
    ],
  );
}
