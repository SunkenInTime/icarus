import 'package:icarus/domain/folder.dart';
import 'package:icarus/strategy/strategy_models.dart';

DateTime _asHiveStoresIt(DateTime time) =>
    DateTime.fromMillisecondsSinceEpoch(time.millisecondsSinceEpoch);

StrategyData strategyAsHiveHoldsIt(StrategyData strategy) => strategy.copyWith(
      createdAt: _asHiveStoresIt(strategy.createdAt),
      lastEdited: _asHiveStoresIt(strategy.lastEdited),
    );

Folder folderAsHiveHoldsIt(Folder folder) => Folder(
      name: folder.name,
      id: folder.id,
      dateCreated: _asHiveStoresIt(folder.dateCreated),
      iconId: folder.iconId,
      color: folder.color,
      parentID: folder.parentID,
      customColor: folder.customColor,
    );

final class HiveLibrary {
  HiveLibrary({
    required Iterable<StrategyData> strategies,
    required Iterable<Folder> folders,
  })  : strategies = List.unmodifiable(strategies.map(strategyAsHiveHoldsIt)),
        folders = List.unmodifiable(folders.map(folderAsHiveHoldsIt));

  final List<StrategyData> strategies;
  final List<Folder> folders;
}
