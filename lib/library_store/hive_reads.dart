import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_naming.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:path/path.dart' as path;

sealed class HiveRead<T> {
  const HiveRead();
}

final class InHive<T> extends HiveRead<T> {
  const InHive(this.value);

  final T value;
}

final class NotInHive<T> extends HiveRead<T> {
  const NotInHive();
}

final class HiveStillWriting<T> extends HiveRead<T> {
  const HiveStillWriting();
}

final class HiveSnapshot {
  HiveSnapshot({
    required this.library,
    required Set<String> strategiesWriting,
    required Set<String> foldersWriting,
  })  : strategiesWriting = Set.unmodifiable(strategiesWriting),
        foldersWriting = Set.unmodifiable(foldersWriting);

  final HiveLibrary library;
  final Set<String> strategiesWriting;
  final Set<String> foldersWriting;

  int get writes => strategiesWriting.length + foldersWriting.length;
}

abstract interface class LibraryBoxes {
  StrategyData? strategy(String id);

  Folder? folder(String id);

  Iterable<StrategyData> get strategies;

  Iterable<Folder> get folders;

  Iterable<HiveRecordName> get strategyNames;

  Iterable<HiveRecordName> get folderNames;
}

final class _HiveBoxes implements LibraryBoxes {
  const _HiveBoxes();

  @override
  StrategyData? strategy(String id) => const LocalLibrary().storedStrategy(id);

  @override
  Folder? folder(String id) => const LocalLibrary().storedFolder(id);

  @override
  Iterable<StrategyData> get strategies =>
      const LocalLibrary().storedStrategies;

  @override
  Iterable<Folder> get folders => const LocalLibrary().storedFolders;

  @override
  Iterable<HiveRecordName> get strategyNames =>
      const LocalLibrary().storedStrategyNames;

  @override
  Iterable<HiveRecordName> get folderNames =>
      const LocalLibrary().storedFolderNames;
}

List<Stream<Object?>> libraryBoxEvents() => const LocalLibrary().boxEvents();

Set<String> libraryBoxFileNames() => const LocalLibrary().boxFileNames();

Future<void> openHiveLibrary() => LocalLibrary.openHiveBoxes();

bool hiveLibraryOnDisk(String directory) =>
    [HiveBoxNames.strategiesBox, HiveBoxNames.foldersBox].any(
      (box) => File(path.join(directory, '$box.hive')).existsSync(),
    );

final class HiveReads {
  HiveReads() : _boxes = const _HiveBoxes();

  @visibleForTesting
  HiveReads.over(this._boxes);

  final LibraryBoxes _boxes;
  late final HiveNames names = HiveNames.of(
    strategies: _boxes.strategyNames,
    folders: _boxes.folderNames,
  );
  final _strategiesWriting = <String, int>{};
  final _foldersWriting = <String, int>{};
  final _strategyWritesBegun = <String, int>{};

  int strategyWritesBegun(String id) => _strategyWritesBegun[id] ?? 0;

  bool strategyWriting(String id) => _strategiesWriting.containsKey(id);

  bool folderWriting(String id) => _foldersWriting.containsKey(id);

  Iterable<String> get strategiesBeingWritten => _strategiesWriting.keys;

  Iterable<String> get foldersBeingWritten => _foldersWriting.keys;

  void writing(LibraryTouch touch) {
    for (final id in touch.strategies) {
      _strategiesWriting[id] = (_strategiesWriting[id] ?? 0) + 1;
      _strategyWritesBegun[id] = strategyWritesBegun(id) + 1;
    }
    for (final id in touch.folders) {
      _foldersWriting[id] = (_foldersWriting[id] ?? 0) + 1;
    }
  }

  void answered(LibraryTouch touch) {
    _settle(_strategiesWriting, touch.strategies);
    _settle(_foldersWriting, touch.folders);
  }

  static void _settle(Map<String, int> writing, List<String> ids) {
    for (final id in ids) {
      switch (writing[id]) {
        case null || 1:
          writing.remove(id);
        case final count:
          writing[id] = count - 1;
      }
    }
  }

  HiveRead<StrategyData> strategy(String id) => switch (id) {
        _ when !names.strategies.namesById(id) => const NotInHive(),
        _ when strategyWriting(id) => const HiveStillWriting(),
        _ => switch (_boxes.strategy(id)) {
            final strategy? => InHive(strategyAsHiveHoldsIt(strategy)),
            null => const NotInHive(),
          },
      };

  HiveRead<Folder> folder(String id) => switch (id) {
        _ when !names.folders.namesById(id) => const NotInHive(),
        _ when folderWriting(id) => const HiveStillWriting(),
        _ => switch (_boxes.folder(id)) {
            final folder? => InHive(folderAsHiveHoldsIt(folder)),
            null => const NotInHive(),
          },
      };

  HiveSnapshot library() => HiveSnapshot(
        library: HiveLibrary(
          strategies: [
            for (final strategy in _boxes.strategies)
              if (names.strategies.namesById(strategy.id) &&
                  !strategyWriting(strategy.id))
                strategy,
          ],
          folders: [
            for (final folder in _boxes.folders)
              if (names.folders.namesById(folder.id) &&
                  !folderWriting(folder.id))
                folder,
          ],
          names: names,
        ),
        strategiesWriting: _strategiesWriting.keys.toSet(),
        foldersWriting: _foldersWriting.keys.toSet(),
      );
}
