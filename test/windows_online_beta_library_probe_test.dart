import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final supportDirectory =
      Platform.environment['ICARUS_WINDOWS_SMOKE_SUPPORT_DIR'];
  final probePath = Platform.environment['ICARUS_WINDOWS_SMOKE_PROBE_PATH'];
  final expectedStrategyName =
      Platform.environment['ICARUS_WINDOWS_SMOKE_EXPECTED_STRATEGY_NAME'];
  final isWindowsSmoke = supportDirectory != null &&
      probePath != null &&
      expectedStrategyName != null;

  test(
    'reads the public-build library and writes a current semantic fingerprint',
    () async {
      Hive.init(supportDirectory!);
      registerIcarusAdapters(Hive);

      try {
        final box =
            await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
        final strategies = box.values.toList(growable: false)
          ..sort((left, right) => left.id.compareTo(right.id));

        expect(strategies, isNotEmpty);
        expect(
          strategies.any((strategy) => strategy.name == expectedStrategyName),
          isTrue,
          reason: 'The historical .ica fixture was not imported.',
        );

        final canonicalStrategies = <Map<String, Object?>>[];
        for (final storedStrategy in strategies) {
          expect(storedStrategy.pages, isNotEmpty);
          final currentStrategy =
              await StrategyMigrator.migrateLegacyData(storedStrategy);
          canonicalStrategies.add(<String, Object?>{
            'id': currentStrategy.id,
            'name': currentStrategy.name,
            'map': currentStrategy.mapData.name,
            'folderID': currentStrategy.folderID,
            'themeProfileId': currentStrategy.themeProfileId,
            'themeOverridePalette':
                currentStrategy.themeOverridePalette?.toJson(),
            'pages': currentStrategy.pages
                .map((page) => page.toJson(currentStrategy.id))
                .toList(growable: false),
          });
        }

        final outputFile = File(probePath!);
        await outputFile.parent.create(recursive: true);
        await outputFile.writeAsString(
          jsonEncode(<String, Object?>{
            'strategyCount': strategies.length,
            'strategyNames': strategies
                .map((strategy) => strategy.name)
                .toList(growable: false),
            'storedVersions': strategies
                .map((strategy) => strategy.versionNumber)
                .toList(growable: false),
            'canonicalCurrentState': jsonEncode(<String, Object?>{
              'strategies': canonicalStrategies,
            }),
          }),
          flush: true,
        );
      } finally {
        await Hive.close();
      }
    },
    skip: isWindowsSmoke
        ? false
        : 'Only runs inside the disposable Windows upgrade smoke.',
  );
}
