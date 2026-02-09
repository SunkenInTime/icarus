import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/abilities.dart';

enum AgentType {
  jett,
  raze,
  pheonix,
  astra,
  clove,
  breach,
  iso,
  viper,
  deadlock,
  yoru,
  sova,
  skye,
  kayo,
  killjoy,
  brimstone,
  cypher,
  chamber,
  fade,
  gekko,
  harbor,
  neon,
  omen,
  reyna,
  sage,
  vyse,
  tejo,
  waylay,
  veto,
}

enum AgentState {
  dead,
  none,
}

enum AgentRole { controller, duelist, initiator, sentinel }

const Map<AgentRole, String> agentRoleNames = {
  AgentRole.controller: 'controller',
  AgentRole.duelist: 'duelist',
  AgentRole.initiator: 'initiator',
  AgentRole.sentinel: 'sentinel',
};

abstract class DraggableData {}

typedef AbilityBuilder = Ability Function(AbilitySpec spec);

class AbilitySpec {
  AbilitySpec({
    required this.name,
    required this.iconPath,
    required this.buildAbility,
  });

  final String name;
  final String iconPath;
  final AbilityBuilder buildAbility;

  AbilityInfo toAbilityInfo({
    required AgentType type,
    required int index,
  }) {
    return AbilityInfo(
      name: name,
      iconPath: iconPath,
      type: type,
      index: index,
      abilityData: buildAbility(this),
    );
  }
}

class AgentSpec {
  AgentSpec({
    required this.type,
    required this.role,
    required this.name,
    required this.abilities,
  });

  final AgentType type;
  final AgentRole role;
  final String name;
  final List<AbilitySpec> abilities;

  AgentData toAgentData() {
    final abilityInfos = List<AbilityInfo>.generate(
      abilities.length,
      (index) => abilities[index].toAbilityInfo(type: type, index: index),
    );
    return AgentData(
      type: type,
      role: role,
      name: name,
      abilities: abilityInfos,
    );
  }
}

// Virtual distance to valorant distance is valmeters * 4.952941176470588 = vitual distance
@HiveType(typeId: 9)
class AbilityInfo extends HiveObject implements DraggableData {
  // Even though you might have more properties at runtime,
  // only these two are persisted.
  @HiveField(0)
  final AgentType type;

  @HiveField(1)
  final int index;

  /// The following fields are not persisted.
  final String name;
  final String iconPath;
  Ability? abilityData;
  bool isTransformable = false;
  Offset? centerPoint;

  AbilityInfo({
    required this.name,
    required this.iconPath,
    required this.type,
    required this.index,
    Ability? abilityData,
  }) : abilityData = abilityData ?? _lookupAbility(type, index);

  AbilityInfo copyWith({
    String? name,
    String? iconPath,
    Ability? abilityData,
    AgentType? type,
    int? index,
  }) {
    return AbilityInfo(
      name: name ?? this.name,
      iconPath: iconPath ?? this.iconPath,
      type: type ?? this.type,
      index: index ?? this.index,
      abilityData: abilityData ?? this.abilityData,
    );
  }

  void updateCenterPoint(Offset centerPoint) {
    this.centerPoint = centerPoint;
  }

  /// Helper method to perform the lookup on deserialization.
  static Ability? _lookupAbility(AgentType type, int index) {
    return AgentData.abilityFor(type, index).abilityData;
  }
}

// This is the custom Hive adapter for AbilityInfo.
// It only stores the AgentType and index.
class AbilityInfoAdapter extends TypeAdapter<AbilityInfo> {
  @override
  final int typeId = 9;

  @override
  AbilityInfo read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };

    // Retrieve stored type and index
    final agentType = fields[0] as AgentType;
    final index = fields[1] as int;

    // Lookup the complete AbilityInfo data.
    return AgentData.abilityFor(agentType, index);
  }

  @override
  void write(BinaryWriter writer, AbilityInfo obj) {
    // Only persist type and index.
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.index);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AbilityInfoAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AgentData implements DraggableData {
  final AgentType type;
  final AgentRole role;
  final List<AbilityInfo> abilities;
  final String name;
  final String iconPath;

  static const double inGameMeters = 5.5;
  // static const double inGameMeters = 6;

  static const double inGameMetersDiameter = inGameMeters * 2;
  AgentData({
    required this.type,
    required this.role,
    required this.name,
    List<AbilityInfo>? abilities,
  })  : iconPath = 'assets/agents/$name/icon.webp',
        abilities = abilities ?? _defaultAbilities(type, name);
  static final Map<AgentType, AgentData> agents = _buildAgents();

  static Map<AgentType, AgentData> _buildAgents() {
    return {for (final spec in _agentSpecs) spec.type: spec.toAgentData()};
  }

  static AbilityInfo abilityFor(AgentType type, int index) {
    final agent = agents[type];
    if (agent != null && index >= 0 && index < agent.abilities.length) {
      return agent.abilities[index];
    }
    assert(() {
      debugPrint(
        'AbilityInfo lookup failed for $type index $index. Falling back.',
      );
      return true;
    }());
    return _fallbackAbility(type);
  }

  static List<AbilityInfo> _defaultAbilities(AgentType type, String name) {
    return List<AbilityInfo>.generate(
      4,
      (index) => AbilityInfo(
        name: 'Ability ${index + 1}',
        iconPath: 'assets/agents/$name/${index + 1}.webp',
        type: type,
        index: index,
        abilityData:
            BaseAbility(iconPath: 'assets/agents/$name/${index + 1}.webp'),
      ),
    );
  }

  static AbilityInfo _fallbackAbility(AgentType type) {
    final agent = agents[type];
    if (agent != null && agent.abilities.isNotEmpty) {
      return agent.abilities.first;
    }
    if (agents.isNotEmpty) {
      return agents.values.first.abilities.first;
    }
    return AbilityInfo(
      name: 'Unknown Ability',
      iconPath: 'assets/agents/Jett/1.webp',
      type: AgentType.jett,
      index: 0,
      abilityData: BaseAbility(iconPath: 'assets/agents/Jett/1.webp'),
    );
  }

  static AgentData? forType(AgentType type) {
    final agent = agents[type];
    if (agent != null) {
      return agent;
    }
    assert(() {
      debugPrint('Agent lookup failed for $type. Falling back.');
      return true;
    }());
    return agents.isNotEmpty ? agents.values.first : null;
  }
}

String _abilityIconPath(String agentName, int index) {
  return 'assets/agents/$agentName/${index + 1}.webp';
}

AbilitySpec _baseAbilitySpec(
  String agentName,
  int index, {
  String? name,
  String? iconPath,
}) {
  final resolvedIconPath = iconPath ?? _abilityIconPath(agentName, index);
  return AbilitySpec(
    name: name ?? 'Ability ${index + 1}',
    iconPath: resolvedIconPath,
    buildAbility: (spec) => BaseAbility(iconPath: spec.iconPath),
  );
}

AbilitySpec _imageAbilitySpec(
  String agentName,
  int index, {
  required String name,
  required String imagePath,
  required double size,
  String? iconPath,
}) {
  final resolvedIconPath = iconPath ?? _abilityIconPath(agentName, index);
  return AbilitySpec(
    name: name,
    iconPath: resolvedIconPath,
    buildAbility: (spec) => ImageAbility(imagePath: imagePath, size: size),
  );
}

AbilitySpec _circleAbilitySpec(
  String agentName,
  int index, {
  String? name,
  required double size,
  required Color outlineColor,
  bool? hasCenterDot,
  bool? hasPerimeter,
  Color? fillColor,
  int? opacity,
  double? perimeterSize,
  String? iconPath,
}) {
  final resolvedIconPath = iconPath ?? _abilityIconPath(agentName, index);
  return AbilitySpec(
    name: name ?? 'Ability ${index + 1}',
    iconPath: resolvedIconPath,
    buildAbility: (spec) => CircleAbility(
      iconPath: spec.iconPath,
      size: size,
      outlineColor: outlineColor,
      hasCenterDot: hasCenterDot,
      hasPerimeter: hasPerimeter,
      fillColor: fillColor,
      opacity: opacity,
      perimeterSize: perimeterSize,
    ),
  );
}

AbilitySpec _squareAbilitySpec(
  String agentName,
  int index, {
  String? name,
  required double width,
  required double height,
  required Color color,
  double distanceBetweenAOE = 0,
  bool isWall = false,
  bool hasTopborder = false,
  bool hasSideBorders = false,
  bool isTransparent = false,
  String? iconPath,
}) {
  final resolvedIconPath = iconPath ?? _abilityIconPath(agentName, index);
  return AbilitySpec(
    name: name ?? 'Ability ${index + 1}',
    iconPath: resolvedIconPath,
    buildAbility: (spec) => SquareAbility(
      width: width,
      height: height,
      iconPath: spec.iconPath,
      color: color,
      distanceBetweenAOE: distanceBetweenAOE,
      isWall: isWall,
      hasTopborder: hasTopborder,
      hasSideBorders: hasSideBorders,
      isTransparent: isTransparent,
    ),
  );
}

AbilitySpec _resizableSquareAbilitySpec(
  String agentName,
  int index, {
  String? name,
  required double width,
  required double height,
  required Color color,
  required double minLength,
  double distanceBetweenAOE = 0,
  bool isWall = false,
  bool hasTopborder = false,
  bool hasSideBorders = false,
  bool isTransparent = false,
  String? iconPath,
}) {
  final resolvedIconPath = iconPath ?? _abilityIconPath(agentName, index);
  return AbilitySpec(
    name: name ?? 'Ability ${index + 1}',
    iconPath: resolvedIconPath,
    buildAbility: (spec) => ResizableSquareAbility(
      width: width,
      height: height,
      iconPath: spec.iconPath,
      color: color,
      minLength: minLength,
      distanceBetweenAOE: distanceBetweenAOE,
      isWall: isWall,
      hasTopborder: hasTopborder,
      hasSideBorders: hasSideBorders,
      isTransparent: isTransparent,
    ),
  );
}

AbilitySpec _centerSquareAbilitySpec(
  String agentName,
  int index, {
  String? name,
  required double width,
  required double height,
  required Color color,
  String? iconPath,
}) {
  final resolvedIconPath = iconPath ?? _abilityIconPath(agentName, index);
  return AbilitySpec(
    name: name ?? 'Ability ${index + 1}',
    iconPath: resolvedIconPath,
    buildAbility: (spec) => CenterSquareAbility(
      width: width,
      height: height,
      iconPath: spec.iconPath,
      color: color,
    ),
  );
}

AbilitySpec _rotatableImageAbilitySpec(
  String agentName,
  int index, {
  String? name,
  required String imagePath,
  required double width,
  required double height,
  String? iconPath,
}) {
  final resolvedIconPath = iconPath ?? _abilityIconPath(agentName, index);
  return AbilitySpec(
    name: name ?? 'Ability ${index + 1}',
    iconPath: resolvedIconPath,
    buildAbility: (spec) => RotatableImageAbility(
      imagePath: imagePath,
      height: height,
      width: width,
    ),
  );
}

final List<AgentSpec> _agentSpecs = [
  AgentSpec(
    type: AgentType.jett,
    role: AgentRole.duelist,
    name: 'Jett',
    abilities: [
      _imageAbilitySpec(
        'Jett',
        0,
        name: 'Cloudburst',
        iconPath: 'assets/agents/Jett/1.webp',
        imagePath: 'assets/agents/Jett/Smoke.webp',
        size: 30,
      ),
      _baseAbilitySpec('Jett', 1),
      _baseAbilitySpec('Jett', 2),
      _baseAbilitySpec('Jett', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.raze,
    role: AgentRole.duelist,
    name: 'Raze',
    abilities: [
      _baseAbilitySpec('Raze', 0),
      _baseAbilitySpec('Raze', 1),
      _baseAbilitySpec('Raze', 2),
      _baseAbilitySpec('Raze', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.pheonix,
    role: AgentRole.duelist,
    name: 'Phoenix',
    abilities: [
      _squareAbilitySpec(
        'Phoenix',
        0,
        width: 5,
        height: 21 * AgentData.inGameMeters,
        color: Colors.redAccent,
        isWall: true,
      ),
      _baseAbilitySpec('Phoenix', 1),
      _circleAbilitySpec(
        'Phoenix',
        2,
        size: 4.5,
        outlineColor: Colors.redAccent,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Phoenix', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.astra,
    role: AgentRole.controller,
    name: 'Astra',
    abilities: [
      _circleAbilitySpec(
        'Astra',
        0,
        size: 4.75,
        outlineColor: Colors.purple,
      ),
      _circleAbilitySpec(
        'Astra',
        1,
        size: 4.75,
        outlineColor: Colors.purple,
      ),
      _imageAbilitySpec(
        'Astra',
        2,
        name: 'Nebula',
        iconPath: 'assets/agents/Astra/1.webp',
        imagePath: 'assets/agents/Astra/Smoke.webp',
        size: 4.75 * AgentData.inGameMetersDiameter,
      ),
      _centerSquareAbilitySpec(
        'Astra',
        3,
        width: 5,
        height: 1000,
        color: Colors.purple,
      ),
      _baseAbilitySpec(
        'Astra',
        4,
        name: 'Astra Star',
        iconPath: 'assets/agents/Astra/star.webp',
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.clove,
    role: AgentRole.controller,
    name: 'Clove',
    abilities: [
      _baseAbilitySpec('Clove', 0),
      _circleAbilitySpec(
        'Clove',
        1,
        size: 6,
        outlineColor: const Color.fromARGB(255, 251, 106, 154),
        hasCenterDot: true,
      ),
      _imageAbilitySpec(
        'Clove',
        2,
        name: 'Sky Smoke',
        iconPath: 'assets/agents/Clove/3.webp',
        imagePath: 'assets/agents/Clove/Smoke.webp',
        size: 4 * AgentData.inGameMetersDiameter,
      ),
      _baseAbilitySpec('Clove', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.breach,
    role: AgentRole.initiator,
    name: 'Breach',
    abilities: [
      _squareAbilitySpec(
        'Breach',
        0,
        width: 3 * AgentData.inGameMetersDiameter,
        height: 10 * AgentData.inGameMeters,
        color: Colors.orangeAccent,
      ),
      _baseAbilitySpec('Breach', 1),
      _resizableSquareAbilitySpec(
        'Breach',
        2,
        width: 7.5 * AgentData.inGameMeters,
        height: 56 * AgentData.inGameMeters,
        color: Colors.orangeAccent,
        minLength: 8 * AgentData.inGameMeters,
        distanceBetweenAOE: 8 * AgentData.inGameMeters,
      ),
      _squareAbilitySpec(
        'Breach',
        3,
        width: 18 * AgentData.inGameMeters,
        height: 32 * AgentData.inGameMeters,
        color: Colors.orangeAccent,
        distanceBetweenAOE: 8 * AgentData.inGameMeters,
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.iso,
    role: AgentRole.duelist,
    name: 'Iso',
    abilities: [
      _squareAbilitySpec(
        'Iso',
        0,
        width: 4.5 * AgentData.inGameMeters,
        height: 27.5 * AgentData.inGameMeters,
        color: Colors.indigo,
        hasTopborder: true,
        distanceBetweenAOE: 5 * AgentData.inGameMeters,
      ),
      _squareAbilitySpec(
        'Iso',
        1,
        width: 3 * AgentData.inGameMetersDiameter,
        height: 34.875 * AgentData.inGameMeters,
        color: Colors.indigo,
      ),
      _baseAbilitySpec('Iso', 2),
      _squareAbilitySpec(
        'Iso',
        3,
        width: 15 * AgentData.inGameMeters,
        height: 36 * AgentData.inGameMeters,
        color: Colors.indigo,
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.viper,
    role: AgentRole.controller,
    name: 'Viper',
    abilities: [
      _circleAbilitySpec(
        'Viper',
        0,
        size: 4.5,
        outlineColor: Colors.greenAccent,
        hasCenterDot: true,
      ),
      _imageAbilitySpec(
        'Viper',
        1,
        name: 'Sky Smoke',
        iconPath: 'assets/agents/Viper/2.webp',
        imagePath: 'assets/agents/Viper/Smoke.webp',
        size: 4.5 * AgentData.inGameMetersDiameter,
      ),
      _squareAbilitySpec(
        'Viper',
        2,
        width: 5,
        height: 60 * AgentData.inGameMeters,
        color: Colors.greenAccent,
        isWall: true,
      ),
      _baseAbilitySpec('Viper', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.deadlock,
    role: AgentRole.sentinel,
    name: 'Deadlock',
    abilities: [
      _circleAbilitySpec(
        'Deadlock',
        0,
        size: 6.5,
        outlineColor: Colors.blue,
        hasCenterDot: true,
      ),
      _squareAbilitySpec(
        'Deadlock',
        1,
        width: 8 * AgentData.inGameMeters,
        height: 9 * AgentData.inGameMeters,
        color: Colors.blue,
      ),
      _baseAbilitySpec('Deadlock', 2),
      _baseAbilitySpec('Deadlock', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.yoru,
    role: AgentRole.duelist,
    name: 'Yoru',
    abilities: [
      _baseAbilitySpec('Yoru', 0),
      _baseAbilitySpec('Yoru', 1),
      _baseAbilitySpec('Yoru', 2),
      _baseAbilitySpec('Yoru', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.sova,
    role: AgentRole.initiator,
    name: 'Sova',
    abilities: [
      _baseAbilitySpec('Sova', 0),
      _circleAbilitySpec(
        'Sova',
        1,
        size: 4,
        outlineColor: const Color.fromARGB(255, 1, 131, 237),
        hasCenterDot: true,
      ),
      _circleAbilitySpec(
        'Sova',
        2,
        size: 30,
        outlineColor: const Color.fromARGB(255, 1, 131, 237),
        hasCenterDot: true,
      ),
      _squareAbilitySpec(
        'Sova',
        3,
        width: 1.76 * AgentData.inGameMetersDiameter,
        height: 66 * AgentData.inGameMeters,
        color: const Color.fromARGB(255, 1, 131, 237),
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.skye,
    role: AgentRole.initiator,
    name: 'Skye',
    abilities: [
      _circleAbilitySpec(
        'Skye',
        0,
        size: 18,
        outlineColor: Colors.green,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Skye', 1),
      _baseAbilitySpec('Skye', 2),
      _baseAbilitySpec('Skye', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.kayo,
    role: AgentRole.initiator,
    name: 'Kayo',
    abilities: [
      _circleAbilitySpec(
        'Kayo',
        0,
        size: 4,
        outlineColor: const Color(0xFF8C06A3),
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Kayo', 1),
      _circleAbilitySpec(
        'Kayo',
        2,
        size: 15,
        outlineColor: const Color.fromARGB(255, 106, 14, 182),
        hasCenterDot: true,
      ),
      _circleAbilitySpec(
        'Kayo',
        3,
        size: 42.5,
        outlineColor: const Color(0xFF8C06A3),
        hasCenterDot: true,
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.killjoy,
    role: AgentRole.sentinel,
    name: 'Killjoy',
    abilities: [
      _circleAbilitySpec(
        'Killjoy',
        0,
        size: 5.5,
        outlineColor: const Color(0xFF6A0EB6),
        hasCenterDot: true,
      ),
      _circleAbilitySpec(
        'Killjoy',
        1,
        size: 40,
        outlineColor: Colors.white,
        hasCenterDot: true,
        hasPerimeter: true,
        perimeterSize: 54.48,
        fillColor: const Color.fromARGB(255, 106, 14, 182),
      ),
      _circleAbilitySpec(
        'Killjoy',
        2,
        size: 40,
        outlineColor: Colors.white.withAlpha(100),
        hasCenterDot: true,
        opacity: 0,
        fillColor: Colors.transparent,
      ),
      _circleAbilitySpec(
        'Killjoy',
        3,
        size: 32.5,
        outlineColor: const Color(0xFF6A0EB6),
        hasCenterDot: true,
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.brimstone,
    role: AgentRole.controller,
    name: 'Brimstone',
    abilities: [
      _circleAbilitySpec(
        'Brimstone',
        0,
        size: 6,
        outlineColor: const Color.fromARGB(255, 97, 253, 131),
        hasCenterDot: true,
      ),
      _circleAbilitySpec(
        'Brimstone',
        1,
        size: 4.5,
        outlineColor: Colors.red,
        hasCenterDot: true,
      ),
      _imageAbilitySpec(
        'Brimstone',
        2,
        name: 'Sky Smoke',
        iconPath: 'assets/agents/Brimstone/3.webp',
        imagePath: 'assets/agents/Brimstone/Smoke.webp',
        size: 4.15 * AgentData.inGameMetersDiameter,
      ),
      _circleAbilitySpec(
        'Brimstone',
        3,
        size: 9,
        outlineColor: Colors.red,
        hasCenterDot: true,
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.cypher,
    role: AgentRole.sentinel,
    name: 'Cypher',
    abilities: [
      _resizableSquareAbilitySpec(
        'Cypher',
        0,
        width: 3,
        height: 15 * AgentData.inGameMeters,
        color: Colors.white,
        minLength: AgentData.inGameMeters * 1,
        isWall: true,
      ),
      _circleAbilitySpec(
        'Cypher',
        1,
        size: 3.72,
        outlineColor: Colors.white,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Cypher', 2),
      _baseAbilitySpec('Cypher', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.chamber,
    role: AgentRole.sentinel,
    name: 'Chamber',
    abilities: [
      _circleAbilitySpec(
        'Chamber',
        0,
        size: 10,
        outlineColor: Colors.amber,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Chamber', 1),
      _circleAbilitySpec(
        'Chamber',
        2,
        size: 18,
        outlineColor: Colors.amber,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Chamber', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.fade,
    role: AgentRole.initiator,
    name: 'Fade',
    abilities: [
      _baseAbilitySpec('Fade', 0),
      _circleAbilitySpec(
        'Fade',
        1,
        size: 6.58,
        outlineColor: const Color(0xFF680A79),
        hasCenterDot: true,
      ),
      _circleAbilitySpec(
        'Fade',
        2,
        size: 30,
        outlineColor: const Color(0xFF680A79),
        hasCenterDot: true,
        opacity: 0,
      ),
      _squareAbilitySpec(
        'Fade',
        3,
        width: 20 * AgentData.inGameMeters,
        height: 40 * AgentData.inGameMeters,
        color: const Color(0xFF680A79),
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.gekko,
    role: AgentRole.initiator,
    name: 'Gekko',
    abilities: [
      _circleAbilitySpec(
        'Gekko',
        0,
        size: 6.2,
        outlineColor: Colors.greenAccent,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Gekko', 1),
      _baseAbilitySpec('Gekko', 2),
      _baseAbilitySpec('Gekko', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.harbor,
    role: AgentRole.controller,
    name: 'Harbor',
    abilities: [
      _circleAbilitySpec(
        'Harbor',
        0,
        size: 6,
        outlineColor: Colors.lightBlue,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Harbor', 1),
      _imageAbilitySpec(
        'Harbor',
        2,
        name: 'Sky Smoke',
        iconPath: 'assets/agents/Harbor/3.webp',
        imagePath: 'assets/agents/Harbor/Smoke.webp',
        size: 4.5 * AgentData.inGameMetersDiameter,
      ),
      _squareAbilitySpec(
        'Harbor',
        3,
        width: 20 * AgentData.inGameMeters,
        height: 40 * AgentData.inGameMeters,
        color: Colors.lightBlue,
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.neon,
    role: AgentRole.duelist,
    name: 'Neon',
    abilities: [
      _squareAbilitySpec(
        'Neon',
        0,
        width: 3.5 * AgentData.inGameMeters,
        height: 45 * AgentData.inGameMeters,
        color: Colors.blueAccent,
        hasSideBorders: true,
        isTransparent: true,
      ),
      _circleAbilitySpec(
        'Neon',
        1,
        size: 5,
        outlineColor: Colors.blue,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Neon', 2),
      _baseAbilitySpec('Neon', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.omen,
    role: AgentRole.controller,
    name: 'Omen',
    abilities: [
      _baseAbilitySpec('Omen', 0),
      _squareAbilitySpec(
        'Omen',
        1,
        width: 4.3 * AgentData.inGameMetersDiameter,
        height: 25 * AgentData.inGameMeters,
        color: Colors.deepPurple,
      ),
      _imageAbilitySpec(
        'Omen',
        2,
        name: 'Smoke',
        iconPath: 'assets/agents/Omen/3.webp',
        imagePath: 'assets/agents/Omen/Smoke.webp',
        size: 4.1 * AgentData.inGameMetersDiameter,
      ),
      _baseAbilitySpec('Omen', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.reyna,
    role: AgentRole.duelist,
    name: 'Reyna',
    abilities: [
      _baseAbilitySpec('Reyna', 0),
      _baseAbilitySpec('Reyna', 1),
      _baseAbilitySpec('Reyna', 2),
      _baseAbilitySpec('Reyna', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.sage,
    role: AgentRole.sentinel,
    name: 'Sage',
    abilities: [
      _rotatableImageAbilitySpec(
        'Sage',
        0,
        imagePath: 'assets/agents/Sage/wall.webp',
        height: 10.4 * AgentData.inGameMeters,
        width: 1.5 * AgentData.inGameMeters,
      ),
      _circleAbilitySpec(
        'Sage',
        1,
        size: 6.5,
        outlineColor: Colors.blueAccent,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Sage', 2),
      _baseAbilitySpec('Sage', 3),
    ],
  ),
  AgentSpec(
    type: AgentType.vyse,
    role: AgentRole.sentinel,
    name: 'Vyse',
    abilities: [
      _squareAbilitySpec(
        'Vyse',
        0,
        width: 1 * AgentData.inGameMeters,
        height: 12 * AgentData.inGameMeters,
        color: Colors.deepPurple,
      ),
      _circleAbilitySpec(
        'Vyse',
        1,
        size: 6.25,
        outlineColor: Colors.deepPurple,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Vyse', 2),
      _circleAbilitySpec(
        'Vyse',
        3,
        size: 32.5,
        outlineColor: Colors.deepPurple,
        hasCenterDot: true,
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.tejo,
    role: AgentRole.initiator,
    name: 'Tejo',
    abilities: [
      _circleAbilitySpec(
        'Tejo',
        0,
        size: 16,
        outlineColor: Colors.orangeAccent,
        hasCenterDot: true,
      ),
      _circleAbilitySpec(
        'Tejo',
        1,
        size: 5.25,
        outlineColor: Colors.orangeAccent,
        hasCenterDot: true,
      ),
      _circleAbilitySpec(
        'Tejo',
        2,
        size: 4.5,
        outlineColor: Colors.orangeAccent,
        hasCenterDot: true,
      ),
      _squareAbilitySpec(
        'Tejo',
        3,
        width: 10 * AgentData.inGameMeters,
        height: 32 * AgentData.inGameMeters,
        color: Colors.orangeAccent,
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.waylay,
    role: AgentRole.duelist,
    name: 'Waylay',
    abilities: [
      _circleAbilitySpec(
        'Waylay',
        0,
        size: 5,
        outlineColor: Colors.deepPurpleAccent,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Waylay', 1),
      _baseAbilitySpec('Waylay', 2),
      _squareAbilitySpec(
        'Waylay',
        3,
        width: 13.5 * AgentData.inGameMeters,
        height: 36 * AgentData.inGameMeters,
        color: Colors.deepPurpleAccent,
        distanceBetweenAOE: 3 * AgentData.inGameMeters,
      ),
    ],
  ),
  AgentSpec(
    type: AgentType.veto,
    role: AgentRole.sentinel,
    name: 'Veto',
    abilities: [
      _circleAbilitySpec(
        'Veto',
        0,
        size: 24,
        outlineColor: Colors.lightBlueAccent,
        hasCenterDot: true,
      ),
      _circleAbilitySpec(
        'Veto',
        1,
        size: 6.58,
        outlineColor: Colors.lightBlueAccent,
        hasCenterDot: true,
      ),
      _circleAbilitySpec(
        'Veto',
        2,
        size: 18,
        outlineColor: Colors.lightBlueAccent,
        hasCenterDot: true,
      ),
      _baseAbilitySpec('Veto', 3),
    ],
  ),
];
