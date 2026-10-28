// Desktop 4.6.3's adapters for the typeIds this build writes by hand, copied
// verbatim from the desktop-stable-v4.6.3+103 tag (only the class names
// changed), plus its WeaponTypeAdapter and AgentTypeAdapter, which this
// build extended with the Warden and Hush. Each of those two gains only the
// write case Dart's exhaustive switch demands for the new value, which
// throws. Every other adapter is unchanged since that release. Rollback
// tests decode with these to prove 4.6.3 opens, and keeps, what this build
// saves. Never edit them to match this build.

// ignore_for_file: deprecated_member_use_from_same_package

import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/hive/hive_adapters.dart'
    show
        ellipseDrawingAdapterTypeId,
        freeDrawingAdapterTypeId,
        lineAdapterTypeId,
        rectangleDrawingAdapterTypeId;
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

class Desktop463PlacedAgentAdapter extends TypeAdapter<PlacedAgent> {
  @override
  final typeId = 2;

  @override
  PlacedAgent read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlacedAgent(
      type: fields[0] as AgentType,
      position: fields[4] as Offset,
      id: fields[2] as String,
      isAlly: fields[1] == null ? true : fields[1] as bool,
      lineUpID: fields[5] as String?,
      state: fields[6] == null ? AgentState.none : fields[6] as AgentState,
      weapon: fields[7] == null ? WeaponType.none : fields[7] as WeaponType,
    )..isDeleted = fields[3] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedAgent obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.isAlly)
      ..writeByte(2)
      ..write(obj.id)
      ..writeByte(3)
      ..write(obj.isDeleted)
      ..writeByte(4)
      ..write(obj.position)
      ..writeByte(5)
      ..write(obj.lineUpID)
      ..writeByte(6)
      ..write(obj.state)
      ..writeByte(7)
      ..write(obj.weapon);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Desktop463PlacedAgentAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class Desktop463PlacedAbilityAdapter extends TypeAdapter<PlacedAbility> {
  @override
  final typeId = 3;

  @override
  PlacedAbility read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlacedAbility(
      data: fields[0] as AbilityInfo,
      position: fields[5] as Offset,
      id: fields[3] as String,
      isAlly: fields[1] == null ? true : fields[1] as bool,
      length: fields[6] == null ? 0 : (fields[6] as num).toDouble(),
      lineUpID: fields[7] as String?,
      rotation: fields[2] == null ? 0 : (fields[2] as num).toDouble(),
      visualState: fields[9] == null
          ? const AbilityVisualState()
          : fields[9] as AbilityVisualState,
      armLengthsMeters: (fields[8] as List?)?.cast<double>(),
    )..isDeleted = fields[4] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedAbility obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.data)
      ..writeByte(1)
      ..write(obj.isAlly)
      ..writeByte(2)
      ..write(obj.rotation)
      ..writeByte(3)
      ..write(obj.id)
      ..writeByte(4)
      ..write(obj.isDeleted)
      ..writeByte(5)
      ..write(obj.position)
      ..writeByte(6)
      ..write(obj.length)
      ..writeByte(7)
      ..write(obj.lineUpID)
      ..writeByte(8)
      ..write(obj.armLengthsMeters)
      ..writeByte(9)
      ..write(obj.visualState);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Desktop463PlacedAbilityAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class Desktop463StrategyPageAdapter extends TypeAdapter<StrategyPage> {
  @override
  final typeId = 20;

  @override
  StrategyPage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return StrategyPage(
      id: fields[0] as String,
      name: fields[2] as String,
      isAutoNamed: fields[14] as bool?,
      drawingData: (fields[3] as List).cast<DrawingElement>(),
      agentData: (fields[4] as List).cast<PlacedAgentNode>(),
      abilityData: (fields[5] as List).cast<PlacedAbility>(),
      textData: (fields[6] as List).cast<PlacedText>(),
      imageData: (fields[7] as List).cast<PlacedImage>(),
      utilityData: (fields[8] as List).cast<PlacedUtility>(),
      sortIndex: (fields[1] as num).toInt(),
      isAttack: fields[9] as bool,
      settings: fields[10] as StrategySettings,
      lineUpOrigins: fields[15] == null
          ? const []
          : (fields[15] as List).cast<LineUpOrigin>(),
      lineUpLandings: fields[16] == null
          ? const []
          : (fields[16] as List).cast<LineUpLanding>(),
      lineUpLinks: fields[17] == null
          ? const []
          : (fields[17] as List).cast<LineUpLink>(),
      lineUpGroups: fields[12] == null
          ? const []
          : (fields[12] as List).cast<LineUpGroup>(),
      lineUps:
          fields[11] == null ? const [] : (fields[11] as List).cast<LineUp>(),
    );
  }

  @override
  void write(BinaryWriter writer, StrategyPage obj) {
    writer
      ..writeByte(17)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sortIndex)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.drawingData)
      ..writeByte(4)
      ..write(obj.agentData)
      ..writeByte(5)
      ..write(obj.abilityData)
      ..writeByte(6)
      ..write(obj.textData)
      ..writeByte(7)
      ..write(obj.imageData)
      ..writeByte(8)
      ..write(obj.utilityData)
      ..writeByte(9)
      ..write(obj.isAttack)
      ..writeByte(10)
      ..write(obj.settings)
      ..writeByte(11)
      ..write(obj.lineUps)
      ..writeByte(12)
      ..write(obj.lineUpGroups)
      ..writeByte(14)
      ..write(obj.isAutoNamed)
      ..writeByte(15)
      ..write(obj.lineUpOrigins)
      ..writeByte(16)
      ..write(obj.lineUpLandings)
      ..writeByte(17)
      ..write(obj.lineUpLinks);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Desktop463StrategyPageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class Desktop463FolderAdapter extends TypeAdapter<Folder> {
  @override
  final typeId = 17;

  @override
  Folder read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Folder(
      name: fields[0] as String,
      id: fields[1] as String,
      parentID: fields[2] as String?,
      dateCreated: fields[3] as DateTime,
      iconId: FolderIconRegistry.idForStoredValue(fields[4]),
      color: fields[5] as FolderColor? ?? FolderColor.red,
      customColor: switch (fields[6]) {
        final int colorValue => Color(colorValue),
        final Color color => color,
        null => null,
        _ => null,
      },
    );
  }

  @override
  void write(BinaryWriter writer, Folder obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.name)
      ..writeByte(1)
      ..write(obj.id)
      ..writeByte(2)
      ..write(obj.parentID)
      ..writeByte(3)
      ..write(obj.dateCreated)
      ..writeByte(4)
      ..write(obj.iconId)
      ..writeByte(5)
      ..write(obj.color)
      ..writeByte(6)
      ..write(obj.customColor?.toARGB32());
  }
}

class Desktop463FreeDrawingAdapter extends TypeAdapter<FreeDrawing> {
  @override
  final typeId = freeDrawingAdapterTypeId;

  @override
  FreeDrawing read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };

    return FreeDrawing(
      listOfPoints: (fields[0] as List?)?.cast<Offset>(),
      colorValue: _readDrawingHiveColorValue(
        fields,
        colorFieldIndex: 2,
        legacyColorValueFieldIndex: 12,
      ),
      thickness: fields[11] == null
          ? Settings.defaultStrokeThickness
          : (fields[11] as num).toDouble(),
      boundingBox: fields[6] as BoundingBox?,
      isDotted: fields[3] as bool,
      hasArrow: fields[4] as bool,
      id: fields[5] as String,
      showTraversalTime: fields[8] == null ? false : fields[8] as bool,
      traversalSpeedProfile: fields[9] == null
          ? TraversalSpeed.defaultProfile
          : fields[9] as TraversalSpeedProfile,
      cachedPolylineLengthUnits: (fields[10] as num?)?.toDouble(),
    );
  }

  @override
  void write(BinaryWriter writer, FreeDrawing obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.listOfPoints)
      ..writeByte(2)
      ..write(obj.colorValue)
      ..writeByte(3)
      ..write(obj.isDotted)
      ..writeByte(4)
      ..write(obj.hasArrow)
      ..writeByte(5)
      ..write(obj.id)
      ..writeByte(6)
      ..write(obj.boundingBox)
      ..writeByte(8)
      ..write(obj.showTraversalTime)
      ..writeByte(9)
      ..write(obj.traversalSpeedProfile)
      ..writeByte(10)
      ..write(obj.cachedPolylineLengthUnits)
      ..writeByte(11)
      ..write(obj.thickness);
  }
}

class Desktop463LineAdapter extends TypeAdapter<Line> {
  @override
  final typeId = lineAdapterTypeId;

  @override
  Line read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };

    return Line(
      lineStart: fields[0] as Offset,
      lineEnd: fields[1] as Offset,
      colorValue: _readDrawingHiveColorValue(
        fields,
        colorFieldIndex: 2,
        legacyColorValueFieldIndex: 10,
      ),
      thickness: fields[9] == null
          ? Settings.defaultStrokeThickness
          : (fields[9] as num).toDouble(),
      boundingBox: fields[6] as BoundingBox?,
      isDotted: fields[3] as bool,
      hasArrow: fields[4] as bool,
      id: fields[5] as String,
      showTraversalTime: fields[7] == null ? false : fields[7] as bool,
      traversalSpeedProfile: fields[8] == null
          ? TraversalSpeed.defaultProfile
          : fields[8] as TraversalSpeedProfile,
    );
  }

  @override
  void write(BinaryWriter writer, Line obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.lineStart)
      ..writeByte(1)
      ..write(obj.lineEnd)
      ..writeByte(2)
      ..write(obj.colorValue)
      ..writeByte(3)
      ..write(obj.isDotted)
      ..writeByte(4)
      ..write(obj.hasArrow)
      ..writeByte(5)
      ..write(obj.id)
      ..writeByte(6)
      ..write(obj.boundingBox)
      ..writeByte(7)
      ..write(obj.showTraversalTime)
      ..writeByte(8)
      ..write(obj.traversalSpeedProfile)
      ..writeByte(9)
      ..write(obj.thickness);
  }
}

class Desktop463RectangleDrawingAdapter extends TypeAdapter<RectangleDrawing> {
  @override
  final typeId = rectangleDrawingAdapterTypeId;

  @override
  RectangleDrawing read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };

    return RectangleDrawing(
      start: fields[0] as Offset,
      end: fields[1] as Offset,
      colorValue: _readDrawingHiveColorValue(
        fields,
        colorFieldIndex: 2,
        legacyColorValueFieldIndex: 8,
      ),
      thickness: fields[7] == null
          ? Settings.defaultStrokeThickness
          : (fields[7] as num).toDouble(),
      boundingBox: fields[6] as BoundingBox?,
      isDotted: fields[3] as bool,
      hasArrow: fields[4] as bool,
      id: fields[5] as String,
    );
  }

  @override
  void write(BinaryWriter writer, RectangleDrawing obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.start)
      ..writeByte(1)
      ..write(obj.end)
      ..writeByte(2)
      ..write(obj.colorValue)
      ..writeByte(3)
      ..write(obj.isDotted)
      ..writeByte(4)
      ..write(obj.hasArrow)
      ..writeByte(5)
      ..write(obj.id)
      ..writeByte(6)
      ..write(obj.boundingBox)
      ..writeByte(7)
      ..write(obj.thickness);
  }
}

class Desktop463EllipseDrawingAdapter extends TypeAdapter<EllipseDrawing> {
  @override
  final typeId = ellipseDrawingAdapterTypeId;

  @override
  EllipseDrawing read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };

    return EllipseDrawing(
      start: fields[0] as Offset,
      end: fields[1] as Offset,
      colorValue: _readDrawingHiveColorValue(
        fields,
        colorFieldIndex: 2,
        legacyColorValueFieldIndex: 8,
      ),
      thickness: fields[3] == null
          ? Settings.defaultStrokeThickness
          : (fields[3] as num).toDouble(),
      boundingBox: fields[7] as BoundingBox?,
      isDotted: fields[4] as bool,
      hasArrow: fields[5] as bool,
      id: fields[6] as String,
    );
  }

  @override
  void write(BinaryWriter writer, EllipseDrawing obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.start)
      ..writeByte(1)
      ..write(obj.end)
      ..writeByte(2)
      ..write(obj.colorValue)
      ..writeByte(3)
      ..write(obj.thickness)
      ..writeByte(4)
      ..write(obj.isDotted)
      ..writeByte(5)
      ..write(obj.hasArrow)
      ..writeByte(6)
      ..write(obj.id)
      ..writeByte(7)
      ..write(obj.boundingBox);
  }
}

class Desktop463WeaponTypeAdapter extends TypeAdapter<WeaponType> {
  @override
  final typeId = 38;

  @override
  WeaponType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return WeaponType.none;
      case 1:
        return WeaponType.classic;
      case 2:
        return WeaponType.shorty;
      case 3:
        return WeaponType.frenzy;
      case 4:
        return WeaponType.ghost;
      case 5:
        return WeaponType.bandit;
      case 6:
        return WeaponType.sheriff;
      case 7:
        return WeaponType.bulldog;
      case 8:
        return WeaponType.guardian;
      case 9:
        return WeaponType.phantom;
      case 10:
        return WeaponType.vandal;
      case 11:
        return WeaponType.bucky;
      case 12:
        return WeaponType.judge;
      case 13:
        return WeaponType.stinger;
      case 14:
        return WeaponType.spectre;
      case 15:
        return WeaponType.marshal;
      case 16:
        return WeaponType.outlaw;
      case 17:
        return WeaponType.operator;
      case 18:
        return WeaponType.ares;
      case 19:
        return WeaponType.odin;
      default:
        return WeaponType.none;
    }
  }

  @override
  void write(BinaryWriter writer, WeaponType obj) {
    switch (obj) {
      case WeaponType.none:
        writer.writeByte(0);
      case WeaponType.classic:
        writer.writeByte(1);
      case WeaponType.shorty:
        writer.writeByte(2);
      case WeaponType.frenzy:
        writer.writeByte(3);
      case WeaponType.ghost:
        writer.writeByte(4);
      case WeaponType.bandit:
        writer.writeByte(5);
      case WeaponType.sheriff:
        writer.writeByte(6);
      case WeaponType.bulldog:
        writer.writeByte(7);
      case WeaponType.guardian:
        writer.writeByte(8);
      case WeaponType.phantom:
        writer.writeByte(9);
      case WeaponType.vandal:
        writer.writeByte(10);
      case WeaponType.bucky:
        writer.writeByte(11);
      case WeaponType.judge:
        writer.writeByte(12);
      case WeaponType.stinger:
        writer.writeByte(13);
      case WeaponType.spectre:
        writer.writeByte(14);
      case WeaponType.marshal:
        writer.writeByte(15);
      case WeaponType.outlaw:
        writer.writeByte(16);
      case WeaponType.operator:
        writer.writeByte(17);
      case WeaponType.ares:
        writer.writeByte(18);
      case WeaponType.odin:
        writer.writeByte(19);
      // Not in 4.6.3, which can never hold one; only Dart's exhaustive
      // switch needs the case.
      case WeaponType.warden:
        throw StateError('Desktop 4.6.3 has no Warden');
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Desktop463WeaponTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class Desktop463AgentTypeAdapter extends TypeAdapter<AgentType> {
  @override
  final typeId = 7;

  @override
  AgentType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AgentType.jett;
      case 1:
        return AgentType.raze;
      case 2:
        return AgentType.pheonix;
      case 3:
        return AgentType.astra;
      case 4:
        return AgentType.clove;
      case 5:
        return AgentType.breach;
      case 6:
        return AgentType.iso;
      case 7:
        return AgentType.viper;
      case 8:
        return AgentType.deadlock;
      case 9:
        return AgentType.yoru;
      case 10:
        return AgentType.sova;
      case 11:
        return AgentType.skye;
      case 12:
        return AgentType.kayo;
      case 13:
        return AgentType.killjoy;
      case 14:
        return AgentType.brimstone;
      case 15:
        return AgentType.cypher;
      case 16:
        return AgentType.chamber;
      case 17:
        return AgentType.fade;
      case 18:
        return AgentType.gekko;
      case 19:
        return AgentType.harbor;
      case 20:
        return AgentType.neon;
      case 21:
        return AgentType.omen;
      case 22:
        return AgentType.reyna;
      case 23:
        return AgentType.sage;
      case 24:
        return AgentType.vyse;
      case 25:
        return AgentType.tejo;
      case 26:
        return AgentType.waylay;
      case 27:
        return AgentType.veto;
      case 28:
        return AgentType.miks;
      default:
        return AgentType.jett;
    }
  }

  @override
  void write(BinaryWriter writer, AgentType obj) {
    switch (obj) {
      case AgentType.jett:
        writer.writeByte(0);
      case AgentType.raze:
        writer.writeByte(1);
      case AgentType.pheonix:
        writer.writeByte(2);
      case AgentType.astra:
        writer.writeByte(3);
      case AgentType.clove:
        writer.writeByte(4);
      case AgentType.breach:
        writer.writeByte(5);
      case AgentType.iso:
        writer.writeByte(6);
      case AgentType.viper:
        writer.writeByte(7);
      case AgentType.deadlock:
        writer.writeByte(8);
      case AgentType.yoru:
        writer.writeByte(9);
      case AgentType.sova:
        writer.writeByte(10);
      case AgentType.skye:
        writer.writeByte(11);
      case AgentType.kayo:
        writer.writeByte(12);
      case AgentType.killjoy:
        writer.writeByte(13);
      case AgentType.brimstone:
        writer.writeByte(14);
      case AgentType.cypher:
        writer.writeByte(15);
      case AgentType.chamber:
        writer.writeByte(16);
      case AgentType.fade:
        writer.writeByte(17);
      case AgentType.gekko:
        writer.writeByte(18);
      case AgentType.harbor:
        writer.writeByte(19);
      case AgentType.neon:
        writer.writeByte(20);
      case AgentType.omen:
        writer.writeByte(21);
      case AgentType.reyna:
        writer.writeByte(22);
      case AgentType.sage:
        writer.writeByte(23);
      case AgentType.vyse:
        writer.writeByte(24);
      case AgentType.tejo:
        writer.writeByte(25);
      case AgentType.waylay:
        writer.writeByte(26);
      case AgentType.veto:
        writer.writeByte(27);
      case AgentType.miks:
        writer.writeByte(28);
      // Not in 4.6.3, which can never hold one; only Dart's exhaustive
      // switch needs the case.
      case AgentType.hush:
        throw StateError('Desktop 4.6.3 has no Hush');
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Desktop463AgentTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

int _readDrawingHiveColorValue(
  Map<int, dynamic> fields, {
  required int colorFieldIndex,
  int? legacyColorValueFieldIndex,
}) {
  final value = legacyColorValueFieldIndex == null
      ? fields[colorFieldIndex]
      : fields[legacyColorValueFieldIndex] ?? fields[colorFieldIndex];

  return switch (value) {
    final int colorValue => colorValue,
    final num colorValue => colorValue.toInt(),
    final Color color => color.toARGB32(),
    _ => 0xFFFFFFFF,
  };
}
