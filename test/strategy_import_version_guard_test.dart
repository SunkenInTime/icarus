import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registrar.g.dart';
import 'package:icarus/providers/strategy_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version guard allows current and older versions', () {
    expect(
      () => StrategyProvider.throwIfImportedVersionIsTooNewForTest(
        Settings.versionNumber,
      ),
      returnsNormally,
    );
    expect(
      () => StrategyProvider.throwIfImportedVersionIsTooNewForTest(
        Settings.versionNumber - 1,
      ),
      returnsNormally,
    );
  });

  test('version guard throws on newer version', () {
    expect(
      () => StrategyProvider.throwIfImportedVersionIsTooNewForTest(
        Settings.versionNumber + 1,
      ),
      throwsA(isA<NewerVersionImportException>()),
    );
  });

  test('newer-version import is blocked before persistence', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('icarus-import-test-');
    Hive.init(tempDir.path);
    Hive.registerAdapters();
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
      container
          .read(strategyProvider.notifier)
          .loadFromFilePath(badVersionFile.path),
      throwsA(isA<NewerVersionImportException>()),
    );

    expect(box.isEmpty, isTrue);

    await Hive.close();
    await tempDir.delete(recursive: true);
  });
}
