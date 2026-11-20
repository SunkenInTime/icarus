import 'dart:ui';

import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

enum Optionals { set, unset }

AbilityInfo _ability(AgentType agent, int index) =>
    AgentData.agents[agent]!.abilities[index];

List<PlacedAgentNode> _agents(String prefix, Optionals optionals) {
  final full = optionals == Optionals.set;
  return [
    PlacedAgent(
      id: '$prefix-agent',
      type: AgentType.jett,
      position: const Offset(101.25, 202.5),
      isAlly: !full,
      lineUpID: full ? 'group-from-legacy' : null,
      state: full ? AgentState.dead : AgentState.none,
      weapon: full ? WeaponType.operator : WeaponType.none,
    )..caption = full ? 'Entry first' : null,
    PlacedViewConeAgent(
      id: '$prefix-cone-agent',
      type: AgentType.killjoy,
      position: const Offset(300, 120),
      presetType: UtilityType.viewCone90,
      rotation: full ? 1.25 : 0,
      length: full ? 48.5 : 0,
      visionElevation: full ? 2.5 : null,
      isAlly: full,
      weapon: full ? WeaponType.vandal : WeaponType.none,
    )..caption = full ? '' : null,
    PlacedCircleAgent(
      id: '$prefix-circle-agent',
      type: AgentType.viper,
      position: const Offset(410, 330),
      diameterMeters: full ? 12.5 : 0,
      colorValue: full ? 0x803B82F6 : 0xFFFFFFFF,
      opacityPercent: full ? 45 : 100,
      state: full ? AgentState.dead : AgentState.none,
    ),
  ];
}

List<PlacedAbility> _abilities(String prefix, Optionals optionals) {
  final full = optionals == Optionals.set;
  return [
    PlacedAbility(
      id: '$prefix-ability',
      data: _ability(AgentType.sova, 0),
      position: const Offset(55, 66),
      isAlly: !full,
      length: full ? 30.5 : 0,
      rotation: full ? 0.75 : 0,
      lineUpID: full ? 'group-from-legacy' : null,
      visualState: full
          ? const AbilityVisualState(
              showRangeOutline: false,
              showRangeFill: false,
              showInnerOutline: false,
              showInnerFill: false,
              showVisionCone: false,
            )
          : const AbilityVisualState(),
    )..caption = full ? 'Shock dart' : null,
    PlacedAbility(
      id: '$prefix-paranoia',
      data: _ability(AgentType.omen, 1),
      position: const Offset(700, 250),
      rotation: full ? 2 : 0,
    ),
    PlacedAbility(
      id: '$prefix-high-tide',
      data: _ability(AgentType.harbor, 1),
      position: const Offset(500, 500),
      wallPath:
          full ? const [Offset(0, 0), Offset(12.5, 4), Offset(30, -8)] : null,
    ),
    PlacedAbility(
      id: '$prefix-barrier-mesh',
      data: _ability(AgentType.deadlock, 1),
      position: const Offset(640, 410),
      rotation: full ? 0.5 : 0,
      armLengthsMeters: full ? const [3, 4.5, 6, 7.5] : null,
    ),
  ];
}

List<DrawingElement> _drawings(String prefix, Optionals optionals) {
  final full = optionals == Optionals.set;
  final box = full
      ? BoundingBox(min: const Offset(1, 2), max: const Offset(90, 80))
      : null;
  return [
    FreeDrawing(
      id: '$prefix-free',
      listOfPoints: const [Offset(1, 2), Offset(10, 20), Offset(30, 25.5)],
      colorValue: 0xFFE11D48,
      thickness: full ? 6 : Settings.defaultStrokeThickness,
      boundingBox: box,
      isDotted: full,
      hasArrow: full,
      showTraversalTime: full,
      traversalSpeedProfile:
          full ? TraversalSpeedProfile.neonRun : TraversalSpeed.defaultProfile,
    ),
    Line(
      id: '$prefix-line',
      lineStart: const Offset(5, 5),
      lineEnd: const Offset(80, 45),
      colorValue: 0xFFFFFFFF,
      thickness: full ? 2.5 : Settings.defaultStrokeThickness,
      boundingBox: box,
      isDotted: full,
      hasArrow: !full,
      showTraversalTime: full,
      traversalSpeedProfile:
          full ? TraversalSpeedProfile.walking : TraversalSpeed.defaultProfile,
    ),
    RectangleDrawing(
      id: '$prefix-rectangle',
      start: const Offset(10, 10),
      end: const Offset(60, 40),
      colorValue: 0xFF22C55E,
      thickness: full ? 4 : Settings.defaultStrokeThickness,
      boundingBox: box,
      isDotted: full,
      hasArrow: false,
    ),
    EllipseDrawing(
      id: '$prefix-ellipse',
      start: const Offset(15, 15),
      end: const Offset(70, 35),
      colorValue: 0xFF3B82F6,
      thickness: full ? 3 : Settings.defaultStrokeThickness,
      boundingBox: box,
      isDotted: !full,
      hasArrow: full,
    ),
  ];
}

List<PlacedText> _texts(String prefix, Optionals optionals) {
  final full = optionals == Optionals.set;
  return [
    PlacedText(
      id: '$prefix-text',
      position: const Offset(220, 140),
      size: full ? 240 : 185,
      fontSize: full ? 22 : 16,
      sizeVersion: full ? 1 : null,
      tagColorValue: full ? 0xFFF59E0B : null,
    )
      ..text = full ? 'Rotate "B" after 1:10 \\ fake' : ''
      ..caption = full ? 'Call it' : null,
  ];
}

List<PlacedImage> _images(String prefix, Optionals optionals) {
  final full = optionals == Optionals.set;
  return [
    PlacedImage(
      id: '$prefix-image',
      position: const Offset(320, 260),
      aspectRatio: 1.5,
      scale: full ? 0.8 : 1,
      fileExtension: full ? '.png' : null,
      sizeVersion: full ? PlacedImage.currentSizeVersion : null,
      tagColorValue: full ? 0xFF10B981 : null,
      link: full ? 'https://example.com/clip' : '',
      assetId: full ? '$prefix-picture' : null,
    )..caption = full ? 'Smoke timing' : null,
  ];
}

List<PlacedUtility> _utilities(String prefix, Optionals optionals) {
  final full = optionals == Optionals.set;
  return [
    for (final type in UtilityType.values)
      PlacedUtility(
        id: '$prefix-utility-${type.name}',
        type: type,
        position: Offset(40.0 + type.index * 10, 90),
        isAlly: !full,
        angle: full ? 0.3 : 0,
        visionElevation: full ? 1.5 : null,
        customDiameter: full ? 14 : null,
        customWidth: full ? 6 : null,
        customLength: full ? 18 : null,
        customColorValue: full ? 0xFF22C55E : null,
        customOpacityPercent: full ? 30 : null,
        isZone: full && type == UtilityType.customRectangle,
      )
        ..rotation = full ? 1.1 : 0
        ..length = full ? 20 : 0
        ..caption = full ? 'Watch ${type.name}' : null,
    if (full)
      PlacedUtility(
        id: '$prefix-door',
        type: UtilityType.customRectangle,
        position: const Offset(600, 600),
        customWidth: 4,
        customLength: 12,
        mapDoor: 'lotus-a',
      ),
  ];
}

LineUpGraph sharedSpotLineups(String prefix) {
  PlacedAgent agent(String id) => PlacedAgent(
        id: '$prefix-$id',
        type: AgentType.sova,
        position: const Offset(12, 34),
      );
  PlacedAbility landing(String id) => PlacedAbility(
        id: '$prefix-$id',
        data: _ability(AgentType.sova, 1),
        position: const Offset(56, 78),
      );
  return LineUpGraph(
    origins: [
      LineUpOrigin(id: '$prefix-origin-1', agent: agent('origin-agent-1')),
      LineUpOrigin(id: '$prefix-origin-2', agent: agent('origin-agent-2')),
      LineUpOrigin(id: '$prefix-origin-3', agent: agent('origin-agent-3')),
    ],
    landings: [
      LineUpLanding(id: '$prefix-landing-1', ability: landing('landing-1')),
      LineUpLanding(id: '$prefix-landing-2', ability: landing('landing-2')),
      LineUpLanding(id: '$prefix-landing-3', ability: landing('landing-3')),
    ],
    links: [
      LineUpLink(
        id: '$prefix-link-a',
        originId: '$prefix-origin-1',
        landingId: '$prefix-landing-1',
        name: 'A main',
        youtubeLink: 'https://youtu.be/example',
        notes: 'Jump throw',
        images: [
          SimpleImageData(id: '$prefix-lineup-shot-1', fileExtension: '.png'),
          SimpleImageData(id: '$prefix-lineup-shot-2', fileExtension: '.jpg'),
        ],
      ),
      LineUpLink(
        id: '$prefix-link-b',
        originId: '$prefix-origin-1',
        landingId: '$prefix-landing-2',
      ),
      LineUpLink(
        id: '$prefix-link-c',
        originId: '$prefix-origin-2',
        landingId: '$prefix-landing-2',
        name: 'Shared landing',
      ),
      LineUpLink(
        id: '$prefix-link-d',
        originId: '$prefix-origin-3',
        landingId: '$prefix-landing-3',
      ),
    ],
  );
}

StrategyPage generatedPage({
  required String id,
  required int sortIndex,
  required Optionals optionals,
  required bool isAttack,
  bool? isAutoNamed,
  String? itemPrefix,
  LineUpGraph lineups = LineUpGraph.empty,
}) {
  final prefix = itemPrefix ?? id;
  final full = optionals == Optionals.set;
  return StrategyPage(
    id: id,
    name: full ? 'Page "$sortIndex" \\ retake' : 'Page ${sortIndex + 1}',
    isAutoNamed: isAutoNamed,
    drawingData: _drawings(prefix, optionals),
    agentData: _agents(prefix, optionals),
    abilityData: _abilities(prefix, optionals),
    textData: _texts(prefix, optionals),
    imageData: _images(prefix, optionals),
    utilityData: _utilities(prefix, optionals),
    sortIndex: sortIndex,
    isAttack: isAttack,
    settings: full
        ? StrategySettings(
            agentSize: 31.5,
            abilitySize: 19.25,
            useNeutralTeamColors: true,
          )
        : StrategySettings(),
    lineUpOrigins: lineups.origins,
    lineUpLandings: lineups.landings,
    lineUpLinks: lineups.links,
  );
}

StrategyData generatedStrategy(Optionals optionals) {
  final full = optionals == Optionals.set;
  final created = DateTime.utc(2026, 3, 4, 5, 6, 7, 8, 9);
  return StrategyData(
    id: 'strategy-${optionals.name}',
    name: full ? 'Split "B" retake \\ v2' : 'Untitled',
    mapData: full ? MapValue.lotus : MapValue.ascent,
    versionNumber: Settings.versionNumber,
    lastEdited: full ? created.add(const Duration(days: 3)) : created,
    createdAt: created,
    folderID: full ? 'folder-1' : null,
    themeProfileId: full ? 'profile-custom' : null,
    themeOverridePalette: full
        ? MapThemePalette(
            baseColorValue: 0xFF101820,
            detailColorValue: 0xFFF2AA4C,
            highlightColorValue: 0xFFFFFFFF,
          )
        : null,
    pages: [
      generatedPage(
        id: 'page-attack',
        sortIndex: 0,
        optionals: optionals,
        isAttack: true,
        isAutoNamed: full ? false : null,
        lineups: full ? sharedSpotLineups('page-attack') : LineUpGraph.empty,
      ),
      generatedPage(
        id: 'page-defense',
        sortIndex: 1,
        optionals: optionals,
        isAttack: false,
        isAutoNamed: full ? true : null,
        itemPrefix: 'page-attack',
        lineups: full ? sharedSpotLineups('page-defense') : LineUpGraph.empty,
      ),
      if (full)
        generatedPage(
          id: 'page-duplicated',
          sortIndex: 2,
          optionals: optionals,
          isAttack: true,
          isAutoNamed: true,
          itemPrefix: 'page-attack',
          lineups: sharedSpotLineups('page-attack'),
        ),
    ],
  );
}
