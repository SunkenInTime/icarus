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
  const LibraryTouch({
    required this.strategies,
    required this.folders,
    this.wrote,
  });

  final List<String> strategies;
  final List<String> folders;
  final StrategyData? wrote;
}

abstract base class LocalLibraryFollower {
  void onWriting(LibraryTouch touch);

  void onAnswered(LibraryTouch touch);

  void onWriteFailed(LibraryTouch touch) {}

  void onFault(Object error, StackTrace stackTrace);

  void _told(void Function(LibraryTouch touch) notice, LibraryTouch touch) {
    try {
      notice(touch);
    } on Object catch (error, stackTrace) {
      _faulted(error, stackTrace);
    }
  }

  void _faulted(Object error, StackTrace stackTrace) {
    try {
      onFault(error, stackTrace);
    } on Object {
      if (identical(LocalLibrary.follower, this)) LocalLibrary.follower = null;
    }
  }

  Future<void> _tracked(LibraryTouch touch, Future<void> Function() write) {
    _told(onWriting, touch);
    final Future<void> writing;
    try {
      writing = write();
    } on Object {
      _told(onWriteFailed, touch);
      _told(onAnswered, touch);
      rethrow;
    }
    writing.then(
      (_) => _told(onAnswered, touch),
      onError: (Object _) {
        _told(onWriteFailed, touch);
        _told(onAnswered, touch);
      },
    );
    return writing;
  }
}

final class LocalLibrary {
  const LocalLibrary();

  static LocalLibraryFollower? follower;

  static LocalLibraryFollower? get _following =>
      shadowReachable ? follower : null;

  Box<StrategyData> get _strategies =>
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

  Box<Folder> get _folders => Hive.box<Folder>(HiveBoxNames.foldersBox);

  static bool get isOpen => Hive.isBoxOpen(HiveBoxNames.strategiesBox);

  StrategyData? storedStrategy(String id) => _strategies.get(id);

  StrategyData? firstStoredWithId(String id) =>
      _strategies.values.where((strategy) => strategy.id == id).firstOrNull;

  bool holdsStrategy(String id) => _strategies.containsKey(id);

  Iterable<StrategyData> get storedStrategies => _strategies.values;

  Folder? storedFolder(String id) => _folders.get(id);

  Iterable<Folder> get storedFolders => _folders.values;

  Iterable<({Object key, String id})> get storedStrategyNames => [
        for (final key in _strategies.keys)
          if (_strategies.get(key) case final strategy?)
            (key: key as Object, id: strategy.id),
      ];

  Iterable<({Object key, String id})> get storedFolderNames => [
        for (final key in _folders.keys)
          if (_folders.get(key) case final folder?)
            (key: key as Object, id: folder.id),
      ];

  List<Stream<Object?>> boxEvents() => [_strategies.watch(), _folders.watch()];

  Set<String> boxFileNames() =>
      {'${_strategies.name}.hive', '${_folders.name}.hive'};

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
        final following => _write(
            () => following._tracked(
              LibraryTouch(
                strategies: [strategy.id],
                folders: const [],
                wrote: strategy,
              ),
              () => _strategies.put(strategy.id, strategy),
            ),
          ),
      };

  Future<LibraryWrite> renameStrategy(StrategyData stored, String name) {
    stored.name = name;
    return switch (_following) {
      null => _write(stored.save),
      final following => _write(
          () => following._tracked(
            LibraryTouch(
              strategies: [stored.id],
              folders: const [],
              wrote: stored,
            ),
            stored.save,
          ),
        ),
    };
  }

  Future<LibraryWrite> moveStrategy(StrategyData stored, String? folderId) {
    stored.folderID = folderId;
    return switch (_following) {
      null => _write(stored.save),
      final following => _write(
          () => following._tracked(
            LibraryTouch(
              strategies: [stored.id],
              folders: const [],
              wrote: stored,
            ),
            stored.save,
          ),
        ),
    };
  }

  Future<LibraryWrite> deleteStrategy(String strategyId) =>
      switch (_following) {
        null => _write(() => _strategies.delete(strategyId)),
        final following => _write(
            () => following._tracked(
              LibraryTouch(strategies: [strategyId], folders: const []),
              () => _strategies.delete(strategyId),
            ),
          ),
      };

  Future<LibraryWrite> addFolder(Folder folder) => switch (_following) {
        null => _write(() => _folders.put(folder.id, folder)),
        final following => _write(
            () => following._tracked(
              LibraryTouch(strategies: const [], folders: [folder.id]),
              () => _folders.put(folder.id, folder),
            ),
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
      final following => _write(
          () => following._tracked(
            LibraryTouch(strategies: const [], folders: [stored.id]),
            stored.save,
          ),
        ),
    };
  }

  Future<LibraryWrite> moveFolder(Folder stored, String? parentId) {
    stored.parentID = parentId;
    return switch (_following) {
      null => _write(stored.save),
      final following => _write(
          () => following._tracked(
            LibraryTouch(strategies: const [], folders: [stored.id]),
            stored.save,
          ),
        ),
    };
  }

  Future<LibraryWrite> deleteFolder(String folderId) => switch (_following) {
        null => _write(() => _folders.delete(folderId)),
        final following => _write(
            () => following._tracked(
              LibraryTouch(strategies: const [], folders: [folderId]),
              () => _folders.delete(folderId),
            ),
          ),
      };

  Future<LibraryWrite> deleteFoldersWithStrategies({
    required List<String> folderIds,
    required List<String> strategyIds,
  }) =>
      switch (_following) {
        null => _write(
            () => Future.wait([
              _strategies.deleteAll(strategyIds),
              _folders.deleteAll(folderIds),
            ]),
          ),
        final following => _write(
            () => Future.wait([
              following._tracked(
                LibraryTouch(strategies: strategyIds, folders: const []),
                () => _strategies.deleteAll(strategyIds),
              ),
              following._tracked(
                LibraryTouch(strategies: const [], folders: folderIds),
                () => _folders.deleteAll(folderIds),
              ),
            ]),
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
}
