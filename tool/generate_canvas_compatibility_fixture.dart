import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;

const _fixtureVersion = 97;
const _fixtureTimestamp = 946684800;
const _strategyId = 'canvas-compatibility-v97';
const _fixtureName = 'canvas-compatibility-v97';

const _red = 0xFFEF4444;
const _orange = 0xFFF97316;
const _yellow = 0xFFFACC15;
const _green = 0xFF22C55E;
const _blue = 0xFF3B82F6;
const _violet = 0xFF8B5CF6;
const _white = 0xFFFFFFFF;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate the frozen v97 canvas compatibility fixture', () async {
    if (Settings.versionNumber != _fixtureVersion) {
      throw StateError(
        'This generator is frozen at v$_fixtureVersion. Copy it for the '
        'current schema instead of rewriting the historical fixture.',
      );
    }

    final pages = _buildPages();
    final payload = <String, dynamic>{
      'versionNumber': '$_fixtureVersion',
      'mapData': Maps.mapNames[MapValue.ascent],
      'themePalette': MapThemeProfilesProvider.immutableDefaultPalette.toJson(),
      'pages': pages.map((page) => page.toJson(_strategyId)).toList(),
    };

    final archive = Archive()
      ..addFile(
        _fixtureArchiveFile(
          '$_fixtureName.json',
          utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)),
        ),
      );

    for (final spec in _fixtureImages) {
      archive.addFile(
        _fixtureArchiveFile(
          '${spec.id}.png',
          _testImageBytes(spec),
        ),
      );
    }

    final output = File(
      path.join(
        Directory.current.path,
        'test',
        'fixtures',
        'strategy_integrity',
        '$_fixtureName.ica',
      ),
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(ZipEncoder().encode(archive));

    expect(await output.length(), greaterThan(0));
  });
}

ArchiveFile _fixtureArchiveFile(String name, List<int> bytes) {
  return ArchiveFile.bytes(name, bytes)
    ..creationTime = _fixtureTimestamp
    ..lastModTime = _fixtureTimestamp;
}

List<StrategyPage> _buildPages() {
  final pages = <StrategyPage>[];

  void addPage({
    required String name,
    bool isAttack = true,
    StrategySettings? settings,
    List<DrawingElement> drawings = const [],
    List<PlacedAgentNode> agents = const [],
    List<PlacedAbility> abilities = const [],
    List<PlacedText> text = const [],
    List<PlacedImage> images = const [],
    List<PlacedUtility> utilities = const [],
    List<LineUpGroup> lineUps = const [],
  }) {
    final sortIndex = pages.length;
    pages.add(
      StrategyPage(
        id: 'compat-page-${sortIndex + 1}',
        sortIndex: sortIndex,
        name: name,
        isAutoNamed: false,
        drawingData: drawings,
        agentData: agents,
        abilityData: abilities,
        textData: text,
        imageData: images,
        utilityData: utilities,
        lineUpGroups: lineUps,
        isAttack: isAttack,
        settings: settings ?? StrategySettings(),
      ),
    );
  }

  final teamAgents = <PlacedAgentNode>[];
  final teamLabels = <PlacedText>[];
  for (var index = 0; index < AgentType.values.length; index++) {
    final type = AgentType.values[index];
    final column = index % 5;
    final row = index ~/ 5;
    final x = 170.0 + column * 320;
    final y = 130.0 + row * 145;
    teamLabels.add(
      _text(
        'team-label-${type.name}',
        Offset(x - 60, y - 48),
        AgentData.agents[type]!.name,
        width: 150,
        fontSize: 12,
      ),
    );
    teamAgents
      ..add(
        PlacedAgent(
          id: 'team-${type.name}-ally',
          type: type,
          position: Offset(x, y),
        ),
      )
      ..add(
        PlacedAgent(
          id: 'team-${type.name}-enemy',
          type: type,
          position: Offset(x + 62, y),
          isAlly: false,
        ),
      );
  }
  addPage(
    name: '01 Agents - ally and enemy',
    agents: teamAgents,
    text: teamLabels,
  );

  final deadAgents = <PlacedAgentNode>[];
  final deadLabels = <PlacedText>[];
  for (var index = 0; index < AgentType.values.length; index++) {
    final type = AgentType.values[index];
    final column = index % 6;
    final row = index ~/ 6;
    final x = 135.0 + column * 275;
    final y = 145.0 + row * 175;
    deadLabels.add(
      _text(
        'dead-label-${type.name}',
        Offset(x - 50, y - 48),
        AgentData.agents[type]!.name,
        width: 135,
        fontSize: 11,
      ),
    );
    deadAgents.add(
      PlacedAgent(
        id: 'dead-${type.name}',
        type: type,
        position: Offset(x, y),
        isAlly: index.isEven,
        state: AgentState.dead,
      ),
    );
  }
  addPage(
    name: '02 Agents - dead state',
    agents: deadAgents,
    text: deadLabels,
  );

  final specialAgents = <PlacedAgentNode>[
    PlacedAgent(
      id: 'special-plain-ally',
      type: AgentType.jett,
      position: const Offset(180, 200),
    ),
    PlacedAgent(
      id: 'special-plain-enemy',
      type: AgentType.jett,
      position: const Offset(280, 200),
      isAlly: false,
    ),
    PlacedViewConeAgent(
      id: 'special-cone-180',
      type: AgentType.sova,
      position: const Offset(500, 180),
      presetType: UtilityType.viewCone180,
      rotation: math.pi / 7,
      length: 130,
      visionElevation: 1.5,
    ),
    PlacedViewConeAgent(
      id: 'special-cone-90',
      type: AgentType.cypher,
      position: const Offset(880, 220),
      presetType: UtilityType.viewCone90,
      rotation: -math.pi / 3,
      length: 90,
      isAlly: false,
    ),
    PlacedViewConeAgent(
      id: 'special-cone-40-dead',
      type: AgentType.killjoy,
      position: const Offset(1180, 170),
      presetType: UtilityType.viewCone40,
      rotation: math.pi * 0.82,
      length: 165,
      visionElevation: -2,
      state: AgentState.dead,
    ),
    PlacedCircleAgent(
      id: 'special-circle-small',
      type: AgentType.astra,
      position: const Offset(260, 620),
      diameterMeters: 6,
      colorValue: _violet,
      opacityPercent: 30,
    ),
    PlacedCircleAgent(
      id: 'special-circle-large',
      type: AgentType.viper,
      position: const Offset(650, 560),
      diameterMeters: 18,
      colorValue: _green,
      opacityPercent: 65,
      isAlly: false,
    ),
    PlacedCircleAgent(
      id: 'special-circle-dead',
      type: AgentType.omen,
      position: const Offset(1120, 610),
      diameterMeters: 11,
      colorValue: _red,
      opacityPercent: 45,
      state: AgentState.dead,
    ),
  ];
  addPage(
    name: '03 Agents - cones, circles, neutral teams',
    agents: specialAgents,
    settings: StrategySettings(useNeutralTeamColors: true),
    text: [
      _text('special-label-plain', const Offset(120, 95), 'Plain agents'),
      _text(
          'special-label-cones', const Offset(650, 70), 'Attached view cones'),
      _text('special-label-circles', const Offset(610, 470), 'Agent circles'),
    ],
  );

  const agentTypes = AgentType.values;
  for (var start = 0; start < agentTypes.length; start += 4) {
    final end = math.min(start + 4, agentTypes.length);
    final pageAgents = agentTypes.sublist(start, end);
    final abilities = <PlacedAbility>[];
    final labels = <PlacedText>[];

    for (var row = 0; row < pageAgents.length; row++) {
      final type = pageAgents[row];
      final agent = AgentData.agents[type]!;
      final y = 145.0 + row * 225;
      labels.add(
        _text(
          'ability-agent-label-${type.name}',
          Offset(65, y - 45),
          agent.name,
          width: 170,
          fontSize: 18,
          tagColorValue: row.isEven ? _blue : _red,
        ),
      );

      for (var abilityIndex = 0;
          abilityIndex < agent.abilities.length;
          abilityIndex++) {
        final info = agent.abilities[abilityIndex];
        final x = 330.0 + abilityIndex * 220;
        labels.add(
          _text(
            'ability-label-${type.name}-$abilityIndex',
            Offset(x - 70, y - 55),
            info.name,
            width: 180,
            fontSize: 11,
          ),
        );
        abilities.add(
          _placedAbility(
            info,
            id: 'all-ability-${type.name}-$abilityIndex',
            position: Offset(x, y),
            isAlly: (row + abilityIndex).isEven,
            rotation: _abilityRotation(info, row + abilityIndex),
          ),
        );
      }
    }

    addPage(
      name:
          '${(pages.length + 1).toString().padLeft(2, '0')} Abilities - ${pageAgents.first.name} to ${pageAgents.last.name}',
      abilities: abilities,
      text: labels,
      settings: StrategySettings(abilitySize: 22),
    );
  }

  final abilityKinds = _abilityKindSamples();
  final visibilityAbilities = <PlacedAbility>[];
  final visibilityLabels = <PlacedText>[];
  for (var index = 0; index < abilityKinds.length; index++) {
    final sample = abilityKinds[index];
    final column = index % 4;
    final row = index ~/ 4;
    final x = 190.0 + column * 400;
    final y = 190.0 + row * 315;
    visibilityLabels.add(
      _text(
        'visibility-label-${sample.label}',
        Offset(x - 75, y - 70),
        sample.label,
        width: 190,
        fontSize: 13,
      ),
    );
    visibilityAbilities
      ..add(
        _placedAbility(
          sample.info,
          id: 'visibility-${sample.label}-default',
          position: Offset(x, y),
          rotation: math.pi / 9,
        ),
      )
      ..add(
        _placedAbility(
          sample.info,
          id: 'visibility-${sample.label}-reduced',
          position: Offset(x + 145, y + 65),
          isAlly: false,
          rotation: -math.pi / 5,
          visualState: AbilityVisualState(
            showRangeOutline: index % 2 == 0,
            showRangeFill: false,
            showInnerOutline: index % 3 == 0,
            showInnerFill: false,
            showVisionCone: false,
          ),
        ),
      );
  }
  addPage(
    name:
        '${(pages.length + 1).toString().padLeft(2, '0')} Ability visibility states',
    abilities: visibilityAbilities,
    text: visibilityLabels,
  );

  final utilities = <PlacedUtility>[];
  final utilityLabels = <PlacedText>[];
  for (var index = 0; index < UtilityType.values.length; index++) {
    final type = UtilityType.values[index];
    final column = index % 5;
    final row = index ~/ 5;
    final x = 150.0 + column * 330;
    final y = 220.0 + row * 420;
    utilityLabels.add(
      _text(
        'utility-label-${type.name}',
        Offset(x - 45, y - 80),
        type.name,
        width: 155,
        fontSize: 13,
      ),
    );
    utilities
      ..add(
        _utility(
          type,
          id: 'utility-${type.name}-ally',
          position: Offset(x, y),
          isAlly: true,
          rotation: math.pi / 7 + index * 0.08,
          sizeVariant: index,
          baselineCustomShape: true,
        ),
      )
      ..add(
        _utility(
          type,
          id: 'utility-${type.name}-enemy',
          position: Offset(x + 105, y + 95),
          isAlly: false,
          rotation: -math.pi / 4 - index * 0.06,
          sizeVariant: index + 1,
        ),
      );
  }
  addPage(
    name:
        '${(pages.length + 1).toString().padLeft(2, '0')} Utilities and custom shapes',
    utilities: utilities,
    text: utilityLabels,
  );

  addPage(
    name:
        '${(pages.length + 1).toString().padLeft(2, '0')} Drawings and traversal times',
    drawings: _drawingMatrix(),
    text: [
      _text('drawing-label-lines', const Offset(90, 65),
          'Lines and traversal times'),
      _text('drawing-label-free', const Offset(90, 415), 'Freehand'),
      _text('drawing-label-shapes', const Offset(920, 415),
          'Rectangle and ellipse'),
    ],
  );

  addPage(
    name: '${(pages.length + 1).toString().padLeft(2, '0')} Text and images',
    text: _textMatrix(),
    images: _imageMatrix(),
    utilities: [
      _utility(
        UtilityType.customCircle,
        id: 'media-page-custom-circle',
        position: const Offset(1260, 650),
        sizeVariant: 4,
      ),
      _utility(
        UtilityType.customRectangle,
        id: 'media-page-custom-rectangle',
        position: const Offset(1450, 665),
        rotation: math.pi / 5,
        sizeVariant: 6,
      ),
    ],
  );

  addPage(
    name:
        '${(pages.length + 1).toString().padLeft(2, '0')} Lineup groups and stacking',
    lineUps: _lineUpMatrix(),
    text: [
      _text(
          'lineup-label-a', const Offset(120, 110), 'Sova group: three items'),
      _text('lineup-label-b', const Offset(980, 110),
          'Viper group: enemy colors'),
    ],
  );

  final mirrorAttack = _mirrorContent();
  addPage(
    name:
        '${(pages.length + 1).toString().padLeft(2, '0')} Canonical mirror - attack',
    drawings: mirrorAttack.drawings,
    agents: mirrorAttack.agents,
    abilities: mirrorAttack.abilities,
    text: mirrorAttack.text,
    images: mirrorAttack.images,
    utilities: mirrorAttack.utilities,
    lineUps: mirrorAttack.lineUps,
  );

  final mirrorDefense = _mirrorContent();
  addPage(
    name:
        '${(pages.length + 1).toString().padLeft(2, '0')} Canonical mirror - defense',
    isAttack: false,
    drawings: mirrorDefense.drawings,
    agents: mirrorDefense.agents,
    abilities: mirrorDefense.abilities,
    text: mirrorDefense.text,
    images: mirrorDefense.images,
    utilities: mirrorDefense.utilities,
    lineUps: mirrorDefense.lineUps,
  );

  final transitionA = _transitionContent(isEnd: false);
  addPage(
    name:
        '${(pages.length + 1).toString().padLeft(2, '0')} Defense transition A',
    isAttack: false,
    drawings: transitionA.drawings,
    agents: transitionA.agents,
    abilities: transitionA.abilities,
    text: transitionA.text,
    images: transitionA.images,
    utilities: transitionA.utilities,
  );

  final transitionB = _transitionContent(isEnd: true);
  addPage(
    name:
        '${(pages.length + 1).toString().padLeft(2, '0')} Defense transition B',
    isAttack: false,
    drawings: transitionB.drawings,
    agents: transitionB.agents,
    abilities: transitionB.abilities,
    text: transitionB.text,
    images: transitionB.images,
    utilities: transitionB.utilities,
  );

  return pages;
}

PlacedText _text(
  String id,
  Offset position,
  String value, {
  double width = 185,
  double fontSize = 16,
  int? tagColorValue,
}) {
  return PlacedText(
    id: id,
    position: position,
    size: width,
    fontSize: fontSize,
    sizeVersion: worldSizedMediaVersion,
    tagColorValue: tagColorValue,
  )..text = value;
}

PlacedImage _image(
  String id,
  Offset position, {
  required double aspectRatio,
  double width = 185,
  int? tagColorValue,
}) {
  return PlacedImage(
    id: id,
    position: position,
    aspectRatio: aspectRatio,
    scale: width,
    fileExtension: '.png',
    sizeVersion: worldSizedMediaVersion,
    tagColorValue: tagColorValue,
  );
}

PlacedAbility _placedAbility(
  AbilityInfo info, {
  required String id,
  required Offset position,
  bool isAlly = true,
  double rotation = 0,
  AbilityVisualState visualState = const AbilityVisualState(),
  String? lineUpID,
}) {
  final ability = info.abilityData!;
  final length = ability is ResizableSquareAbility
      ? (ability.minLength + ability.height) / 2
      : 0.0;
  final armLengths = ability is DeadlockBarrierMeshAbility
      ? const <double>[2, 4.5, 7, 9.5]
      : null;
  return PlacedAbility(
    id: id,
    data: info,
    position: position,
    isAlly: isAlly,
    rotation: rotation,
    length: length,
    visualState: visualState,
    armLengthsMeters: armLengths,
    lineUpID: lineUpID,
  );
}

double _abilityRotation(AbilityInfo info, int seed) {
  if (!isRotatable(info.abilityData!)) return 0;
  return -math.pi / 2 + seed * math.pi / 7;
}

PlacedUtility _utility(
  UtilityType type, {
  required String id,
  required Offset position,
  bool isAlly = true,
  double rotation = 0,
  int sizeVariant = 0,
  bool baselineCustomShape = false,
}) {
  final isCircle = type == UtilityType.customCircle;
  final isRectangle = type == UtilityType.customRectangle;
  final isCone = UtilityData.isViewCone(type);
  return PlacedUtility(
    id: id,
    type: type,
    position: position,
    isAlly: isAlly,
    angle: isCone ? UtilityData.getViewConeSpawnAngle(type) : 0,
    visionElevation: isCone && sizeVariant.isEven ? sizeVariant / 2 : null,
    customDiameter: isCircle
        ? baselineCustomShape
            ? 14
            : 5.0 + sizeVariant * 1.8
        : null,
    customWidth: isRectangle
        ? baselineCustomShape
            ? 6
            : 3.0 + sizeVariant * 0.7
        : null,
    customLength: isRectangle
        ? baselineCustomShape
            ? 18
            : 10.0 + sizeVariant * 2.2
        : null,
    customColorValue: baselineCustomShape
        ? isCircle
            ? _blue
            : _green
        : isCircle || isRectangle
            ? <int>[_blue, _violet, _green, _orange][sizeVariant % 4]
            : null,
    customOpacityPercent: baselineCustomShape
        ? isCircle
            ? 35
            : 30
        : isCircle || isRectangle
            ? 25 + (sizeVariant % 4) * 20
            : null,
  )
    ..rotation = rotation
    ..length = isCone ? 65.0 + sizeVariant * 14 : 0;
}

List<_AbilityKindSample> _abilityKindSamples() {
  final abilities = [
    for (final type in AgentType.values) ...AgentData.agents[type]!.abilities,
  ];

  AbilityInfo find(bool Function(Ability ability) test) =>
      abilities.firstWhere((info) => test(info.abilityData!));

  return [
    _AbilityKindSample('base icon', find((ability) => ability is BaseAbility)),
    _AbilityKindSample(
      'image smoke',
      find(
        (ability) => ability is ImageAbility && ability.supportsInactiveState,
      ),
    ),
    _AbilityKindSample(
      'circle and inner range',
      find(
        (ability) => ability is CircleAbility && ability.hasInnerRange,
      ),
    ),
    _AbilityKindSample(
      'sector circle',
      find((ability) => ability is SectorCircleAbility),
    ),
    _AbilityKindSample(
      'square wall',
      find(
        (ability) =>
            ability is SquareAbility &&
            ability is! ResizableSquareAbility &&
            ability.supportsInactiveState,
      ),
    ),
    _AbilityKindSample(
      'centered square',
      find((ability) => ability is CenterSquareAbility),
    ),
    _AbilityKindSample(
      'rotatable image',
      find((ability) => ability is RotatableImageAbility),
    ),
    _AbilityKindSample(
      'resizable square',
      find((ability) => ability is ResizableSquareAbility),
    ),
    _AbilityKindSample(
      'barrier mesh',
      find((ability) => ability is DeadlockBarrierMeshAbility),
    ),
  ];
}

List<DrawingElement> _drawingMatrix() {
  final drawings = <DrawingElement>[];
  for (var index = 0; index < TraversalSpeedProfile.values.length; index++) {
    final profile = TraversalSpeedProfile.values[index];
    final y = 150.0 + index * 65;
    drawings.add(
      Line(
        id: 'drawing-line-${profile.name}',
        lineStart: Offset(180, y),
        lineEnd: Offset(1450, y + (index.isEven ? 35 : -25)),
        colorValue: <int>[_white, _yellow, _orange, _blue][index],
        thickness: Settings.strokeThicknessOptions[index],
        isDotted: index.isOdd,
        hasArrow: index >= 2,
        showTraversalTime: true,
        traversalSpeedProfile: profile,
        boundingBox: BoundingBox(
          min: Offset(180, y - 25),
          max: Offset(1450, y + 40),
        ),
      ),
    );
  }

  drawings
    ..add(
      FreeDrawing(
        id: 'drawing-free-solid',
        listOfPoints: const [
          Offset(180, 550),
          Offset(260, 480),
          Offset(350, 610),
          Offset(450, 500),
          Offset(570, 620),
        ],
        colorValue: _green,
        thickness: 8,
        isDotted: false,
        hasArrow: false,
        boundingBox: BoundingBox(
          min: const Offset(180, 480),
          max: const Offset(570, 620),
        ),
      ),
    )
    ..add(
      FreeDrawing(
        id: 'drawing-free-dotted-arrow',
        listOfPoints: const [
          Offset(170, 790),
          Offset(280, 680),
          Offset(390, 820),
          Offset(520, 700),
          Offset(650, 850),
        ],
        colorValue: _violet,
        thickness: 5,
        isDotted: true,
        hasArrow: true,
        showTraversalTime: true,
        traversalSpeedProfile: TraversalSpeedProfile.walking,
        boundingBox: BoundingBox(
          min: const Offset(170, 680),
          max: const Offset(650, 850),
        ),
      ),
    )
    ..add(
      RectangleDrawing(
        id: 'drawing-rectangle-solid',
        start: const Offset(980, 530),
        end: const Offset(1300, 735),
        colorValue: _red,
        thickness: 8,
        isDotted: false,
        hasArrow: false,
        boundingBox: BoundingBox(
          min: const Offset(980, 530),
          max: const Offset(1300, 735),
        ),
      ),
    )
    ..add(
      RectangleDrawing(
        id: 'drawing-rectangle-dotted',
        start: const Offset(1370, 520),
        end: const Offset(1580, 700),
        colorValue: _yellow,
        thickness: 3,
        isDotted: true,
        hasArrow: false,
        boundingBox: BoundingBox(
          min: const Offset(1370, 520),
          max: const Offset(1580, 700),
        ),
      ),
    )
    ..add(
      EllipseDrawing(
        id: 'drawing-ellipse-solid',
        start: const Offset(930, 765),
        end: const Offset(1240, 930),
        colorValue: _blue,
        thickness: 5,
        isDotted: false,
        hasArrow: false,
        boundingBox: BoundingBox(
          min: const Offset(930, 765),
          max: const Offset(1240, 930),
        ),
      ),
    )
    ..add(
      EllipseDrawing(
        id: 'drawing-ellipse-dotted',
        start: const Offset(1330, 760),
        end: const Offset(1600, 925),
        colorValue: _orange,
        thickness: 2,
        isDotted: true,
        hasArrow: false,
        boundingBox: BoundingBox(
          min: const Offset(1330, 760),
          max: const Offset(1600, 925),
        ),
      ),
    );

  return drawings;
}

List<PlacedText> _textMatrix() => [
      _text('text-empty', const Offset(90, 100), '', width: 90, fontSize: 12),
      _text(
        'text-short',
        const Offset(260, 100),
        'Short label',
        width: 140,
        fontSize: 14,
        tagColorValue: _red,
      ),
      _text(
        'text-multiline',
        const Offset(510, 90),
        'Multiline text\nkeeps its measured height\nwhen the side changes.',
        width: 230,
        fontSize: 18,
        tagColorValue: _blue,
      ),
      _text(
        'text-long-word',
        const Offset(870, 95),
        'SUPERCALIFRAGILISTICEXPIALIDOCIOUS',
        width: 185,
        fontSize: 16,
        tagColorValue: _yellow,
      ),
      _text(
        'text-wide',
        const Offset(1190, 90),
        'Maximum-width card with punctuation: A -> B, 90 degrees, 12.5m.',
        width: 460,
        fontSize: 20,
        tagColorValue: _green,
      ),
      _text(
        'text-large',
        const Offset(120, 520),
        'Large type',
        width: 300,
        fontSize: 34,
        tagColorValue: _violet,
      ),
      _text(
        'text-unicode',
        const Offset(520, 530),
        'Unicode: cafe, こんにちは, 안녕하세요, مرحبا',
        width: 360,
        fontSize: 17,
      ),
      _text(
        'text-edge',
        const Offset(1600, 850),
        'Near edge',
        width: 120,
        fontSize: 14,
        tagColorValue: _orange,
      ),
    ];

List<PlacedImage> _imageMatrix() => [
      _image(
        'image-square',
        const Offset(120, 300),
        aspectRatio: 1,
        width: 90,
      ),
      _image(
        'image-wide',
        const Offset(340, 285),
        aspectRatio: 16 / 9,
        width: 260,
        tagColorValue: _blue,
      ),
      _image(
        'image-tall',
        const Offset(760, 270),
        aspectRatio: 9 / 16,
        width: 185,
        tagColorValue: _red,
      ),
      _image(
        'image-tagged',
        const Offset(1030, 285),
        aspectRatio: 2,
        width: 460,
        tagColorValue: _green,
      ),
    ];

List<LineUpGroup> _lineUpMatrix() {
  const sovaGroupId = 'lineup-group-sova';
  const viperGroupId = 'lineup-group-viper';
  final sova = AgentData.agents[AgentType.sova]!;
  final viper = AgentData.agents[AgentType.viper]!;
  return [
    LineUpGroup(
      id: sovaGroupId,
      agent: PlacedAgent(
        id: 'lineup-sova-agent',
        type: AgentType.sova,
        position: const Offset(220, 430),
        lineUpID: sovaGroupId,
      ),
      items: [
        for (var index = 0; index < 3; index++)
          LineUpItem(
            id: 'lineup-sova-item-$index',
            ability: _placedAbility(
              sova.abilities[index + 1],
              id: 'lineup-sova-ability-$index',
              position: Offset(520 + index * 180, 360 + index * 110),
              lineUpID: sovaGroupId,
              rotation: index * math.pi / 5,
            ),
            youtubeLink: index == 0
                ? 'https://www.youtube.com/watch?v=compatibility'
                : '',
            notes: 'Reference ${index + 1}: bounce and aim marker.',
            images: index == 0
                ? [
                    SimpleImageData(
                      id: 'lineup-reference',
                      fileExtension: '.png',
                    ),
                  ]
                : const [],
          ),
      ],
    ),
    LineUpGroup(
      id: viperGroupId,
      agent: PlacedAgent(
        id: 'lineup-viper-agent',
        type: AgentType.viper,
        position: const Offset(1080, 670),
        isAlly: false,
        lineUpID: viperGroupId,
      ),
      items: [
        LineUpItem(
          id: 'lineup-viper-item-0',
          ability: _placedAbility(
            viper.abilities.first,
            id: 'lineup-viper-ability-0',
            position: const Offset(1370, 390),
            isAlly: false,
            lineUpID: viperGroupId,
          ),
          notes: 'Enemy-color lineup with an area ability.',
        ),
        LineUpItem(
          id: 'lineup-viper-item-1',
          ability: _placedAbility(
            viper.abilities[2],
            id: 'lineup-viper-ability-1',
            position: const Offset(1450, 720),
            isAlly: false,
            lineUpID: viperGroupId,
            rotation: math.pi * 0.7,
          ),
          notes: 'Rotated wall endpoint.',
        ),
      ],
    ),
  ];
}

_PageContent _mirrorContent() {
  final breach = AgentData.agents[AgentType.breach]!;
  final deadlock = AgentData.agents[AgentType.deadlock]!;
  return _PageContent(
    drawings: [
      Line(
        id: 'mirror-line',
        lineStart: const Offset(80, 840),
        lineEnd: const Offset(620, 690),
        colorValue: _yellow,
        thickness: 8,
        isDotted: true,
        hasArrow: true,
        showTraversalTime: true,
        traversalSpeedProfile: TraversalSpeedProfile.brimStim,
        boundingBox: BoundingBox(
          min: const Offset(80, 690),
          max: const Offset(620, 840),
        ),
      ),
      FreeDrawing(
        id: 'mirror-freehand',
        listOfPoints: const [
          Offset(1190, 750),
          Offset(1310, 650),
          Offset(1410, 820),
          Offset(1580, 690),
        ],
        colorValue: _green,
        thickness: 5,
        isDotted: false,
        hasArrow: false,
        boundingBox: BoundingBox(
          min: const Offset(1190, 650),
          max: const Offset(1580, 820),
        ),
      ),
    ],
    agents: [
      PlacedAgent(
        id: 'mirror-agent-plain',
        type: AgentType.jett,
        position: const Offset(75, 90),
      ),
      PlacedViewConeAgent(
        id: 'mirror-agent-cone',
        type: AgentType.cypher,
        position: const Offset(1180, 140),
        presetType: UtilityType.viewCone90,
        rotation: math.pi / 3,
        length: 145,
        visionElevation: 2.5,
        isAlly: false,
      ),
      PlacedCircleAgent(
        id: 'mirror-agent-circle',
        type: AgentType.astra,
        position: const Offset(210, 560),
        diameterMeters: 12,
        colorValue: _violet,
        opacityPercent: 42,
      ),
    ],
    abilities: [
      _placedAbility(
        breach.abilities[2],
        id: 'mirror-ability-resizable',
        position: const Offset(510, 210),
        rotation: -math.pi / 4,
      ),
      _placedAbility(
        deadlock.abilities[2],
        id: 'mirror-ability-barrier',
        position: const Offset(860, 520),
        isAlly: false,
        rotation: math.pi / 6,
      ),
    ],
    text: [
      _text(
        'mirror-text-dynamic',
        const Offset(1450, 90),
        'Dynamic text\nuses measured bounds.',
        width: 250,
        fontSize: 19,
        tagColorValue: _blue,
      ),
      _text(
        'mirror-text-edge',
        const Offset(60, 430),
        'Edge anchor',
        width: 115,
        fontSize: 13,
        tagColorValue: _orange,
      ),
    ],
    images: [
      _image(
        'mirror-image',
        const Offset(1390, 400),
        aspectRatio: 16 / 9,
        width: 280,
        tagColorValue: _green,
      ),
    ],
    utilities: [
      _utility(
        UtilityType.viewCone40,
        id: 'mirror-utility-cone',
        position: const Offset(690, 650),
        rotation: math.pi * 0.85,
        sizeVariant: 5,
      ),
      _utility(
        UtilityType.customRectangle,
        id: 'mirror-utility-rectangle',
        position: const Offset(1500, 790),
        rotation: -math.pi / 5,
        sizeVariant: 7,
      ),
      _utility(
        UtilityType.customCircle,
        id: 'mirror-utility-circle',
        position: const Offset(760, 80),
        sizeVariant: 3,
      ),
    ],
    lineUps: _mirrorLineUp(),
  );
}

List<LineUpGroup> _mirrorLineUp() {
  const groupId = 'mirror-lineup-group';
  final kayo = AgentData.agents[AgentType.kayo]!;
  return [
    LineUpGroup(
      id: groupId,
      agent: PlacedAgent(
        id: 'mirror-lineup-agent',
        type: AgentType.kayo,
        position: const Offset(1020, 860),
        lineUpID: groupId,
      ),
      items: [
        LineUpItem(
          id: 'mirror-lineup-item',
          ability: _placedAbility(
            kayo.abilities.first,
            id: 'mirror-lineup-ability',
            position: const Offset(1250, 900),
            lineUpID: groupId,
          ),
          notes: 'Same canonical lineup on both sides.',
        ),
      ],
    ),
  ];
}

_PageContent _transitionContent({required bool isEnd}) {
  final sova = AgentData.agents[AgentType.sova]!;
  final breach = AgentData.agents[AgentType.breach]!;
  if (!isEnd) {
    return _PageContent(
      drawings: [
        FreeDrawing(
          id: 'transition-drawing-disappear',
          listOfPoints: const [
            Offset(120, 780),
            Offset(320, 650),
            Offset(500, 800),
          ],
          colorValue: _orange,
          thickness: 8,
          isDotted: false,
          hasArrow: false,
          boundingBox: BoundingBox(
            min: const Offset(120, 650),
            max: const Offset(500, 800),
          ),
        ),
      ],
      agents: [
        PlacedAgent(
          id: 'transition-agent',
          type: AgentType.jett,
          position: const Offset(210, 180),
        ),
      ],
      abilities: [
        _placedAbility(
          breach.abilities[2],
          id: 'transition-ability',
          position: const Offset(430, 230),
          rotation: 0.2,
        ),
      ],
      text: [
        _text(
          'transition-text-move',
          const Offset(830, 170),
          'Moves across defense',
          width: 230,
          tagColorValue: _blue,
        ),
        _text(
          'transition-text-disappear',
          const Offset(1280, 260),
          'Disappears',
          width: 150,
          tagColorValue: _red,
        ),
      ],
      images: const [],
      utilities: [
        _utility(
          UtilityType.viewCone90,
          id: 'transition-cone',
          position: const Offset(610, 510),
          rotation: -0.8,
          sizeVariant: 2,
        ),
      ],
    );
  }

  return _PageContent(
    drawings: [
      Line(
        id: 'transition-drawing-appear',
        lineStart: const Offset(1050, 760),
        lineEnd: const Offset(1540, 600),
        colorValue: _green,
        thickness: 5,
        isDotted: true,
        hasArrow: true,
        boundingBox: BoundingBox(
          min: const Offset(1050, 600),
          max: const Offset(1540, 760),
        ),
      ),
    ],
    agents: [
      PlacedAgent(
        id: 'transition-agent',
        type: AgentType.jett,
        position: const Offset(1390, 720),
      ),
      PlacedViewConeAgent(
        id: 'transition-agent-appear',
        type: AgentType.sova,
        position: const Offset(230, 650),
        presetType: UtilityType.viewCone40,
        rotation: math.pi / 3,
        length: 110,
      ),
    ],
    abilities: [
      _placedAbility(
        breach.abilities[2],
        id: 'transition-ability',
        position: const Offset(960, 580),
        rotation: 1.8,
      ),
      _placedAbility(
        sova.abilities[2],
        id: 'transition-ability-appear',
        position: const Offset(1450, 180),
        isAlly: false,
      ),
    ],
    text: [
      _text(
        'transition-text-move',
        const Offset(360, 710),
        'Moved across defense\nwith a new height',
        width: 260,
        fontSize: 20,
        tagColorValue: _green,
      ),
    ],
    images: [
      _image(
        'transition-image',
        const Offset(1180, 300),
        aspectRatio: 16 / 9,
        width: 300,
        tagColorValue: _violet,
      ),
    ],
    utilities: [
      _utility(
        UtilityType.viewCone90,
        id: 'transition-cone',
        position: const Offset(680, 320),
        rotation: 2.2,
        sizeVariant: 6,
      ),
      _utility(
        UtilityType.customRectangle,
        id: 'transition-shape-appear',
        position: const Offset(120, 160),
        rotation: -math.pi / 3,
        sizeVariant: 5,
      ),
    ],
  );
}

List<_FixtureImage> get _fixtureImages => const [
      _FixtureImage('image-square', 400, 400),
      _FixtureImage('image-wide', 640, 360),
      _FixtureImage('image-tall', 360, 640),
      _FixtureImage('image-tagged', 720, 360),
      _FixtureImage('lineup-reference', 640, 360),
      _FixtureImage('mirror-image', 640, 360),
      _FixtureImage('transition-image', 640, 360),
    ];

List<int> _testImageBytes(_FixtureImage spec) {
  final image = img.Image(width: spec.width, height: spec.height);
  for (final pixel in image) {
    final isLeft = pixel.x < spec.width / 2;
    final isTop = pixel.y < spec.height / 2;
    final color = switch ((isLeft, isTop)) {
      (true, true) => (239, 68, 68),
      (false, true) => (34, 197, 94),
      (true, false) => (59, 130, 246),
      (false, false) => (250, 204, 21),
    };
    image.setPixelRgba(
      pixel.x,
      pixel.y,
      color.$1,
      color.$2,
      color.$3,
      255,
    );
  }

  final centerX = spec.width ~/ 2;
  final centerY = spec.height ~/ 2;
  for (var y = centerY - 8; y <= centerY + 8; y++) {
    for (var x = centerX - 8; x <= centerX + 8; x++) {
      image.setPixelRgba(x, y, 255, 255, 255, 255);
    }
  }
  return img.encodePng(image);
}

class _AbilityKindSample {
  const _AbilityKindSample(this.label, this.info);

  final String label;
  final AbilityInfo info;
}

class _PageContent {
  const _PageContent({
    this.drawings = const [],
    this.agents = const [],
    this.abilities = const [],
    this.text = const [],
    this.images = const [],
    this.utilities = const [],
    this.lineUps = const [],
  });

  final List<DrawingElement> drawings;
  final List<PlacedAgentNode> agents;
  final List<PlacedAbility> abilities;
  final List<PlacedText> text;
  final List<PlacedImage> images;
  final List<PlacedUtility> utilities;
  final List<LineUpGroup> lineUps;
}

class _FixtureImage {
  const _FixtureImage(this.id, this.width, this.height);

  final String id;
  final int width;
  final int height;
}
