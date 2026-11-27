
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

StrategySettings cloneSettings(StrategySettings settings) => StrategySettings(
      agentSize: settings.agentSize,
      abilitySize: settings.abilitySize,
      useNeutralTeamColors: settings.useNeutralTeamColors,
    );

StrategyPage pageOf({
  required String id,
  required String name,
  required bool? isAutoNamed,
  required int sortIndex,
  required bool isAttack,
  required StrategySettings settings,
  required List<ActionObjectState> objects,
  required LineUpGraph lineups,
}) {
  final graph = lineups.deepCopy();
  return StrategyPage(
    id: id,
    name: name,
    isAutoNamed: isAutoNamed,
    sortIndex: sortIndex,
    isAttack: isAttack,
    settings: cloneSettings(settings),
    agentData: [
      for (final o in objects)
        if (o.kind == ActionObjectKind.agent) o.agent!,
    ],
    abilityData: [
      for (final o in objects)
        if (o.kind == ActionObjectKind.ability) o.ability!,
    ],
    drawingData: [
      for (final o in objects)
        if (o.kind == ActionObjectKind.drawing) o.drawing!,
    ],
    textData: [
      for (final o in objects)
        if (o.kind == ActionObjectKind.text) o.text!,
    ],
    imageData: [
      for (final o in objects)
        if (o.kind == ActionObjectKind.image) o.image!,
    ],
    utilityData: [
      for (final o in objects)
        if (o.kind == ActionObjectKind.utility) o.utility!,
    ],
    lineUpOrigins: graph.origins,
    lineUpLandings: graph.landings,
    lineUpLinks: graph.links,
  );
}

List<ActionObjectState> objectsOnPage(StrategyPage page) => [
      for (final agent in page.agentData) ActionObjectState.agent(agent),
      for (final ability in page.abilityData)
        ActionObjectState.ability(ability),
      for (final drawing in page.drawingData)
        ActionObjectState.drawing(drawing),
      for (final text in page.textData) ActionObjectState.text(text),
      for (final image in page.imageData) ActionObjectState.image(image),
      for (final utility in page.utilityData)
        ActionObjectState.utility(utility),
    ];

StrategyPage clonePage(StrategyPage page) => pageOf(
      id: page.id,
      name: page.name,
      isAutoNamed: page.isAutoNamed,
      sortIndex: page.sortIndex,
      isAttack: page.isAttack,
      settings: page.settings,
      objects: objectsOnPage(page),
      lineups: page.lineUpGraph,
    );

StrategyData cloneStrategy(StrategyData strategy) => strategy.copyWith(
      pages: [for (final page in strategy.pages) clonePage(page)],
    );
