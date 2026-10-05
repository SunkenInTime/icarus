import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
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
  ReplayCapture({
    required this.createStrategy,
    required this.map,
    required this.name,
  });

  /// Makes the empty strategy the first capture fills, as the library's
  /// New Strategy does.
  final Future<StrategyData> Function(MapValue map, String name) createStrategy;
  final MapValue map;

  /// The strategy's name when the first capture creates it.
  final String name;

  String? _strategyId;

  /// The page the last capture added.
  String? get lastPageId => _lastPageId;
  String? _lastPageId;

  /// The strategy captures go to, while it still exists on this map. If the
  /// user deleted it or moved it to another map, the next capture starts a
  /// new one rather than writing this map's positions into it.
  StrategyData? get strategy {
    final id = _strategyId;
    if (id == null) return null;
    final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id);
    return strategy?.mapData == map ? strategy : null;
  }

  /// Saves [frame] as a page named [pageName] and returns the strategy.
  /// Refuses, without writing, a frame holding a non-finite number.
  Future<StrategyData> capture(
    ReplayFrame frame, {
    required String pageName,
  }) async {
    _checkFinite(frame);
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    var target = strategy;
    final replaceBlankPage = target == null;
    target ??= await createStrategy(map, name);
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
    _lastPageId = page.id;
    return updated;
  }

  static void _checkFinite(ReplayFrame frame) {
    for (final widget in frame.widgets) {
      final geometry = <double>[
        widget.position.dx,
        widget.position.dy,
        ...switch (widget) {
          PlacedViewConeAgent(:final rotation, :final length) => [
              rotation,
              length,
            ],
          PlacedAbility(
            :final rotation,
            :final length,
            :final armLengthsMeters
          ) =>
            [rotation, length, ...armLengthsMeters],
          PlacedUtility(:final rotation, :final length) => [rotation, length],
          _ => const <double>[],
        },
      ];
      if (geometry.any((value) => !value.isFinite)) {
        throw StateError('Capture refused: ${widget.id} is not on the map.');
      }
    }
  }
}
