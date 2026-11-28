import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/library_store/store_library.dart';
import 'package:icarus/strategy/library_records.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

enum LocalSides { attack, defend, mixed, unknown }

sealed class LocalFolderEntry {
  const LocalFolderEntry();

  Folder get folder;
}

final class HiveFolderRecord extends LocalFolderEntry {
  const HiveFolderRecord(this.folder);

  @override
  final Folder folder;
}

abstract interface class LocalStrategySummary {
  factory LocalStrategySummary.fromHive(StrategyData strategy) =
      _HiveStrategySummary;

  factory LocalStrategySummary.fromStore(StrategySummary summary) =
      _StoreStrategySummary;

  String get id;

  String get name;

  MapValue get mapData;

  String? get folderId;

  DateTime get createdAt;

  DateTime get lastEdited;

  LocalSides get sides;

  bool get opensOnAttack;

  List<AgentType> get agentTypes;
}

final class _HiveStrategySummary implements LocalStrategySummary {
  _HiveStrategySummary(this._strategy);

  final StrategyData _strategy;

  @override
  String get id => _strategy.id;

  @override
  String get name => _strategy.name;

  @override
  MapValue get mapData => _strategy.mapData;

  @override
  String? get folderId => _strategy.folderID;

  @override
  DateTime get createdAt => _strategy.createdAt;

  @override
  DateTime get lastEdited => _strategy.lastEdited;

  @override
  LocalSides get sides {
    final pages = _strategy.pages;
    if (pages.isEmpty) return LocalSides.unknown;
    final first = pages.first.isAttack;
    if (pages.any((page) => page.isAttack != first)) return LocalSides.mixed;
    return first ? LocalSides.attack : LocalSides.defend;
  }

  @override
  bool get opensOnAttack =>
      _strategy.pages.isEmpty ? true : _strategy.pages.first.isAttack;

  @override
  List<AgentType> get agentTypes => {
        for (final page in _strategy.pages) ...[
          for (final agent in page.agentData) agent.type,
          for (final origin in page.lineUpOrigins) origin.agent.type,
        ],
      }.toList();
}

final class _StoreStrategySummary implements LocalStrategySummary {
  _StoreStrategySummary(this._summary);

  final StrategySummary _summary;

  static final _agents = AgentType.values.asNameMap();

  @override
  String get id => _summary.publicId;

  @override
  String get name => _summary.name;

  @override
  MapValue get mapData => mapNamed(_summary.mapData)!;

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
  List<AgentType> get agentTypes => [
        for (final name in _summary.agentsInOrder)
          if (_agents[name] case final type?) type,
      ];
}

final class _Mapped<T> implements ValueListenable<T> {
  const _Mapped(this._source, this._read);

  final Listenable _source;
  final T Function() _read;

  @override
  T get value => _read();

  @override
  void addListener(VoidCallback listener) => _source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _source.removeListener(listener);
}

final class LocalStrategyImage {
  const LocalStrategyImage._(this._records, this._id);

  final LibraryRecords<StrategyData> _records;
  final String? _id;

  StrategyData? get current => switch (_id) {
        final id? => _records.get(id),
        null => null,
      };
}

abstract interface class LibraryListing {
  ValueListenable<Iterable<LocalStrategySummary>> get strategies;

  ValueListenable<Iterable<Folder>> get folders;

  LocalStrategySummary? strategy(String id);

  Folder? folder(String id);

  List<Folder> folderChildren(String id);

  LocalFolderEntry folderEntry(Folder folder);

  bool get holdsAnything;

  ValueListenable<bool> mixesSides(String? id);
}

final class StoreLibraryListing implements LibraryListing {
  StoreLibraryListing(this._library);

  final StoreLibrary _library;

  @override
  late final ValueListenable<Iterable<LocalStrategySummary>> strategies =
      _Mapped(
    _library.summaries.listenable(),
    () => _library.summaries.values.map(LocalStrategySummary.fromStore),
  );

  @override
  late final ValueListenable<Iterable<Folder>> folders = _Mapped(
    _library.folders.listenable(),
    () => _library.folders.values,
  );

  @override
  LocalStrategySummary? strategy(String id) =>
      switch (_library.summaries.get(id)) {
        final summary? => LocalStrategySummary.fromStore(summary),
        null => null,
      };

  @override
  Folder? folder(String id) => _library.folders.get(id);

  @override
  List<Folder> folderChildren(String id) => _library.folders.values
      .where((folder) => folder.parentID == id)
      .toList();

  @override
  LocalFolderEntry folderEntry(Folder folder) => HiveFolderRecord(folder);

  @override
  bool get holdsAnything =>
      _library.summaries.isNotEmpty || _library.folders.isNotEmpty;

  @override
  ValueListenable<bool> mixesSides(String? id) => _Mapped(
        _library.summaries.listenable(keys: [id]),
        () => switch (id) {
          final id? => _library.summaries.get(id)?.sides == Sides.mixed,
          null => false,
        },
      );
}

final class HiveLibraryListing implements LibraryListing {
  LibraryRecords<StrategyData> get _strategyBox =>
      const LocalLibrary().strategyRecords;

  LibraryRecords<Folder> get _folderBox => const LocalLibrary().folderRecords;

  @override
  late final ValueListenable<Iterable<LocalStrategySummary>> strategies =
      _Mapped(
    _strategyBox.listenable(),
    () => _strategyBox.values.map(LocalStrategySummary.fromHive),
  );

  @override
  late final ValueListenable<Iterable<Folder>> folders = _Mapped(
    _folderBox.listenable(),
    () => _folderBox.values,
  );

  @override
  LocalStrategySummary? strategy(String id) => switch (_strategyBox.get(id)) {
        final strategy? => LocalStrategySummary.fromHive(strategy),
        null => null,
      };

  @override
  Folder? folder(String id) => _folderBox.get(id);

  @override
  List<Folder> folderChildren(String id) =>
      _folderBox.values.where((folder) => folder.parentID == id).toList();

  @override
  LocalFolderEntry folderEntry(Folder folder) => HiveFolderRecord(folder);

  @override
  bool get holdsAnything => _strategyBox.isNotEmpty || _folderBox.isNotEmpty;

  @override
  ValueListenable<bool> mixesSides(String? id) => _Mapped(
        _strategyBox.listenable(keys: [id]),
        () {
          final pages = switch (id) {
                final id? => _strategyBox.get(id)?.pages,
                null => null,
              } ??
              const [];
          return pages.any((page) => page.isAttack != pages.first.isAttack);
        },
      );
}

final localLibraryViewProvider = Provider<LocalLibraryView>((ref) {
  ref.watch(libraryOnStoreProvider);
  return LocalLibraryView();
});

final class LocalLibraryView {
  final _hive = HiveLibraryListing();
  StoreLibraryListing? _store;

  LibraryListing get onDisk => switch (LocalLibrary.source) {
        LibraryInStore(:final library) => switch (_store) {
            final listing? when identical(listing._library, library) =>
              listing,
            _ => _store = StoreLibraryListing(library),
          },
        LibraryInHive() || LibraryNotOpened() => _hive,
      };

  LibraryRecords<StrategyData> get _strategyBox =>
      const LocalLibrary().strategyRecords;

  ValueListenable<Iterable<LocalStrategySummary>> get strategies =>
      onDisk.strategies;

  ValueListenable<Iterable<Folder>> get folders => onDisk.folders;

  LocalStrategySummary? strategy(String id) => onDisk.strategy(id);

  Folder? folder(String id) => onDisk.folder(id);

  List<Folder> folderChildren(String id) => onDisk.folderChildren(id);

  LocalFolderEntry folderEntry(Folder folder) => onDisk.folderEntry(folder);

  HiveFolderRecord? recordFor(LocalFolderEntry entry) => switch (entry) {
        final HiveFolderRecord record => record,
      };

  bool get holdsAnything => onDisk.holdsAnything;

  ValueListenable<bool> mixesSides(String? id) => onDisk.mixesSides(id);

  bool get isOpen => LocalLibrary.isOpen;

  StrategyData? strategyImage(String id) => _strategyBox.get(id);

  ValueListenable<LocalStrategyImage> strategyImageChanges(String? id) =>
      _Mapped(
        _strategyBox.listenable(keys: [id]),
        () => LocalStrategyImage._(_strategyBox, id),
      );

  Future<StrategyData?> readStrategy(String id) =>
      SynchronousFuture(_strategyBox.get(id));
}
