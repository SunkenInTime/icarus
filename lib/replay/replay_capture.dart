import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:uuid/uuid.dart';

/// Saves replay moments as pages of one strategy. The first capture creates
/// the strategy; later ones append to it, so a replay session builds one
/// strategy page by page.
///
/// Players and utility keep their replay ids on every page, so the editor's
/// page transitions move each player from one captured moment to the next.
class ReplayCapture {
  ReplayCapture({required this.ref, required this.map, required this.name});

  final WidgetRef ref;
  final MapValue map;

  /// The strategy's name when the first capture creates it.
  final String name;

  String? _strategyId;

  /// The strategy captures go to, once there is one.
  StrategyData? get strategy {
    final id = _strategyId;
    if (id == null) return null;
    return Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id);
  }

  /// Saves [frame] as a page named [pageName] and returns the strategy.
  Future<StrategyData> capture(ReplayFrame frame,
      {required String pageName}) async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    var target = strategy;
    final replaceBlankPage = target == null;
    target ??= await ref
        .read(strategyProvider.notifier)
        .createNewStrategy(map: map, name: name);
    _strategyId = target.id;

    final pages = [...target.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final page = StrategyPage(
      id: const Uuid().v4(),
      name: pageName,
      isAutoNamed: false,
      drawingData: const [],
      agentData: frame.agents,
      abilityData: frame.abilities,
      textData: const [],
      imageData: const [],
      utilityData: frame.utilities,
      sortIndex: replaceBlankPage ? 0 : pages.length,
      isAttack: frame.isAttack,
      settings: pages.first.settings,
    );
    final updated = target.copyWith(
      // A new strategy comes with one blank page; the first capture takes
      // its place rather than following it.
      pages: replaceBlankPage ? [page] : [...pages, page],
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
    return updated;
  }
}
