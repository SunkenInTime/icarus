import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/hive_record.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:path/path.dart' as path;

Future<Directory> openScratchHive(
  Directory directory, {
  Iterable<StrategyData> strategies = const [],
  Iterable<Folder> folders = const [],
}) async {
  Hive.init(directory.path);
  if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
  final strategyBox =
      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  final folderBox = await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
  for (final strategy in strategies) {
    await strategyBox.put(strategy.id, strategy);
  }
  for (final folder in folders) {
    await folderBox.put(folder.id, folder);
  }
  return directory;
}

HiveLibrary hiveLibraryNow() => HiveLibrary(
      strategies: Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values,
      folders: Hive.box<Folder>(HiveBoxNames.foldersBox).values,
    );

Future<Map<String, String>> filesUnder(Directory directory) async => {
      for (final entity in directory.listSync(recursive: true))
        if (entity is File)
          path.relative(entity.path, from: directory.path):
              sha256.convert(await entity.readAsBytes()).toString(),
    };
