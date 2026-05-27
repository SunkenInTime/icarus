import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version guard allows current and older versions', () {
    expect(
      () => StrategyImportExportService.throwIfImportedVersionIsTooNewForTest(
        Settings.versionNumber,
      ),
      returnsNormally,
    );
    expect(
      () => StrategyImportExportService.throwIfImportedVersionIsTooNewForTest(
        Settings.versionNumber - 1,
      ),
      returnsNormally,
    );
  });

  test('version guard throws on newer version', () {
    expect(
      () => StrategyImportExportService.throwIfImportedVersionIsTooNewForTest(
        Settings.versionNumber + 1,
      ),
      throwsA(isA<NewerVersionImportException>()),
    );
  });

  test('newer-version import is blocked before persistence', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('icarus-import-test-');
    Hive.init(tempDir.path);
    registerIcarusAdapters(Hive);
    final box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);

    final badVersionFile = File('${tempDir.path}/newer.ica');
    await badVersionFile.writeAsString(
      jsonEncode({
        'versionNumber': Settings.versionNumber + 1,
      }),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await expectLater(
      StrategyImportExportService(container).loadFromFilePath(badVersionFile.path),
      throwsA(isA<NewerVersionImportException>()),
    );

    expect(box.isEmpty, isTrue);

    await Hive.close();
    await tempDir.delete(recursive: true);
  });
}
