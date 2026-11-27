import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
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

final class HiveLibraryListing {
  LibraryRecords<StrategyData> get _strategyBox =>
      const LocalLibrary().strategyRecords;

  LibraryRecords<Folder> get _folderBox => const LocalLibrary().folderRecords;

  late final ValueListenable<Iterable<LocalStrategySummary>> strategies =
      _Mapped(
    _strategyBox.listenable(),
    () => _strategyBox.values.map(LocalStrategySummary.fromHive),
  );

  late final ValueListenable<Iterable<Folder>> folders = _Mapped(
    _folderBox.listenable(),
    () => _folderBox.values,
  );

  LocalStrategySummary? strategy(String id) => switch (_strategyBox.get(id)) {
        final strategy? => LocalStrategySummary.fromHive(strategy),
        null => null,
      };

  Folder? folder(String id) => _folderBox.get(id);

  List<Folder> folderChildren(String id) =>
      _folderBox.values.where((folder) => folder.parentID == id).toList();

  LocalFolderEntry folderEntry(Folder folder) => HiveFolderRecord(folder);

  bool get holdsAnything => _strategyBox.isNotEmpty || _folderBox.isNotEmpty;

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
  final onDisk = HiveLibraryListing();

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
