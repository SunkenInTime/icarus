import 'package:collection/collection.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

typedef TileFields = ({
  String id,
  String name,
  String? map,
  String? folder,
  int createdAt,
  int lastEdited,
  String side,
  bool opensOnAttack,
  String agents,
});

TileFields fromHive(StrategyData strategy) {
  final summary =
      LocalStrategySummary.fromHive(strategyAsHiveHoldsIt(strategy));
  return (
    id: summary.id,
    name: summary.name,
    map: Maps.mapNames[summary.mapData],
    folder: summary.folderId,
    createdAt: summary.createdAt.millisecondsSinceEpoch,
    lastEdited: summary.lastEdited.millisecondsSinceEpoch,
    side: summary.sides.name,
    opensOnAttack: summary.opensOnAttack,
    agents: [for (final type in summary.agentTypes) type.name].join(' '),
  );
}

TileFields fromStore(StrategySummary summary) => (
      id: summary.publicId,
      name: summary.name,
      map: summary.mapData,
      folder: summary.folderPublicId,
      createdAt: summary.createdAt.millisecondsSinceEpoch,
      lastEdited: summary.updatedAt.millisecondsSinceEpoch,
      side: summary.pageCount == 0 ? 'unknown' : summary.sides.name,
      opensOnAttack: summary.firstPageIsAttack ?? true,
      agents: summary.agentsInOrder.join(' '),
    );

StrategyData inGroupOrder(StrategyData strategy) => strategy.copyWith(
      pages: [
        for (final page in strategy.pages)
          page.copyWith(
            lineUpGraph: LineUpGraph(
              origins: {
                for (final origin
                    in lineUpsInGroupOrder(page.lineUpGraph).origins)
                  origin.id: origin,
              }.values.toList(),
              landings: page.lineUpLandings,
              links: page.lineUpLinks,
            ),
          ),
      ],
    );

sealed class TileParity {
  const TileParity();
}

final class TileSame extends TileParity {
  const TileSame();
}

final class TileInGroupOrder extends TileParity {
  const TileInGroupOrder();
}

final class TileInPageOrder extends TileParity {
  const TileInPageOrder();
}

final class TileDiffers extends TileParity {
  const TileDiffers(this.stored, this.hive);

  final TileFields stored;
  final TileFields hive;

  @override
  String toString() => 'store $stored, Hive $hive';
}

bool pagesOutOfSortOrder(StrategyData strategy) {
  final indexes = [for (final page in strategy.pages) page.sortIndex];
  return indexes.toSet().length != indexes.length ||
      !const ListEquality<int>().equals(indexes, [...indexes]..sort());
}

StrategyData inPageOrder(StrategyData strategy) => strategy.copyWith(
      pages: [...strategy.pages]..sort(
          (a, b) => a.sortIndex != b.sortIndex
              ? a.sortIndex.compareTo(b.sortIndex)
              : a.id.compareTo(b.id),
        ),
    );

TileParity tileParity(StrategySummary summary, StrategyData strategy) {
  final stored = fromStore(summary);
  final hive = fromHive(strategy);
  if (stored == hive) return const TileSame();
  if (stored == fromHive(inGroupOrder(strategy))) {
    return const TileInGroupOrder();
  }
  if (pagesOutOfSortOrder(strategy) &&
      (stored == fromHive(inPageOrder(strategy)) ||
          stored == fromHive(inGroupOrder(inPageOrder(strategy))))) {
    return const TileInPageOrder();
  }
  return TileDiffers(stored, hive);
}
