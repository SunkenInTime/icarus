import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';

StrategyData _strategy(String id) => StrategyData(
      id: id,
      name: id,
      mapData: MapValue.ascent,
      versionNumber: 1,
      lastEdited: DateTime.utc(2026),
      folderID: null,
      pages: const [],
    );

void main() {
  test(
    'a library file another program holds locked fails the write as a value',
    skip: Platform.isWindows ? false : 'only Windows refuses a locked write',
    () async {
      final dir = await Directory.systemTemp.createTemp('icarus-locked-');
      addTearDown(() => dir.delete(recursive: true));
      Hive.init(dir.path);
      registerIcarusAdapters(Hive);
      final strategies =
          await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
      await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
      addTearDown(Hive.close);
      await strategies.put('before', _strategy('before'));
      final scanner = await File(
        '${dir.path}/${HiveBoxNames.strategiesBox}.hive',
      ).open(mode: FileMode.append);
      await scanner.lock(FileLock.exclusive, 0, 1 << 30);
      addTearDown(() async {
        await scanner.unlock(0, 1 << 30);
        await scanner.close();
      });

      final written = await const LocalLibrary().addStrategy(_strategy('new'));

      expect(
        written,
        isA<LibraryWriteFailed>().having(
          (failed) => failed.error,
          'error',
          isA<FileSystemException>(),
        ),
      );
      expect(written.orThrow, throwsA(isA<FileSystemException>()));
    },
  );

  test('a page save after the library box has closed fails as a value',
      () async {
    final dir = await Directory.systemTemp.createTemp('icarus-closed-');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    final strategies =
        await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    addTearDown(Hive.close);
    await strategies.put('open', _strategy('open'));
    final stored = const LocalLibrary().storedStrategy('open')!.copyWith();
    await strategies.close();

    final written = await const LocalLibrary().savePageOnScreen(stored);

    expect(written, isA<LibraryWriteFailed>());
  });
}
