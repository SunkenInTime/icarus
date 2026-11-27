import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/strategy/library_records.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';

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

final class StoreFolderRow extends LocalFolderEntry {
  const StoreFolderRow(this.folder);

  @override
  final Folder folder;
}

abstract interface class LocalStrategySummary {
  factory LocalStrategySummary.fromHive(StrategyData strategy) =
      _HiveStrategySummary;

  String get id;

  String get name;

  MapValue get mapData;

  String? get folderId;

  DateTime get createdAt;

  DateTime get lastEdited;

  LocalSides get sides;

  bool get opensOnAttack;

  List<AgentType> get agentTypes;

  bool get notInStore;
}

DateTime _asStored(DateTime time) => DateTime.fromMillisecondsSinceEpoch(
      time.millisecondsSinceEpoch,
      isUtc: true,
    );

final class _HiveStrategySummary implements LocalStrategySummary {
  _HiveStrategySummary(
    this._strategy, {
    this.notInStore = false,
    this.asStored = false,
  });

  final StrategyData _strategy;
  final bool asStored;

  @override
  final bool notInStore;

  @override
  String get id => _strategy.id;

  @override
  String get name => _strategy.name;

  @override
  MapValue get mapData => _strategy.mapData;

  @override
  String? get folderId => _strategy.folderID;

  @override
  DateTime get createdAt => asStored ? _createdAtAsStored : _strategy.createdAt;

  @override
  DateTime get lastEdited =>
      asStored ? _lastEditedAsStored : _strategy.lastEdited;

  late final _createdAtAsStored = _asStored(_strategy.createdAt);

  late final _lastEditedAsStored = _asStored(_strategy.lastEdited);

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

final _recordBehind = Expando<Folder>('the Hive record a copy was made from');

Folder _folderAsStored(Folder folder) {
  final copy = Folder(
    name: folder.name,
    id: folder.id,
    dateCreated: DateTime.fromMillisecondsSinceEpoch(
      folder.dateCreated.millisecondsSinceEpoch,
    ),
    iconId: folder.iconId,
    color: folder.color,
    parentID: folder.parentID,
    customColor: folder.customColor,
  );
  _recordBehind[copy] = folder;
  return copy;
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

abstract interface class LocalLibraryListing {
  ValueListenable<Iterable<LocalStrategySummary>> get strategies;

  ValueListenable<Iterable<Folder>> get folders;

  LocalStrategySummary? strategy(String id);

  Folder? folder(String id);

  List<Folder> folderChildren(String id);

  LocalFolderEntry folderEntry(Folder folder);

  bool get holdsAnything;

  ValueListenable<bool> mixesSides(String? id);
}

base class HiveLibraryListing implements LocalLibraryListing {
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
  LocalFolderEntry folderEntry(Folder folder) =>
      HiveFolderRecord(_recordBehind[folder] ?? folder);

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

  bool holdsStrategy(String id) => _strategyBox.containsKey(id);

  static LocalStrategySummary asStored(StrategyData strategy) =>
      _HiveStrategySummary(strategy, asStored: true);

  Iterable<LocalStrategySummary> strategiesAsStored() => _strategyBox.values
      .map((strategy) => _HiveStrategySummary(strategy, asStored: true));

  Iterable<Folder> foldersAsStored() => _folderBox.values.map(_folderAsStored);

  Folder? folderAsStored(Object key) =>
      switch (Hive.box<Folder>(HiveBoxNames.foldersBox).get(key)) {
        final folder? => _folderAsStored(folder),
        null => null,
      };

  LocalStrategySummary? strategyAsStored(
    Object key, {
    required Set<String> notInStore,
  }) =>
      switch (Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(key)) {
        final strategy? => _HiveStrategySummary(
            strategy,
            notInStore: notInStore.contains(strategy.id),
            asStored: true,
          ),
        null => null,
      };
}

final localLibraryListingProvider = Provider<LocalLibraryListing?>(
  (ref) => null,
);

final localLibraryViewProvider = Provider<LocalLibraryView>((ref) {
  ref.watch(libraryOnStoreProvider);
  return LocalLibraryView(listing: ref.watch(localLibraryListingProvider));
});

final class LocalLibraryView {
  LocalLibraryView({LocalLibraryListing? listing})
      : onDisk = HiveLibraryListing() {
    _listing = listing ?? onDisk;
  }

  final HiveLibraryListing onDisk;
  late final LocalLibraryListing _listing;

  LibraryRecords<StrategyData> get _strategyBox =>
      const LocalLibrary().strategyRecords;

  LibraryRecords<Folder> get _folderBox => const LocalLibrary().folderRecords;

  ValueListenable<Iterable<LocalStrategySummary>> get strategies =>
      _listing.strategies;

  ValueListenable<Iterable<Folder>> get folders => _listing.folders;

  LocalStrategySummary? strategy(String id) => _listing.strategy(id);

  Folder? folder(String id) => _listing.folder(id);

  List<Folder> folderChildren(String id) => _listing.folderChildren(id);

  LocalFolderEntry folderEntry(Folder folder) => _listing.folderEntry(folder);

  HiveFolderRecord? recordFor(LocalFolderEntry entry) => switch (entry) {
        final HiveFolderRecord record => record,
        StoreFolderRow(:final folder) => switch (_folderBox.get(folder.id)) {
            final stored? => HiveFolderRecord(stored),
            null => null,
          },
      };

  bool get holdsAnything => _listing.holdsAnything;

  ValueListenable<bool> mixesSides(String? id) => _listing.mixesSides(id);

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
