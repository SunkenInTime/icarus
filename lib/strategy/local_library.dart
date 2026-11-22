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

final class LibraryTouch {
  const LibraryTouch({required this.strategies, required this.folders});

  final List<String> strategies;
  final List<String> folders;
}

abstract base class LocalLibraryFollower {
  void onWriting(LibraryTouch touch);

  void onAnswered(LibraryTouch touch);

  void onFault(Object error, StackTrace stackTrace);

  void _told(void Function(LibraryTouch touch) notice, LibraryTouch touch) {
    try {
      notice(touch);
    } on Object catch (error, stackTrace) {
      onFault(error, stackTrace);
    }
  }
}

Iterable<String> _noIds() => const [];

final class LocalLibrary {
  const LocalLibrary();

  static LocalLibraryFollower? follower;

  static LocalLibraryFollower? get _following =>
      shadowReachable ? follower : null;

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

  Future<LibraryWrite> _put(StrategyData strategy) => switch (_following) {
        null => _write(() => _strategies.put(strategy.id, strategy)),
        final following => _followed(
            following,
            () => _strategies.put(strategy.id, strategy),
            strategies: () => [strategy.id],
          ),
      };

  Future<LibraryWrite> renameStrategy(StrategyData stored, String name) {
    stored.name = name;
    return switch (_following) {
      null => _write(stored.save),
      final following =>
        _followed(following, stored.save, strategies: () => [stored.id]),
    };
  }

  Future<LibraryWrite> moveStrategy(StrategyData stored, String? folderId) {
    stored.folderID = folderId;
    return switch (_following) {
      null => _write(stored.save),
      final following =>
        _followed(following, stored.save, strategies: () => [stored.id]),
    };
  }

  Future<LibraryWrite> deleteStrategy(String strategyId) =>
      switch (_following) {
        null => _write(() => _strategies.delete(strategyId)),
        final following => _followed(
            following,
            () => _strategies.delete(strategyId),
            strategies: () => [strategyId],
          ),
      };

  Future<LibraryWrite> addFolder(Folder folder) => switch (_following) {
        null => _write(() => _folders.put(folder.id, folder)),
        final following => _followed(
            following,
            () => _folders.put(folder.id, folder),
            folders: () => [folder.id],
          ),
      };

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
    return switch (_following) {
      null => _write(stored.save),
      final following =>
        _followed(following, stored.save, folders: () => [stored.id]),
    };
  }

  Future<LibraryWrite> moveFolder(Folder stored, String? parentId) {
    stored.parentID = parentId;
    return switch (_following) {
      null => _write(stored.save),
      final following =>
        _followed(following, stored.save, folders: () => [stored.id]),
    };
  }

  Future<LibraryWrite> deleteFolder(String folderId) => switch (_following) {
        null => _write(() => _folders.delete(folderId)),
        final following => _followed(
            following,
            () => _folders.delete(folderId),
            folders: () => [folderId],
          ),
      };

  Future<LibraryWrite> deleteFoldersWithStrategies({
    required Iterable<String> folderIds,
    required Iterable<String> strategyIds,
  }) =>
      switch (_following) {
        null => _write(
            () => Future.wait([
              _strategies.deleteAll(strategyIds),
              _folders.deleteAll(folderIds),
            ]),
          ),
        final following => _followed(
            following,
            () => Future.wait([
              _strategies.deleteAll(strategyIds),
              _folders.deleteAll(folderIds),
            ]),
            strategies: () => strategyIds,
            folders: () => folderIds,
          ),
      };

  Future<LibraryWrite> _write(Future<void> Function() write) async {
    try {
      await write();
    } on HiveError catch (error, stackTrace) {
      return LibraryWriteFailed(error, stackTrace);
    } on FileSystemException catch (error, stackTrace) {
      return LibraryWriteFailed(error, stackTrace);
    }
    return const LibraryWritten();
  }

  Future<LibraryWrite> _followed(
    LocalLibraryFollower following,
    Future<void> Function() write, {
    Iterable<String> Function() strategies = _noIds,
    Iterable<String> Function() folders = _noIds,
  }) async {
    var touch = const LibraryTouch(strategies: [], folders: []);
    try {
      touch = LibraryTouch(
        strategies: strategies().toList(),
        folders: folders().toList(),
      );
      following._told(following.onWriting, touch);
      await write();
    } on HiveError catch (error, stackTrace) {
      return LibraryWriteFailed(error, stackTrace);
    } on FileSystemException catch (error, stackTrace) {
      return LibraryWriteFailed(error, stackTrace);
    } finally {
      following._told(following.onAnswered, touch);
    }
    return const LibraryWritten();
  }
}
