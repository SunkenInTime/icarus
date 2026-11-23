import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
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
  const _HiveStrategySummary(this._strategy);

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

final class _Mapped<S, T> implements ValueListenable<T> {
  const _Mapped(this._source, this._map);

  final ValueListenable<S> _source;
  final T Function(S source) _map;

  @override
  T get value => _map(_source.value);

  @override
  void addListener(VoidCallback listener) => _source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _source.removeListener(listener);
}

final class LocalStrategyImage {
  const LocalStrategyImage._(this._box, this._id);

  final Box<StrategyData> _box;
  final String? _id;

  StrategyData? get current => switch (_id) {
        final id? => _box.get(id),
        null => null,
      };
}

final localLibraryViewProvider = Provider<LocalLibraryView>(
  (ref) => LocalLibraryView(),
);

final class LocalLibraryView {
  Box<StrategyData> get _strategyBox =>
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

  Box<Folder> get _folderBox => Hive.box<Folder>(HiveBoxNames.foldersBox);

  late final ValueListenable<Iterable<LocalStrategySummary>> strategies =
      _Mapped(
    _strategyBox.listenable(),
    (Box<StrategyData> box) => box.values.map(LocalStrategySummary.fromHive),
  );

  late final ValueListenable<Iterable<Folder>> folders = _Mapped(
    _folderBox.listenable(),
    (Box<Folder> box) => box.values,
  );

  LocalStrategySummary? strategy(String id) => switch (_strategyBox.get(id)) {
        final strategy? => LocalStrategySummary.fromHive(strategy),
        null => null,
      };

  Folder? folder(String id) => _folderBox.get(id);

  List<Folder> folderChildren(String id) =>
      _folderBox.values.where((folder) => folder.parentID == id).toList();

  bool get holdsAnything => _strategyBox.isNotEmpty || _folderBox.isNotEmpty;

  bool get isOpen => Hive.isBoxOpen(HiveBoxNames.strategiesBox);

  StrategyData? strategyImage(String id) => _strategyBox.get(id);

  ValueListenable<LocalStrategyImage> strategyImageChanges(String? id) =>
      _Mapped(
        _strategyBox.listenable(keys: [id]),
        (Box<StrategyData> box) => LocalStrategyImage._(box, id),
      );

  Future<StrategyData?> readStrategy(String id) =>
      SynchronousFuture(_strategyBox.get(id));
}
