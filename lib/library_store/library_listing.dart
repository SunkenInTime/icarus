import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_store/hive_naming.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus_library/icarus_library.dart';

final _mapsByName = {
  for (final MapEntry(:key, :value) in Maps.mapNames.entries) value: key,
};

final _agentsByName = AgentType.values.asNameMap();

final class StoredStrategySummary implements LocalStrategySummary {
  StoredStrategySummary._(this._summary, this.mapData, this.agentTypes);

  static StoredStrategySummary? of(StrategySummary summary) {
    final map = _mapsByName[summary.mapData];
    final agents = [
      for (final name in summary.agentsInOrder) _agentsByName[name],
    ];
    if (map == null || agents.contains(null)) return null;
    return StoredStrategySummary._(
      summary,
      map,
      List.unmodifiable(agents.nonNulls),
    );
  }

  final StrategySummary _summary;

  @override
  final MapValue mapData;

  @override
  final List<AgentType> agentTypes;

  @override
  String get id => _summary.publicId;

  @override
  String get name => _summary.name;

  @override
  String? get folderId => _summary.folderPublicId;

  @override
  DateTime get createdAt => _summary.createdAt;

  @override
  DateTime get lastEdited => _summary.updatedAt;

  @override
  LocalSides get sides => _summary.pageCount == 0
      ? LocalSides.unknown
      : switch (_summary.sides) {
          Sides.attack => LocalSides.attack,
          Sides.defend => LocalSides.defend,
          Sides.mixed => LocalSides.mixed,
        };

  @override
  bool get opensOnAttack => _summary.firstPageIsAttack ?? true;

  @override
  bool get notInStore => false;
}

sealed class LibraryListSource {
  const LibraryListSource();
}

final class ListFromHive extends LibraryListSource {
  const ListFromHive();
}

final class ListFromStore extends LibraryListSource {
  const ListFromStore(this.store, this.mirror);

  final LibraryStore store;
  final StoreMirror mirror;
}

int _byKey(String a, String b) => a.compareTo(b);

List<Object> _keysFromHive(Set<String> ids, BoxNames names) => [
      ...{...ids, for (final record in names.kept) record.key},
    ]..sort(compareHiveKeys);

Iterable<T> _merged<T>(
  Iterable<MapEntry<String, T>> stored,
  Set<String> idsFromHive,
  List<Object> keysFromHive,
  T? Function(Object key) hive,
) sync* {
  var next = 0;
  for (final MapEntry(:key, :value) in stored) {
    if (idsFromHive.contains(key)) continue;
    while (next < keysFromHive.length &&
        compareHiveKeys(keysFromHive[next], key) < 0) {
      if (hive(keysFromHive[next]) case final item?) yield item;
      next++;
    }
    yield value;
  }
  for (; next < keysFromHive.length; next++) {
    if (hive(keysFromHive[next]) case final item?) yield item;
  }
}

final class _Drawn<T> implements ValueListenable<T> {
  _Drawn(this._hive, this._marks, this._read);

  final Listenable _hive;
  final Listenable _marks;
  final T Function() _read;

  @override
  T get value => _read();

  @override
  void addListener(VoidCallback listener) {
    _hive.addListener(listener);
    _marks.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _hive.removeListener(listener);
    _marks.removeListener(listener);
  }
}

final class _Moved extends ChangeNotifier {
  void changed() => notifyListeners();
}

final _fromTheStore = Expando<bool>('drawn from the store');

final class StoreLibraryListing implements LocalLibraryListing {
  StoreLibraryListing(this._hive, {required Duration Function() clock})
      : _clock = clock;

  final HiveLibraryListing _hive;
  final Duration Function() _clock;
  LibraryStore? _store;
  StoreMirror? _mirror;
  StreamSubscription<StoreChange>? _storeChanges;
  StreamSubscription<MirrorWrote>? _mirrorUpdates;
  final _stored = SplayTreeMap<String, LocalStrategySummary>(_byKey);
  final _storedFolders = SplayTreeMap<String, Folder>(_byKey);
  final _unshowable = <String>{};
  final _unshowableFolders = <String>{};
  var _marked = (strategies: const <String>{}, folders: const <String>{});
  final _strategiesMoved = _Moved();
  final _foldersMoved = _Moved();
  var _held = false;
  Duration? _firstFromStore;
  var _switches = 0;

  LibraryListSource get source => switch ((_store, _mirror)) {
        (final store?, final mirror?) when !_held =>
          ListFromStore(store, mirror),
        _ => const ListFromHive(),
      };

  Duration? get firstFromStore => _firstFromStore;

  int get switches => _switches;

  Set<String> get strategiesNotInStore => _marked.strategies;

  Set<String> get foldersNotInStore => _marked.folders;

  bool drewFromStore(Object row) => _fromTheStore[row] ?? false;

  late final _strategies = _Drawn<Iterable<LocalStrategySummary>>(
    _hive.strategies,
    _strategiesMoved,
    () => _strategiesNow(),
  );

  late final _folders = _Drawn<Iterable<Folder>>(
    _hive.folders,
    _foldersMoved,
    () => _foldersNow(),
  );

  @override
  ValueListenable<Iterable<LocalStrategySummary>> get strategies => _strategies;

  @override
  ValueListenable<Iterable<Folder>> get folders => _folders;

  Set<String> _strategiesFromHive(StoreMirror mirror) =>
      {...mirror.strategiesNotKnownEqual, ..._unshowable};

  Set<String> _foldersFromHive(StoreMirror mirror) =>
      {...mirror.foldersNotKnownEqual, ..._unshowableFolders};

  Iterable<LocalStrategySummary> _strategiesNow() {
    switch (source) {
      case ListFromHive():
        return _hive.strategiesAsStored();
      case ListFromStore(:final mirror):
        final ids = _strategiesFromHive(mirror);
        return _merged(
          _stored.entries,
          ids,
          _keysFromHive(ids, mirror.reads.names.strategies),
          (key) => _hive.strategyAsStored(key, notInStore: _marked.strategies),
        );
    }
  }

  Iterable<Folder> _foldersNow() {
    switch (source) {
      case ListFromHive():
        return _hive.foldersAsStored();
      case ListFromStore(:final mirror):
        final ids = _foldersFromHive(mirror);
        return _merged(
          _storedFolders.entries,
          ids,
          _keysFromHive(ids, mirror.reads.names.folders),
          _hive.folderAsStored,
        );
    }
  }

  void holdOnHive() => _moving(() => _held = true);

  void letGo() => _moving(() => _held = false);

  void follow(StoreMirror mirror) {
    _mirrorUpdates?.cancel();
    _mirrorUpdates = mirror.updates.listen(
      (wrote) => _moving(() {
        _sourceFrom(mirror);
        if (_store case final store?) _refresh(store, wrote);
      }, wrote: wrote),
    );
    _moving(() => _sourceFrom(mirror));
  }

  void _moving(void Function() change, {MirrorWrote? wrote}) {
    final before = source;
    change();
    final after = source;
    final handedOver = before.runtimeType != after.runtimeType;
    final marks = _marksChanged();
    final caughtUp = after is ListFromStore && wrote != null;
    if (handedOver ||
        marks.strategies ||
        (caughtUp && wrote.strategies.isNotEmpty)) {
      _strategiesMoved.changed();
    }
    if (handedOver || marks.folders || (caughtUp && wrote.folders.isNotEmpty)) {
      _foldersMoved.changed();
    }
  }

  void _refresh(LibraryStore store, MirrorWrote wrote) {
    for (final id in wrote.strategies) {
      switch (store.summaryOf(id)) {
        case final summary?:
          _keepSummary(summary);
        case null:
          _forgetSummary(id);
      }
    }
    for (final id in wrote.folders) {
      switch (store.folderOf(id)) {
        case final row?:
          _keepFolder(row);
        case null:
          _forgetFolder(id);
      }
    }
  }

  void _sourceFrom(StoreMirror mirror) {
    final store = switch (mirror.phase) {
      MirrorFollowing(:final store) when store.isOpen => store,
      _ => null,
    };
    if (!identical(store, _store)) {
      _storeChanges?.cancel();
      _storeChanges = null;
      _store = null;
      _mirror = null;
      if (store != null) _useStore(store, mirror);
    }
  }

  void _useStore(LibraryStore store, StoreMirror mirror) {
    final list = switch (store.library) {
      LibraryOpen(:final list) => list,
      LibraryShut() => null,
    };
    if (list == null) return;
    _stored.clear();
    _storedFolders.clear();
    _unshowable.clear();
    _unshowableFolders.clear();
    list.strategies.forEach(_keepSummary);
    list.folders.forEach(_keepFolder);
    _store = store;
    _mirror = mirror;
    _storeChanges = store.changes.listen(
      null,
      onDone: () => _moving(() => _sourceFrom(mirror)),
    );
    _firstFromStore ??= _clock();
    _switches++;
  }

  void _keepSummary(StrategySummary summary) {
    final id = summary.publicId;
    _stored.remove(id);
    _unshowable.remove(id);
    if (summary.sync is! KeptHere) return;
    switch (StoredStrategySummary.of(summary)) {
      case final shown?:
        _fromTheStore[shown] = true;
        _stored[id] = shown;
      case null:
        _unshowable.add(id);
    }
  }

  void _forgetSummary(String id) {
    _stored.remove(id);
    _unshowable.remove(id);
  }

  void _keepFolder(FolderRow row) {
    final id = row.publicId;
    _storedFolders.remove(id);
    _unshowableFolders.remove(id);
    switch (row) {
      case final ReadableFolder readable:
        switch (folderFromRow(readable)) {
          case FolderMade(:final folder):
            _fromTheStore[folder] = true;
            _storedFolders[id] = folder;
          case FolderRefused():
            _unshowableFolders.add(id);
        }
      case UnreadableFolder():
        _unshowableFolders.add(id);
    }
  }

  void _forgetFolder(String id) {
    _storedFolders.remove(id);
    _unshowableFolders.remove(id);
  }

  ({bool strategies, bool folders}) _marksChanged() {
    final marked = switch (source) {
      ListFromStore(:final mirror) => (
          strategies: {
            ...mirror.refusedStrategies.keys,
            ..._unshowable,
            ...mirror.reads.names.strategies.keptIds,
          },
          folders: {
            ...mirror.refusedFolders.keys,
            ..._unshowableFolders,
            ...mirror.reads.names.folders.keptIds,
          },
        ),
      ListFromHive() => (
          strategies: const <String>{},
          folders: const <String>{}
        ),
    };
    final before = _marked;
    _marked = marked;
    return (
      strategies: !setEquals(before.strategies, marked.strategies),
      folders: !setEquals(before.folders, marked.folders),
    );
  }

  bool _fromStore(String id) => switch (source) {
        ListFromStore(:final mirror) =>
          !_strategiesFromHive(mirror).contains(id),
        ListFromHive() => false,
      };

  bool _folderFromStore(String id) => switch (source) {
        ListFromStore(:final mirror) => !_foldersFromHive(mirror).contains(id),
        ListFromHive() => false,
      };

  @override
  LocalStrategySummary? strategy(String id) => _fromStore(id)
      ? _stored[id]
      : _hive.strategyAsStored(id, notInStore: _marked.strategies);

  @override
  Folder? folder(String id) =>
      _folderFromStore(id) ? _storedFolders[id] : _hive.folderAsStored(id);

  @override
  List<Folder> folderChildren(String id) =>
      _foldersNow().where((folder) => folder.parentID == id).toList();

  @override
  LocalFolderEntry folderEntry(Folder folder) => drewFromStore(folder)
      ? StoreFolderRow(folder)
      : _hive.folderEntry(folder);

  @override
  bool get holdsAnything =>
      _strategiesNow().isNotEmpty || _foldersNow().isNotEmpty;

  @override
  ValueListenable<bool> mixesSides(String? id) => _Drawn(
        _hive.mixesSides(id),
        _strategiesMoved,
        () => switch (id) {
          final id? => strategy(id)?.sides == LocalSides.mixed,
          null => false,
        },
      );
}
