import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/mirror_gate.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/library_store/strategy_image.dart';
import 'package:icarus_library/icarus_library.dart';
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

final class HiveWrites {
  HiveWrites._(this._directory, this._before) {
    _subscriptions = [
      for (final events in [
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).watch(),
        Hive.box<Folder>(HiveBoxNames.foldersBox).watch(),
      ])
        events.listen((event) => written.add(event.key)),
    ];
  }

  static Future<HiveWrites> watch(Directory directory) async =>
      HiveWrites._(directory, await hiveFiles(directory));

  final Directory _directory;
  final Map<String, String> _before;
  late final List<StreamSubscription<BoxEvent>> _subscriptions;
  final written = <Object?>[];

  Future<List<String>> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    final after = await hiveFiles(_directory);
    return [
      for (final key in written) 'a write to key $key',
      for (final name in {..._before.keys, ...after.keys})
        if (_before[name] != after[name]) 'a change to $name',
    ];
  }
}

Future<Map<String, String>> hiveFiles(Directory directory) async => {
      for (final file in directory.listSync().whereType<File>())
        if (path.extension(file.path) == '.hive')
          path.basename(file.path):
              '${file.lastModifiedSync().microsecondsSinceEpoch} '
                  '${sha256.convert(await file.readAsBytes())}',
    };

final _foreignNames = Expando<List<ForeignName>>('foreign names');

Future<LibraryStore> openStoreOn(StorageEngine engine) async =>
    switch (await LibraryStore.open(engine, canRead: appCanRead)) {
      StoreOpened(:final store, :final foreignNames) => () {
          _foreignNames[store] = foreignNames;
          return store;
        }(),
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };

Future<ShadowCopy> copyFromHive(
  LibraryStore store, {
  Future<void> Function() breathe = _still,
}) async {
  final writes = LibraryBoxWrites();
  try {
    return await copyHiveIntoStore(
      HiveReads(),
      GatedStore.open(store),
      images: StrategyImages(),
      writes: writes,
      breathe: breathe,
    );
  } finally {
    await writes.stop();
  }
}

Future<StoreCheck> checkFromHive(LibraryStore store) => checkStoreAgainstHive(
      hiveLibraryNow(),
      store,
      foreignNames: _foreignNames[store] ?? const [],
      breathe: _still,
    );

Future<void> _still() async {}
