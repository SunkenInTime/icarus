import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/strategy/strategy_models.dart';

sealed class LibraryWrite {
  const LibraryWrite();

  void orThrow() {
    switch (this) {
      case LibraryWritten():
        return;
      case LibraryWriteFailed(:final error, :final stackTrace):
        Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

final class LibraryWritten extends LibraryWrite {
  const LibraryWritten();
}

final class LibraryWriteFailed extends LibraryWrite {
  const LibraryWriteFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

abstract interface class LocalLibraryFollower {
  void saved({
    required Iterable<String> strategies,
    required Iterable<String> folders,
  });
}

final class LocalLibrary {
  const LocalLibrary();

  static LocalLibraryFollower? follower;

  Box<StrategyData> get _strategies =>
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

  Box<Folder> get _folders => Hive.box<Folder>(HiveBoxNames.foldersBox);

  Future<LibraryWrite> savePageOnScreen(StrategyData strategy) =>
      _put(strategy);

  Future<LibraryWrite> saveStrategyFields(StrategyData strategy) =>
      _put(strategy);

  Future<LibraryWrite> changePages(StrategyData strategy) => _put(strategy);

  Future<LibraryWrite> replaceAfterMigration(StrategyData strategy) =>
      _put(strategy);

  Future<LibraryWrite> addStrategy(StrategyData strategy) => _put(strategy);

  Future<LibraryWrite> _put(StrategyData strategy) => _write(
        () => _strategies.put(strategy.id, strategy),
        strategies: [strategy.id],
      );

  Future<LibraryWrite> renameStrategy(StrategyData stored, String name) {
    stored.name = name;
    return _write(stored.save, strategies: [stored.id]);
  }

  Future<LibraryWrite> moveStrategy(StrategyData stored, String? folderId) {
    stored.folderID = folderId;
    return _write(stored.save, strategies: [stored.id]);
  }

  Future<LibraryWrite> deleteStrategy(String strategyId) => _write(
        () => _strategies.delete(strategyId),
        strategies: [strategyId],
      );

  Future<LibraryWrite> addFolder(Folder folder) => _write(
        () => _folders.put(folder.id, folder),
        folders: [folder.id],
      );

  Future<LibraryWrite> restyleFolder(
    Folder stored, {
    required String name,
    required int iconId,
    required Color? customColor,
    required FolderColor color,
  }) {
    stored
      ..name = name
      ..iconId = iconId
      ..customColor = customColor
      ..color = color;
    return _write(stored.save, folders: [stored.id]);
  }

  Future<LibraryWrite> moveFolder(Folder stored, String? parentId) {
    stored.parentID = parentId;
    return _write(stored.save, folders: [stored.id]);
  }

  Future<LibraryWrite> deleteFolder(String folderId) => _write(
        () => _folders.delete(folderId),
        folders: [folderId],
      );

  Future<LibraryWrite> deleteFoldersWithStrategies({
    required Iterable<String> folderIds,
    required Iterable<String> strategyIds,
  }) {
    final strategies = strategyIds.toList();
    final folders = folderIds.toList();
    return _write(
      () => Future.wait([
        _strategies.deleteAll(strategies),
        _folders.deleteAll(folders),
      ]),
      strategies: strategies,
      folders: folders,
    );
  }

  Future<LibraryWrite> _write(
    Future<void> Function() write, {
    Iterable<String> strategies = const [],
    Iterable<String> folders = const [],
  }) async {
    try {
      await write();
    } on HiveError catch (error, stackTrace) {
      return LibraryWriteFailed(error, stackTrace);
    } on FileSystemException catch (error, stackTrace) {
      return LibraryWriteFailed(error, stackTrace);
    }
    if (shadowReachable) {
      follower?.saved(strategies: strategies, folders: folders);
    }
    return const LibraryWritten();
  }
}
