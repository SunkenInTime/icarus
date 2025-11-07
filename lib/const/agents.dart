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

enum AgentRole { controller, duelist, initiator, sentinel }

const Map<AgentRole, String> agentRoleNames = {
  AgentRole.controller: 'controller',
  AgentRole.duelist: 'duelist',
  AgentRole.initiator: 'initiator',
  AgentRole.sentinel: 'sentinel',
};

abstract class DraggableData {}

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
    final agentEntry = AgentData.agents[type];
    if (agentEntry != null &&
        index >= 0 &&
        index < agentEntry.abilities.length) {
      return agentEntry.abilities[index].abilityData;
    }
    return null;
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
    final ability = AgentData.agents[agentType]?.abilities[index];

    return ability!;
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
  List<AbilityInfo> abilities;
  final String name;
  final String iconPath;

  static const double inGameMeters = 5.5;
  // static const double inGameMeters = 6;

  static const double inGameMetersDiameter = inGameMeters * 2;
  AgentData({
    required this.type,
    required this.role,
    required this.name,
  })  : iconPath = 'assets/agents/$name/icon.webp',
        abilities = List.generate(
          4,
          (index) => AbilityInfo(
            name: 'Ability ${index + 1}', // You can override this later
            iconPath: 'assets/agents/$name/${index + 1}.webp',
            type: type,
            index: index,
            abilityData:
                BaseAbility(iconPath: 'assets/agents/$name/${index + 1}.webp'),
          ),
        );

  static Map<AgentType, AgentData> agents = {
    AgentType.jett: AgentData(
      type: AgentType.jett,
      role: AgentRole.duelist,
      name: "Jett",
    )..abilities[0] =
          // Override the default abilities
          AbilityInfo(
        type: AgentType.jett,
        index: 0,
        name: "Cloudburst",
        iconPath: 'assets/agents/Jett/1.webp',
        abilityData:
            ImageAbility(imagePath: 'assets/agents/Jett/Smoke.webp', size: 30),
      ),
    AgentType.raze: AgentData(
      type: AgentType.raze,
      role: AgentRole.duelist,
      name: "Raze",
    ),
    AgentType.pheonix: (() {
      final agent = AgentData(
        type: AgentType.pheonix,
        role: AgentRole.duelist,
        name: "Phoenix",
      );
      agent.abilities.first.abilityData = SquareAbility(
        width: 5,
        height: 21 * inGameMeters,
        isWall: true,
        iconPath: agent.abilities.first.iconPath,
        color: Colors.redAccent,
      );
      agent.abilities[2].abilityData = CircleAbility(
        iconPath: agent.abilities[2].iconPath,
        size: 4.5,
        outlineColor: Colors.redAccent,
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.astra: (() {
      final agent = AgentData(
        type: AgentType.astra,
        role: AgentRole.controller,
        name: "Astra",
      )..abilities[2] = AbilityInfo(
          type: AgentType.astra,
          index: 2,
          name: "Nebula",
          iconPath: 'assets/agents/Astra/1.webp',
          abilityData: ImageAbility(
            imagePath: 'assets/agents/Astra/Smoke.webp',
            size: 4.75 * inGameMetersDiameter,
          ),
        );

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 4.75,
        outlineColor: Colors.purple,
      );

      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 4.75,
        outlineColor: Colors.purple,
      );

      agent.abilities[3].abilityData = CenterSquareAbility(
        width: 5,
        height: 1000,
        iconPath: agent.abilities[3].iconPath,
        color: Colors.purple,
      );

      final astraStar = AbilityInfo(
        type: AgentType.astra,
        index: 4,
        name: "Astra Star",
        iconPath: 'assets/agents/Astra/star.webp',
        abilityData: BaseAbility(iconPath: 'assets/agents/Astra/star.webp'),
      );

      agent.abilities.add(astraStar);

      return agent;
    })(),
    AgentType.breach: (() {
      final agent = AgentData(
        type: AgentType.breach,
        role: AgentRole.initiator,
        name: "Breach",
      );
      agent.abilities.first.abilityData = SquareAbility(
        width: 3 * inGameMetersDiameter,
        height: 10 * inGameMeters,
        iconPath: agent.abilities.first.iconPath,
        color: Colors.orangeAccent,
      );

      agent.abilities[2].abilityData = ResizableSquareAbility(
        width: 7.5 * inGameMeters,
        height: 56 * inGameMeters,
        iconPath: agent.abilities[2].iconPath,
        color: Colors.orangeAccent,
        minLength: 8 * inGameMeters,
        distanceBetweenAOE: 8 * inGameMeters,
      );

      agent.abilities.last.abilityData = SquareAbility(
        width: 18 * inGameMeters,
        height: 32 * inGameMeters,
        iconPath: agent.abilities.last.iconPath,
        color: Colors.orangeAccent,
        distanceBetweenAOE: 8 * inGameMeters,
      );

      return agent;
    })(),
    AgentType.viper: (() {
      final agent = AgentData(
        type: AgentType.viper,
        role: AgentRole.controller,
        name: "Viper",
      )..abilities[1] = AbilityInfo(
          type: AgentType.viper,
          index: 1,
          name: "Sky Smoke",
          iconPath: 'assets/agents/Viper/2.webp',
          abilityData: ImageAbility(
            imagePath: 'assets/agents/Viper/Smoke.webp',
            size: 4.5 * inGameMetersDiameter,
          ),
        );

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 4.5,
        outlineColor: Colors.greenAccent,
        hasCenterDot: true,
      );

      agent.abilities[2].abilityData = SquareAbility(
        width: 5,
        height: 60 * inGameMeters,
        isWall: true,
        iconPath: agent.abilities[2].iconPath,
        color: Colors.greenAccent,
      );

      return agent;
    })(),
    AgentType.yoru: AgentData(
      type: AgentType.yoru,
      role: AgentRole.duelist,
      name: "Yoru",
    ),
    AgentType.sova: (() {
      final agent = AgentData(
        type: AgentType.sova,
        role: AgentRole.initiator,
        name: "Sova",
      );

      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 4,
        outlineColor: const Color.fromARGB(255, 1, 131, 237),
        hasCenterDot: true,
      );

      agent.abilities[2].abilityData = CircleAbility(
        iconPath: agent.abilities[2].iconPath,
        size: 30,
        outlineColor: const Color.fromARGB(255, 1, 131, 237),
        hasCenterDot: true,
      );

      agent.abilities.last.abilityData = SquareAbility(
        width: 1.76 * inGameMetersDiameter,
        height: 66 * inGameMeters,
        iconPath: agent.abilities.last.iconPath,
        color: const Color.fromARGB(255, 1, 131, 237),
      );

      return agent;
    })(),
    AgentType.skye: (() {
      final agent = AgentData(
        type: AgentType.skye,
        role: AgentRole.initiator,
        name: "Skye",
      );

      // Heal
      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 18,
        outlineColor: Colors.green,
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.kayo: (() {
      AgentData agent = AgentData(
        type: AgentType.kayo,
        role: AgentRole.initiator,
        name: "Kayo",
      );

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 4,
        outlineColor: const Color(0xFF8C06A3),
        hasCenterDot: true,
      );

      // Ultimate
      agent.abilities[3].abilityData = CircleAbility(
        iconPath: agent.abilities[3].iconPath,
        size: 42.5,
        outlineColor: const Color(0xFF8C06A3),
        hasCenterDot: true,
      );

      agent.abilities[2].abilityData = CircleAbility(
        iconPath: agent.abilities[2].iconPath,
        size: 15,
        outlineColor: const Color.fromARGB(255, 106, 14, 182),
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.killjoy: (() {
      AgentData agent = AgentData(
        type: AgentType.killjoy,
        role: AgentRole.sentinel,
        name: "Killjoy",
      );

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 4.5,
        outlineColor: const Color(0xFF6A0EB6),
        hasCenterDot: true,
      );

      // Ultimate
      agent.abilities[3].abilityData = CircleAbility(
        iconPath: agent.abilities[3].iconPath,
        size: 32.5,
        outlineColor: const Color(0xFF6A0EB6),
        hasCenterDot: true,
      );

      // Alarmbot
      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 40,
        outlineColor: Colors.white,
        hasCenterDot: true,
        hasPerimeter: true, // Previously isDouble
        perimeterSize: 54.48, // Previously innerSize
        fillColor:
            const Color.fromARGB(255, 106, 14, 182), // Previously innerColor
      );

      // Turret
      agent.abilities[2].abilityData = CircleAbility(
        iconPath: agent.abilities[2].iconPath,
        size: 40,
        outlineColor: Colors.white.withAlpha(100),
        hasCenterDot: true,
        opacity: 0,
        fillColor: Colors.transparent, // Previously innerColor
      );

      return agent;
    })(),
    AgentType.brimstone: (() {
      final agent = AgentData(
        type: AgentType.brimstone,
        role: AgentRole.controller,
        name: "Brimstone",
      )..abilities[2] = AbilityInfo(
          type: AgentType.brimstone,
          index: 2,
          name: "Sky Smoke",
          iconPath: 'assets/agents/Brimstone/3.webp',
          abilityData: ImageAbility(
            imagePath: 'assets/agents/Brimstone/Smoke.webp',
            size: 4.15 * inGameMetersDiameter,
          ),
        );

      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 4.5,
        outlineColor: Colors.red,
        hasCenterDot: true,
      );

      // Ultimate
      agent.abilities.last.abilityData = CircleAbility(
        iconPath: agent.abilities[3].iconPath,
        size: 9,
        outlineColor: Colors.red,
        hasCenterDot: true,
      );

      // Stim Beacon
      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities[0].iconPath,
        size: 6,
        outlineColor: const Color.fromARGB(255, 97, 253, 131),
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.cypher: (() {
      final agent = AgentData(
        type: AgentType.cypher,
        role: AgentRole.sentinel,
        name: "Cypher",
      );
      agent.abilities.first.abilityData = ResizableSquareAbility(
        width: 3,
        height: 15 * inGameMeters,
        iconPath: agent.abilities.first.iconPath,
        color: Colors.white,
        minLength: inGameMeters * 1,
        isWall: true,
      );
      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 3.72,
        outlineColor: Colors.white,
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.chamber: (() {
      final agent = AgentData(
        type: AgentType.chamber,
        role: AgentRole.sentinel,
        name: "Chamber",
      );

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 10,
        outlineColor: Colors.amber,
        hasCenterDot: true,
      );

      agent.abilities[2].abilityData = CircleAbility(
        iconPath: agent.abilities[2].iconPath,
        size: 18,
        outlineColor: Colors.amber,
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.fade: (() {
      final agent = AgentData(
        type: AgentType.fade,
        role: AgentRole.initiator,
        name: "Fade",
      );

      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 6.58,
        outlineColor: const Color(0xFF680A79),
        hasCenterDot: true,
      );

      agent.abilities[2].abilityData = CircleAbility(
        iconPath: agent.abilities[2].iconPath,
        size: 30,
        outlineColor: const Color(0xFF680A79),
        hasCenterDot: true,
        opacity: 0,
      );

      agent.abilities.last.abilityData = SquareAbility(
        width: 20 * inGameMeters,
        height: 40 * inGameMeters,
        iconPath: agent.abilities.last.iconPath,
        color: const Color(0xFF680A79),
      );

      return agent;
    })(),
    AgentType.neon: (() {
      final agent = AgentData(
        type: AgentType.neon,
        role: AgentRole.duelist,
        name: "Neon",
      );

      agent.abilities.first.abilityData = SquareAbility(
        width: 3.5 * inGameMeters,
        height: 45 * inGameMeters,
        iconPath: agent.abilities.first.iconPath,
        color: Colors.blueAccent,
        hasSideBorders: true,
        isTransparent: true,
      );
      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 5,
        outlineColor: Colors.blue,
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.omen: (() {
      final agent = AgentData(
        type: AgentType.omen,
        role: AgentRole.controller,
        name: "Omen",
      )..abilities[2] = AbilityInfo(
          type: AgentType.omen,
          index: 2,
          name: "Smoke",
          iconPath: 'assets/agents/Omen/3.webp',
          abilityData: ImageAbility(
            imagePath: 'assets/agents/Omen/Smoke.webp',
            size: 4.1 * inGameMetersDiameter,
          ),
        );

      agent.abilities[1].abilityData = SquareAbility(
        width: 4.3 * inGameMetersDiameter,
        height: 25 * inGameMeters,
        iconPath: agent.abilities[1].iconPath,
        color: Colors.deepPurple,
      );

      return agent;
    })(),
    AgentType.reyna: (() {
      final agent = AgentData(
        type: AgentType.reyna,
        role: AgentRole.duelist,
        name: "Reyna",
      );
      return agent;
    })(),
    AgentType.sage: (() {
      final agent = AgentData(
        type: AgentType.sage,
        role: AgentRole.sentinel,
        name: "Sage",
      );

      agent.abilities.first.abilityData = RotatableImageAbility(
        imagePath: "assets/agents/Sage/wall.webp",
        height: 10.4 * inGameMeters,
        width: 1.5 * inGameMeters,
      );

      //TODO: Figure out the radius of the orb
      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 6.5,
        outlineColor: Colors.blueAccent,
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.clove: (() {
      final agent = AgentData(
        type: AgentType.clove,
        role: AgentRole.controller,
        name: "Clove",
      )..abilities[2] = AbilityInfo(
          type: AgentType.brimstone,
          index: 2,
          name: "Sky Smoke",
          iconPath: 'assets/agents/Clove/3.webp',
          abilityData: ImageAbility(
            imagePath: 'assets/agents/Clove/Smoke.webp',
            size: 4 * inGameMetersDiameter,
          ),
        );

      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 6,
        outlineColor: const Color.fromARGB(255, 251, 106, 154),
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.iso: (() {
      final agent = AgentData(
        type: AgentType.iso,
        role: AgentRole.duelist,
        name: "Iso",
      );

      agent.abilities.first.abilityData = SquareAbility(
        width: 4.5 * inGameMeters,
        height: 27.5 * inGameMeters,
        iconPath: agent.abilities.first.iconPath,
        color: Colors.indigo,
        hasTopborder: true,
        distanceBetweenAOE: 5 * inGameMeters,
      );

      agent.abilities[1].abilityData = SquareAbility(
        width: 3 * inGameMetersDiameter,
        height: 34.875 * inGameMeters,
        iconPath: agent.abilities[1].iconPath,
        color: Colors.indigo,
      );

      agent.abilities[3].abilityData = SquareAbility(
        width: 15 * inGameMeters,
        height: 36 * inGameMeters,
        iconPath: agent.abilities[3].iconPath,
        color: Colors.indigo,
      );

      return agent;
    })(),
    AgentType.deadlock: (() {
      final agent = AgentData(
        type: AgentType.deadlock,
        role: AgentRole.sentinel,
        name: "Deadlock",
      );

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 6.5,
        outlineColor: Colors.blue,
        hasCenterDot: true,
      );

      agent.abilities[1].abilityData = SquareAbility(
        width: 8 * inGameMeters,
        height: 9 * inGameMeters,
        iconPath: agent.abilities[1].iconPath,
        color: Colors.blue,
      );

      return agent;
    })(),
    AgentType.gekko: (() {
      final agent = AgentData(
        type: AgentType.gekko,
        role: AgentRole.initiator,
        name: "Gekko",
      );

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 6.2,
        outlineColor: Colors.greenAccent,
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.harbor: (() {
      final agent = AgentData(
        type: AgentType.harbor,
        role: AgentRole.controller,
        name: "Harbor",
      )..abilities[1] = AbilityInfo(
          type: AgentType.brimstone,
          index: 1,
          name: "Sky Smoke",
          iconPath: 'assets/agents/Harbor/2.webp',
          abilityData: ImageAbility(
            imagePath: 'assets/agents/Harbor/Smoke.webp',
            size: 4 * inGameMetersDiameter,
          ),
        );

      agent.abilities.first.abilityData = ResizableSquareAbility(
        width: 9.75 * inGameMeters,
        height: 35 * inGameMeters,
        minLength: 5 * inGameMeters,
        iconPath: agent.abilities.first.iconPath,
        hasTopborder: true,
        color: Colors.lightBlue,
      );

      agent.abilities.last.abilityData = CircleAbility(
        iconPath: agent.abilities.last.iconPath,
        size: 21.25,
        outlineColor: Colors.lightBlue,
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.vyse: (() {
      final agent = AgentData(
        type: AgentType.vyse,
        role: AgentRole.sentinel,
        name: "Vyse",
      );

      agent.abilities.first.abilityData = SquareAbility(
        width: 1 * inGameMeters,
        height: 12 * inGameMeters,
        iconPath: agent.abilities.first.iconPath,
        color: Colors.deepPurple,
      );

      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 6.25,
        outlineColor: Colors.deepPurple,
        hasCenterDot: true,
      );

      agent.abilities.last.abilityData = CircleAbility(
        iconPath: agent.abilities.last.iconPath,
        size: 32.5,
        outlineColor: Colors.deepPurple,
        hasCenterDot: true,
      );

      return agent;
    })(),
    AgentType.tejo: (() {
      final agent = AgentData(
        type: AgentType.tejo,
        role: AgentRole.initiator,
        name: "Tejo",
      );

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 30,
        outlineColor: Colors.orangeAccent,
        hasCenterDot: true,
      );

      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 5.25,
        outlineColor: Colors.orangeAccent,
        hasCenterDot: true,
      );

      agent.abilities[2].abilityData = CircleAbility(
        iconPath: agent.abilities[2].iconPath,
        size: 4.5,
        outlineColor: Colors.orangeAccent,
        hasCenterDot: true,
      );

      agent.abilities.last.abilityData = SquareAbility(
        width: 10 * inGameMeters,
        height: 32 * inGameMeters,
        iconPath: agent.abilities.last.iconPath,
        color: Colors.orangeAccent,
      );

      return agent;
    })(),
    AgentType.waylay: (() {
      final agent = AgentData(
          type: AgentType.waylay, role: AgentRole.duelist, name: "Waylay");

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 5,
        outlineColor: Colors.deepPurpleAccent,
        hasCenterDot: true,
      );

      agent.abilities.last.abilityData = SquareAbility(
        width: 13.5 * inGameMeters,
        height: 36 * inGameMeters,
        iconPath: agent.abilities.last.iconPath,
        distanceBetweenAOE: 3 * inGameMeters,
        color: Colors.deepPurpleAccent,
      );

      return agent;
    })(),
    AgentType.veto: (() {
      final agent = AgentData(
          type: AgentType.veto, role: AgentRole.sentinel, name: "Veto");

      agent.abilities.first.abilityData = CircleAbility(
        iconPath: agent.abilities.first.iconPath,
        size: 24,
        outlineColor: Colors.lightBlueAccent,
        hasCenterDot: true,
      );

      agent.abilities[1].abilityData = CircleAbility(
        iconPath: agent.abilities[1].iconPath,
        size: 6.58,
        outlineColor: Colors.lightBlueAccent,
        hasCenterDot: true,
      );

      agent.abilities[2].abilityData = CircleAbility(
        iconPath: agent.abilities[2].iconPath,
        size: 18,
        outlineColor: Colors.lightBlueAccent,
        hasCenterDot: true,
      );

      return agent;
    })(),
  };
}
