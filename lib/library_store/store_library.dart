import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_naming.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/services/app_error_reporter.dart';
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

  void _replaceAll(Map<String, T> items) {
    final touched = {..._items.keys, ...items.keys};
    _items
      ..clear()
      ..addAll(items);
    touched.forEach(_changed.add);
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

typedef _Held = ({
  Map<String, StrategyData> strategies,
  Map<String, Folder> folders,
  Map<String, Map<String, int>> numbers,
});

Map<String, int> _numbersOf(StrategyRowSet rows) => {
      for (final element in rows.elements)
        if (element case ReadableElementRow(:final publicId, :final sortIndex))
          publicId: sortIndex,
    };

sealed class _Read {
  const _Read();
}

final class _ReadWhole extends _Read {
  const _ReadWhole(this.held);

  final _Held held;
}

final class _ReadNot extends _Read {
  const _ReadNot(this.why);

  final String why;
}

Future<_Read> _readLibrary(LibraryStore store) async {
  final LibraryList list;
  switch (store.library) {
    case LibraryOpen(list: final open):
      list = open;
    case LibraryShut(:final failure):
      return _ReadNot('the store is shut: $failure');
  }
  if (list.unplaced case [final first, ...]) {
    return _ReadNot('a row could not be placed: ${first.ref}');
  }
  final folders = <String, Folder>{};
  for (final row in list.folders) {
    switch (row) {
      case final ReadableFolder readable:
        switch (folderFromRow(readable)) {
          case FolderMade(:final folder):
            folders[folder.id] = folder;
          case FolderRefused(:final problems):
            return _ReadNot(
              'the folder ${row.publicId} cannot be read: $problems',
            );
        }
      case UnreadableFolder():
        return _ReadNot('the folder ${row.publicId} cannot be read');
    }
  }
  if (list.unreadableStrategies case [final first, ...]) {
    return _ReadNot('a strategy cannot be read: ${first.ref}');
  }
  final kept = [
    for (final summary in list.strategies)
      if (summary.sync is KeptHere) summary,
  ];
  return store.readingAhead(
    [for (final summary in kept) summary.publicId],
    () => _readKept(store, kept, folders),
  );
}

Future<_Read> _readKept(
  LibraryStore store,
  List<StrategySummary> kept,
  Map<String, Folder> folders,
) async {
  final strategies = <String, StrategyData>{};
  final numbers = <String, Map<String, int>>{};
  for (final summary in kept) {
    final id = summary.publicId;
    final StoredStrategy read;
    switch (await readStoredRows(store, id)) {
      case StoredRowsRead(:final rows, written: WrittenAt(:final version))
          when version <= Settings.versionNumber:
        read = strategyOfRows(rows, versionNumber: version);
        numbers[id] = _numbersOf(rows);
      case StoredRowsRead(written: WrittenAt(:final version)):
        return _ReadNot(
          'the strategy "${summary.name}" ($id) was written by a newer '
          'version of Icarus ($version)',
        );
      case StoredRowsRead(written: WrittenNotRecorded()):
        return _ReadNot(
          'the strategy "${summary.name}" ($id) has no record of the version '
          'of Icarus that wrote it: the store was written by a build from '
          'before that record was kept',
        );
      case StoredRowsRead(written: WrittenUnreadable(:final stored)):
        return _ReadNot(
          'the strategy "${summary.name}" ($id) has a version record this '
          'build cannot read: $stored',
        );
      case StoredRowsNot(:final stored):
        read = stored;
    }
    switch (read) {
      case StoredAsData(:final strategy):
        strategies[id] = strategy;
      case final other:
        return _ReadNot('the strategy $id reads as $other');
    }
  }
  return _ReadWhole(
    (strategies: strategies, folders: folders, numbers: numbers),
  );
}

sealed class _Commit {
  const _Commit();
}

final class _Committed extends _Commit {
  const _Committed();
}

final class _NotCommitted extends _Commit {
  const _NotCommitted(this.words, {this.mayHaveLanded = false});

  final String words;
  final bool mayHaveLanded;
}

_Commit _commitOf(LibraryEditResult result) => switch (result) {
      Saved() || NothingToSave() => const _Committed(),
      Refused(:final reason) =>
        _NotCommitted('the library refused the change: $reason'),
      NotSaved(:final failure) =>
        _NotCommitted('the change was not saved: $failure'),
      SaveInDoubt(:final failure) => _NotCommitted(
          'the change may not have been saved: $failure',
          mayHaveLanded: true,
        ),
    };

final class _InFlight {
  _InFlight(this.replay);

  final void Function() replay;
}

String _unwritable(StrategyData strategy, List<RowsProblem> problems) =>
    'the strategy ${strategy.id} cannot be written: '
    '${problems.map(rowsProblemWords).join('; ')}';

Folder _copyOf(Folder folder) => Folder(
      name: folder.name,
      id: folder.id,
      dateCreated: folder.dateCreated,
      iconId: folder.iconId,
      color: folder.color,
      parentID: folder.parentID,
      customColor: folder.customColor,
    );

LibraryWrite _failed(String words, {bool mayHaveLanded = false}) =>
    LibraryWriteFailed(
      StoreWriteFailed(words),
      StackTrace.current,
      mayHaveLanded: mayHaveLanded,
    );

final class StoreLibrary {
  StoreLibrary._(this._store, this._lost, _Held held)
      : strategies = StoreRecords(held.strategies),
        folders = StoreRecords(held.folders),
        _numbers = held.numbers;

  static Future<StoreLibraryLoad> load(
    LibraryStore store, {
    required void Function(String why) lost,
  }) async =>
      switch (await _readLibrary(store)) {
        _ReadWhole(:final held) =>
          StoreLibraryLoaded(StoreLibrary._(store, lost, held)),
        _ReadNot(:final why) => StoreLibraryNotLoaded(why),
      };

  final LibraryStore _store;
  final void Function(String why) _lost;
  var _isLost = false;
  Map<String, Map<String, int>> _numbers;
  final StoreRecords<StrategyData> strategies;
  final StoreRecords<Folder> folders;
  Future<void> _turn = Future.value();
  final _inFlight = <_InFlight>[];

  Future<LibraryWrite> _write({
    required void Function() show,
    required void Function() replay,
    required Future<_Commit> Function() commit,
  }) {
    show();
    final inFlight = _InFlight(replay);
    _inFlight.add(inFlight);
    final written = Completer<LibraryWrite>();
    _turn = _turn.then((_) async {
      final committed = await commit();
      _inFlight.remove(inFlight);
      switch (committed) {
        case _Committed():
          written.complete(const LibraryWritten());
        case _NotCommitted(:final words, :final mayHaveLanded):
          if (mayHaveLanded) {
            AppErrorReporter.reportError(
              'The library store lost the answer to a save, which may have '
              'landed: $words',
              source: 'libraryStore.lostAnswer',
              promptUser: false,
            );
          }
          await _readAgain();
          written.complete(_failed(words, mayHaveLanded: mayHaveLanded));
      }
    });
    return written.future;
  }

  Future<SummariesWrittenBack> writeBackRebuiltSummaries({
    required bool Function() stillServed,
  }) {
    final written = Completer<SummariesWrittenBack>();
    _turn = _turn.then((_) async {
      if (_isLost || !stillServed()) {
        written.complete(const NothingToSave());
        return;
      }
      final result = await _store.writeBackRebuiltSummaries();
      switch (result) {
        case Saved() || NothingToSave():
          break;
        case NotSaved(:final failure):
          AppErrorReporter.reportError(
            'The library store did not write back the summaries it rebuilt at '
            'open; the next open rebuilds them again: $failure',
            source: 'libraryStore.summariesWrittenBack',
            promptUser: false,
          );
          _lostIfShut();
        case SaveInDoubt(:final failure):
          AppErrorReporter.reportError(
            'The library store lost the answer to writing back the summaries '
            'it rebuilt at open: $failure',
            source: 'libraryStore.lostAnswer',
            promptUser: false,
          );
          _lostIfShut();
        case Refused():
          break;
      }
      written.complete(result);
    });
    return written.future;
  }

  void _becomeLost(String why) {
    if (_isLost) return;
    _isLost = true;
    _lost(why);
  }

  void _lostIfShut() {
    if (_store.library case LibraryShut(:final failure)) {
      _becomeLost('the store is shut: $failure');
    }
  }

  Future<void> _readAgain() async {
    switch (await _readLibrary(_store)) {
      case _ReadWhole(:final held):
        strategies._replaceAll(held.strategies);
        folders._replaceAll(held.folders);
        _numbers = held.numbers;
        for (final inFlight in [..._inFlight]) {
          inFlight.replay();
        }
      case _ReadNot(:final why):
        _becomeLost(why);
    }
  }

  String? _folderRefusal(String? folderId) =>
      folderId == null || folders.containsKey(folderId)
          ? null
          : 'the folder $folderId is not in the library';

  String? _placeRefusal(Folder folder, String? parentId) {
    final seen = <String>{};
    for (String? at = parentId; at != null; at = folders.get(at)?.parentID) {
      if (at == folder.id) {
        return 'the folder ${folder.id} would be inside itself';
      }
      if (!folders.containsKey(at))
        return 'the folder $at is not in the library';
      if (!seen.add(at)) return 'the folders above ${folder.id} form a loop';
    }
    return null;
  }

  String? _heldRefusal<T>(StoreRecords<T> records, String id, T stored) =>
      identical(records.get(id), stored)
          ? null
          : 'the library no longer holds this $id as it was handed in';

  Future<LibraryWrite> putStrategy(StrategyData strategy) async {
    if (_folderRefusal(strategy.folderID) case final refusal?) {
      return _failed(refusal);
    }
    final StrategyRowSet rows;
    switch (strategyToRows(
      strategy,
      storedNumbers: _numbers[strategy.id] ?? const {},
    )) {
      case StrategyRowsRefused(:final problems):
        return _failed(_unwritable(strategy, problems));
      case StrategyRowsMade(rows: final made):
        rows = made;
    }
    void show() => strategies._put(strategy.id, strategy);
    return _write(
      show: show,
      replay: show,
      commit: () => _putRows(rows, writtenAt: strategy.versionNumber),
    );
  }

  Future<LibraryWrite> renameStrategy(StrategyData stored, String name) =>
      _changeStrategy(stored, () => stored.name = name, (before) {
        stored.name = before.name;
      });

  Future<LibraryWrite> moveStrategy(StrategyData stored, String? folderId) {
    if (_folderRefusal(folderId) case final refusal?) {
      return Future.value(_failed(refusal));
    }
    return _changeStrategy(stored, () => stored.folderID = folderId, (before) {
      stored.folderID = before.folderID;
    });
  }

  Future<LibraryWrite> _changeStrategy(
    StrategyData stored,
    void Function() change,
    void Function(StrategyData before) asItWas,
  ) async {
    if (_heldRefusal(strategies, stored.id, stored) case final refusal?) {
      return _failed(refusal);
    }
    final before = stored.copyWith();
    change();
    switch (strategyToRows(
      stored,
      storedNumbers: _numbers[stored.id] ?? const {},
    )) {
      case StrategyRowsRefused(:final problems):
        asItWas(before);
        return _failed(_unwritable(stored, problems));
      case StrategyRowsMade(:final rows):
        final asWritten = wholeCopyOf(stored);
        return _write(
          show: () => strategies._put(stored.id, stored),
          replay: () => strategies._put(stored.id, asWritten),
          commit: () => _putRows(rows, writtenAt: stored.versionNumber),
        );
    }
  }

  Future<_Commit> _putRows(StrategyRowSet rows, {required int writtenAt}) async {
    final committed = _commitOf(
      await _store.putStrategy(rows, writtenAt: writtenAt),
    );
    if (committed is _Committed) {
      _numbers[rows.strategy.publicId] = _numbersOf(rows);
    }
    return committed;
  }

  Future<LibraryWrite> putFolder(Folder folder) async {
    if (_placeRefusal(folder, folder.parentID) case final refusal?) {
      return _failed(refusal);
    }
    return _writeFolder(folder);
  }

  Future<LibraryWrite> restyleFolder(Folder stored, void Function() change) {
    if (_heldRefusal(folders, stored.id, stored) case final refusal?) {
      return Future.value(_failed(refusal));
    }
    change();
    return _writeFolder(stored);
  }

  Future<LibraryWrite> moveFolder(Folder stored, String? parentId) {
    if (_heldRefusal(folders, stored.id, stored) ??
            _placeRefusal(stored, parentId)
        case final refusal?) {
      return Future.value(_failed(refusal));
    }
    stored.parentID = parentId;
    return _writeFolder(stored);
  }

  Future<LibraryWrite> _writeFolder(Folder folder) {
    final row = PutFolder(_folderRow(folder));
    final asWritten = _copyOf(folder);
    return _write(
      show: () => folders._put(folder.id, folder),
      replay: () => folders._put(folder.id, asWritten),
      commit: () async => _commitOf(await _store.editLibrary([row])),
    );
  }

  Future<LibraryWrite> deleteStrategy(String id) {
    void show() => strategies._remove(id);
    return _write(
      show: show,
      replay: show,
      commit: () async => switch (_store.library) {
        LibraryShut(:final failure) =>
          _NotCommitted('the store is shut: $failure'),
        LibraryOpen() when _store.summaryOf(id) == null => const _Committed(),
        LibraryOpen() =>
          _commitOf(await _store.editLibrary([RemoveStrategy(id)])),
      },
    );
  }

  Future<LibraryWrite> deleteFoldersWithStrategies({
    required List<String> folderIds,
    required List<String> strategyIds,
  }) {
    if (_deleteRefusal(folderIds, strategyIds) case final refusal?) {
      return Future.value(_failed(refusal));
    }
    void show() {
      strategyIds.forEach(strategies._remove);
      folderIds.forEach(folders._remove);
    }

    return _write(
      show: show,
      replay: show,
      commit: () async {
        final LibraryList list;
        switch (_store.library) {
          case LibraryOpen(list: final open):
            list = open;
          case LibraryShut(:final failure):
            return _NotCommitted('the store is shut: $failure');
        }
        final going = {...folderIds};
        final inThem = {
          for (final summary in list.strategies)
            if (summary.sync is KeptHere &&
                going.contains(summary.folderPublicId))
              summary.publicId,
        };
        final asked = {
          for (final id in strategyIds)
            if (_store.summaryOf(id) != null) id,
        };
        if (!setEquals(inThem, asked)) {
          return const _NotCommitted(
            'the folders hold other strategies than the ones asked to go',
          );
        }
        final rows = [
          for (final row in list.folders)
            if (going.contains(row.publicId)) row,
        ];
        if (asked.isEmpty && rows.isEmpty) return const _Committed();
        return _commitOf(await _store.editLibrary([
          for (final id in asked) RemoveStrategy(id),
          for (final row in folderRowsChildrenFirst(rows))
            RemoveFolder(row.publicId),
        ]));
      },
    );
  }

  String? _deleteRefusal(List<String> folderIds, List<String> strategyIds) {
    final going = {...folderIds};
    final inThem = {
      for (final strategy in strategies.values)
        if (going.contains(strategy.folderID)) strategy.id,
    };
    final asked = {
      for (final id in strategyIds)
        if (strategies.containsKey(id)) id,
    };
    if (!setEquals(inThem, asked)) {
      return 'the folders hold other strategies than the ones asked to go';
    }
    for (final folder in folders.values) {
      if (going.contains(folder.parentID) && !going.contains(folder.id)) {
        return 'the folder ${folder.parentID} holds a folder not asked to go';
      }
    }
    return null;
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
