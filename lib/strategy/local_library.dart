import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/store_library.dart';
import 'package:icarus/strategy/library_records.dart';
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
  const LibraryWriteFailed(
    this.error,
    this.stackTrace, {
    this.mayHaveLanded = false,
  });

  final Object error;
  final StackTrace stackTrace;
  final bool mayHaveLanded;
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

sealed class LocalLibrarySource {
  const LocalLibrarySource();
}

final class LibraryInHive extends LocalLibrarySource {
  const LibraryInHive();
}

final class LibraryInStore extends LocalLibrarySource {
  const LibraryInStore(this.library);

  final StoreLibrary library;
}

final class LibraryNotOpened extends LocalLibrarySource {
  const LibraryNotOpened();
}

final class LibraryNotOpenedWrite implements Exception {
  const LibraryNotOpenedWrite();

  @override
  String toString() => 'the library could not be opened, so nothing was saved';
}

final class LibraryNotOpenedExport implements Exception {
  const LibraryNotOpenedExport();

  @override
  String toString() =>
      'the library could not be opened, so nothing was exported';
}

final _nothingHeld = StoreRecords<Never>();

final class LocalLibrary {
  const LocalLibrary();

  static LocalLibraryFollower? follower;

  static LocalLibrarySource source = const LibraryInHive();

  static LocalLibraryFollower? get _following =>
      shadowReachable ? follower : null;

  Box<StrategyData> get _strategyBox =>
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

  Box<Folder> get _folderBox => Hive.box<Folder>(HiveBoxNames.foldersBox);

  LibraryRecords<StrategyData> get strategyRecords => switch (source) {
        LibraryInHive() => HiveRecords(_strategyBox),
        LibraryInStore(:final library) => library.strategies,
        LibraryNotOpened() => _nothingHeld,
      };

  LibraryRecords<Folder> get folderRecords => switch (source) {
        LibraryInHive() => HiveRecords(_folderBox),
        LibraryInStore(:final library) => library.folders,
        LibraryNotOpened() => _nothingHeld,
      };

  static bool get isOpen => switch (source) {
        LibraryInHive() => Hive.isBoxOpen(HiveBoxNames.strategiesBox),
        LibraryInStore() => true,
        LibraryNotOpened() => false,
      };

  StrategyData? storedStrategy(String id) => strategyRecords.get(id);

  StrategyData? firstStoredWithId(String id) =>
      strategyRecords.values.where((strategy) => strategy.id == id).firstOrNull;

  bool holdsStrategy(String id) => strategyRecords.containsKey(id);

  Iterable<StrategyData> get storedStrategies => strategyRecords.values;

  Folder? storedFolder(String id) => folderRecords.get(id);

  bool holdsFolder(String id) => folderRecords.containsKey(id);

  Iterable<Folder> get storedFolders => folderRecords.values;

  Iterable<({Object key, StrategyData strategy})> get hiveStrategyRecords => [
        for (final key in _strategyBox.keys)
          if (_strategyBox.get(key) case final strategy?)
            (key: key as Object, strategy: strategy),
      ];

  Iterable<({Object key, Folder folder})> get hiveFolderRecords => [
        for (final key in _folderBox.keys)
          if (_folderBox.get(key) case final folder?)
            (key: key as Object, folder: folder),
      ];

  Iterable<({Object key, String id})> get storedStrategyNames => [
        for (final key in _strategyBox.keys)
          if (_strategyBox.get(key) case final strategy?)
            (key: key as Object, id: strategy.id),
      ];

  Iterable<({Object key, String id})> get storedFolderNames => [
        for (final key in _folderBox.keys)
          if (_folderBox.get(key) case final folder?)
            (key: key as Object, id: folder.id),
      ];

  List<Stream<String>> boxEvents() =>
      [strategyRecords.changes(), folderRecords.changes()];

  Set<String> boxFileNames() =>
      {'${_strategyBox.name}.hive', '${_folderBox.name}.hive'};

  Future<LibraryWrite> savePageOnScreen(StrategyData strategy) =>
      _put(strategy);

  Future<LibraryWrite> saveStrategyFields(StrategyData strategy) =>
      _put(strategy);

  Future<LibraryWrite> changePages(StrategyData strategy) => _put(strategy);

  Future<LibraryWrite> replaceAfterMigration(StrategyData strategy) =>
      _put(strategy);

  Future<LibraryWrite> addStrategy(StrategyData strategy) => _put(strategy);

  Future<LibraryWrite> _put(StrategyData strategy) => switch (source) {
        LibraryInStore(:final library) => library.putStrategy(strategy),
        LibraryNotOpened() => _notOpened(),
        LibraryInHive() => switch (_following) {
            null => _write(() => _strategyBox.put(strategy.id, strategy)),
            final following => _write(
                () => following._tracked(
                  LibraryTouch(
                    strategies: [strategy.id],
                    folders: const [],
                    wrote: strategy,
                  ),
                  () => _strategyBox.put(strategy.id, strategy),
                ),
              ),
          },
      };

  Future<LibraryWrite> renameStrategy(StrategyData stored, String name) =>
      switch (source) {
        LibraryInStore(:final library) => library.renameStrategy(stored, name),
        LibraryNotOpened() => _notOpened(),
        LibraryInHive() => _saveInHive(
            stored,
            () => stored.name = name,
          ),
      };

  Future<LibraryWrite> moveStrategy(StrategyData stored, String? folderId) =>
      switch (source) {
        LibraryInStore(:final library) =>
          library.moveStrategy(stored, folderId),
        LibraryNotOpened() => _notOpened(),
        LibraryInHive() => _saveInHive(
            stored,
            () => stored.folderID = folderId,
          ),
      };

  Future<LibraryWrite> _saveInHive(
    StrategyData stored,
    void Function() change,
  ) {
    change();
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

  Future<LibraryWrite> deleteStrategy(String strategyId) => switch (source) {
        LibraryInStore(:final library) => library.deleteStrategy(strategyId),
        LibraryNotOpened() => _notOpened(),
        LibraryInHive() => switch (_following) {
            null => _write(() => _strategyBox.delete(strategyId)),
            final following => _write(
                () => following._tracked(
                  LibraryTouch(strategies: [strategyId], folders: const []),
                  () => _strategyBox.delete(strategyId),
                ),
              ),
          },
      };

  Future<LibraryWrite> addFolder(Folder folder) => switch (source) {
        LibraryInStore(:final library) => library.putFolder(folder),
        LibraryNotOpened() => _notOpened(),
        LibraryInHive() => switch (_following) {
            null => _write(() => _folderBox.put(folder.id, folder)),
            final following => _write(
                () => following._tracked(
                  LibraryTouch(strategies: const [], folders: [folder.id]),
                  () => _folderBox.put(folder.id, folder),
                ),
              ),
          },
      };

  Future<LibraryWrite> restyleFolder(
    Folder stored, {
    required String name,
    required int iconId,
    required Color? customColor,
    required FolderColor color,
  }) {
    void change() => stored
      ..name = name
      ..iconId = iconId
      ..customColor = customColor
      ..color = color;
    return switch (source) {
      LibraryInStore(:final library) => library.restyleFolder(stored, change),
      LibraryNotOpened() => _notOpened(),
      LibraryInHive() => _saveFolderInHive(stored, change),
    };
  }

  Future<LibraryWrite> moveFolder(Folder stored, String? parentId) =>
      switch (source) {
        LibraryInStore(:final library) => library.moveFolder(stored, parentId),
        LibraryNotOpened() => _notOpened(),
        LibraryInHive() =>
          _saveFolderInHive(stored, () => stored.parentID = parentId),
      };

  Future<LibraryWrite> _saveFolderInHive(
    Folder stored,
    void Function() change,
  ) {
    change();
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

  Future<LibraryWrite> deleteFolder(String folderId) => switch (source) {
        LibraryInStore(:final library) => library.deleteFoldersWithStrategies(
            folderIds: [folderId],
            strategyIds: const [],
          ),
        LibraryNotOpened() => _notOpened(),
        LibraryInHive() => switch (_following) {
            null => _write(() => _folderBox.delete(folderId)),
            final following => _write(
                () => following._tracked(
                  LibraryTouch(strategies: const [], folders: [folderId]),
                  () => _folderBox.delete(folderId),
                ),
              ),
          },
      };

  Future<LibraryWrite> deleteFoldersWithStrategies({
    required List<String> folderIds,
    required List<String> strategyIds,
  }) =>
      switch (source) {
        LibraryInStore(:final library) => library.deleteFoldersWithStrategies(
            folderIds: folderIds,
            strategyIds: strategyIds,
          ),
        LibraryNotOpened() => _notOpened(),
        LibraryInHive() => switch (_following) {
            null => _write(
                () => Future.wait([
                  _strategyBox.deleteAll(strategyIds),
                  _folderBox.deleteAll(folderIds),
                ]),
              ),
            final following => _write(
                () => Future.wait([
                  following._tracked(
                    LibraryTouch(strategies: strategyIds, folders: const []),
                    () => _strategyBox.deleteAll(strategyIds),
                  ),
                  following._tracked(
                    LibraryTouch(strategies: const [], folders: folderIds),
                    () => _folderBox.deleteAll(folderIds),
                  ),
                ]),
              ),
          },
      };

  Future<LibraryWrite> _notOpened() async =>
      LibraryWriteFailed(const LibraryNotOpenedWrite(), StackTrace.current);

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
