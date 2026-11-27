import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_naming.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/strategy/library_records.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

final class StoreRecords<T> implements LibraryRecords<T> {
  StoreRecords([Map<String, T> items = const {}])
      : _items = SplayTreeMap.of(items, compareHiveKeys);

  final SplayTreeMap<String, T> _items;
  final _changed = StreamController<String>.broadcast();

  void _put(String id, T value) {
    _items[id] = value;
    _changed.add(id);
  }

  void _remove(String id) {
    if (_items.remove(id) != null) _changed.add(id);
  }

  void Function() _putUndoably(String id, T value) {
    final before = _items[id];
    _put(id, value);
    return () => _undo(id, value, before);
  }

  void Function() _removeUndoably(String id) {
    final before = _items[id];
    _remove(id);
    return () => _undo(id, null, before);
  }

  void _undo(String id, T? now, T? before) {
    if (!identical(_items[id], now)) return;
    switch (before) {
      case final before?:
        _put(id, before);
      case null:
        _remove(id);
    }
  }

  @override
  T? get(String id) => _items[id];

  @override
  bool containsKey(String id) => _items.containsKey(id);

  @override
  Iterable<T> get values => _items.values;

  @override
  int get length => _items.length;

  @override
  bool get isNotEmpty => _items.isNotEmpty;

  @override
  Listenable listenable({List<String?>? keys}) =>
      _Changes(_changed.stream, keys?.toSet());

  @override
  Stream<String> changes() => _changed.stream;
}

final class _Changes implements Listenable {
  _Changes(this._changed, this._keys);

  final Stream<String> _changed;
  final Set<String?>? _keys;
  final _listening = <VoidCallback, StreamSubscription<String>>{};

  @override
  void addListener(VoidCallback listener) {
    _listening[listener]?.cancel();
    _listening[listener] = _changed.listen((id) {
      if (_keys == null || _keys.contains(id)) listener();
    });
  }

  @override
  void removeListener(VoidCallback listener) =>
      _listening.remove(listener)?.cancel();
}

final class StoreWriteFailed implements Exception {
  const StoreWriteFailed(this.words);

  final String words;

  @override
  String toString() => words;
}

sealed class StoreLibraryLoad {
  const StoreLibraryLoad();
}

final class StoreLibraryLoaded extends StoreLibraryLoad {
  const StoreLibraryLoaded(this.library);

  final StoreLibrary library;
}

final class StoreLibraryNotLoaded extends StoreLibraryLoad {
  const StoreLibraryNotLoaded(this.why);

  final String why;
}

final class StoreLibrary {
  StoreLibrary._(this._store, this.strategies, this.folders);

  static Future<StoreLibraryLoad> load(LibraryStore store) async {
    final LibraryList list;
    switch (store.library) {
      case LibraryOpen(list: final open):
        list = open;
      case LibraryShut(:final failure):
        return StoreLibraryNotLoaded('the store is shut: $failure');
    }
    final folders = <String, Folder>{};
    for (final row in list.folders) {
      switch (row) {
        case final ReadableFolder readable:
          switch (folderFromRow(readable)) {
            case FolderMade(:final folder):
              folders[folder.id] = folder;
            case FolderRefused(:final problems):
              return StoreLibraryNotLoaded(
                'the folder ${row.publicId} cannot be read: $problems',
              );
          }
        case UnreadableFolder():
          return StoreLibraryNotLoaded(
            'the folder ${row.publicId} cannot be read',
          );
      }
    }
    if (list.unreadableStrategies case [final first, ...]) {
      return StoreLibraryNotLoaded(
        'a strategy cannot be read: ${first.ref}',
      );
    }
    final strategies = <String, StrategyData>{};
    for (final summary in list.strategies) {
      if (summary.sync is! KeptHere) continue;
      final id = summary.publicId;
      final read = switch (await readStoredRows(store, id)) {
        StoredRowsRead(:final rows) => strategyOfRows(rows),
        StoredRowsNot(:final stored) => stored,
      };
      switch (read) {
        case StoredAsData(:final strategy):
          strategies[id] = strategy;
        case final other:
          return StoreLibraryNotLoaded('the strategy $id reads as $other');
      }
    }
    return StoreLibraryLoaded(StoreLibrary._(
      store,
      StoreRecords(strategies),
      StoreRecords(folders),
    ));
  }

  final LibraryStore _store;
  final StoreRecords<StrategyData> strategies;
  final StoreRecords<Folder> folders;

  Future<LibraryWrite> putStrategy(StrategyData strategy) async {
    final StrategyRowSet rows;
    switch (strategyToRows(strategy)) {
      case StrategyRowsRefused(:final problems):
        return _failed(
          'the strategy ${strategy.id} cannot be written: '
          '${problems.map(rowsProblemWords).join('; ')}',
        );
      case StrategyRowsMade(rows: final made):
        rows = made;
    }
    final undo = strategies._putUndoably(strategy.id, strategy);
    return _written(await _store.putStrategy(rows), undo);
  }

  Future<LibraryWrite> changeStrategy(
    StrategyData stored,
    void Function() change,
    void Function() undo,
  ) =>
      _changed(stored, stored.id, strategies, change, undo, putStrategy);

  Future<LibraryWrite> deleteStrategies(List<String> ids) async {
    final held = [
      for (final id in ids)
        if (strategies.containsKey(id)) id,
    ];
    if (held.isEmpty) return const LibraryWritten();
    final undo = [for (final id in held) strategies._removeUndoably(id)];
    return _written(
      await _store.editLibrary([for (final id in held) RemoveStrategy(id)]),
      () => undo.forEach(_run),
    );
  }

  Future<LibraryWrite> putFolder(Folder folder) async {
    final change = PutFolder(_folderRow(folder));
    final undo = folders._putUndoably(folder.id, folder);
    return _written(await _store.editLibrary([change]), undo);
  }

  Future<LibraryWrite> changeFolder(
    Folder stored,
    void Function() change,
    void Function() undo,
  ) =>
      _changed(stored, stored.id, folders, change, undo, putFolder);

  Future<LibraryWrite> deleteFoldersWithStrategies({
    required List<String> folderIds,
    required List<String> strategyIds,
  }) async {
    final heldStrategies = [
      for (final id in strategyIds)
        if (strategies.containsKey(id)) id,
    ];
    final heldFolders = [
      for (final row in folderRowsChildrenFirst([
        for (final id in folderIds)
          if (folders.get(id) case final folder?) folderToRow(folder),
      ]))
        row.publicId,
    ];
    if (heldStrategies.isEmpty && heldFolders.isEmpty) {
      return const LibraryWritten();
    }
    final undo = [
      for (final id in heldStrategies) strategies._removeUndoably(id),
      for (final id in heldFolders) folders._removeUndoably(id),
    ];
    return _written(
      await _store.editLibrary([
        for (final id in heldStrategies) RemoveStrategy(id),
        for (final id in heldFolders) RemoveFolder(id),
      ]),
      () => undo.forEach(_run),
    );
  }

  ReadableFolder _folderRow(Folder folder) {
    final row = folderToRow(folder);
    return switch (_store.folderOf(folder.id)) {
      ReadableFolder(:final unknownFields) when unknownFields.isNotEmpty =>
        ReadableFolder(
          publicId: row.publicId,
          name: row.name,
          parentFolderPublicId: row.parentFolderPublicId,
          iconId: row.iconId,
          color: row.color,
          customColorValue: row.customColorValue,
          createdAt: row.createdAt,
          unknownFields: unknownFields,
        ),
      _ => row,
    };
  }
}

LibraryWrite _failed(String words) =>
    LibraryWriteFailed(StoreWriteFailed(words), StackTrace.current);

void _run(void Function() action) => action();

Future<LibraryWrite> _changed<T extends Object>(
  T stored,
  String id,
  StoreRecords<T> records,
  void Function() change,
  void Function() undo,
  Future<LibraryWrite> Function(T stored) put,
) async {
  change();
  final written = await put(stored);
  if (written is LibraryWriteFailed && identical(records.get(id), stored)) {
    undo();
    records._put(id, stored);
  }
  return written;
}

LibraryWrite _written(LibraryEditResult result, void Function() undo) {
  switch (result) {
    case Saved() || NothingToSave():
      return const LibraryWritten();
    case Refused(:final reason):
      undo();
      return _failed('the library refused the change: $reason');
    case NotSaved(:final failure):
      undo();
      return _failed('the change was not saved: $failure');
    case SaveInDoubt(:final failure):
      undo();
      return _failed('the change may not have been saved: $failure');
  }
}
