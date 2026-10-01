// ignore_for_file: unused_import, unnecessary_import

import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Offset;

import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

// Hand-written adapters own these typeIds. The generator drops yaml rows for
// types it does not generate, so reserving them is what keeps a future
// AdapterSpec from being handed one of them.
@GenerateAdapters([
  AdapterSpec<StrategyData>(),
  AdapterSpec<PlacedWidget>(),
  AdapterSpec<AbilityVisualState>(),
  AdapterSpec<PlacedText>(),
  AdapterSpec<PlacedImage>(),
  AdapterSpec<MapValue>(),
  AdapterSpec<AgentType>(),
  AdapterSpec<Offset>(),
  AdapterSpec<BoundingBox>(),
  AdapterSpec<StrategySettings>(),
  AdapterSpec<PlacedUtility>(),
  AdapterSpec<UtilityType>(),
  AdapterSpec<IconData>(),
  AdapterSpec<FolderColor>(),
  AdapterSpec<LineUp>(),
  AdapterSpec<LineUpGroup>(),
  AdapterSpec<LineUpItem>(),
  AdapterSpec<LineUpOrigin>(),
  AdapterSpec<LineUpLanding>(),
  AdapterSpec<LineUpLink>(),
  AdapterSpec<SimpleImageData>(),
  AdapterSpec<CloudMediaJobState>(),
  AdapterSpec<AgentState>(),
  AdapterSpec<TraversalSpeedProfile>(),
  AdapterSpec<MapThemePalette>(),
  AdapterSpec<MapThemeProfile>(),
  AdapterSpec<AppPreferences>(),
  AdapterSpec<PlacedViewConeAgent>(),
  AdapterSpec<PlacedCircleAgent>(),
  AdapterSpec<WeaponType>(),
], reservedTypeIds: {
  placedAgentAdapterTypeId,
  placedAbilityAdapterTypeId,
  abilityInfoAdapterTypeId,
  freeDrawingAdapterTypeId,
  lineAdapterTypeId,
  folderAdapterTypeId,
  strategyPageAdapterTypeId,
  rectangleDrawingAdapterTypeId,
  ellipseDrawingAdapterTypeId,
})
part 'hive_adapters.g.dart';

const int placedAgentAdapterTypeId = 2;
const int placedAbilityAdapterTypeId = 3;
const int abilityInfoAdapterTypeId = 9;
const int folderAdapterTypeId = 17;
const int freeDrawingAdapterTypeId = 11;
const int lineAdapterTypeId = 12;
const int strategyPageAdapterTypeId = 20;
const int rectangleDrawingAdapterTypeId = 24;
const int ellipseDrawingAdapterTypeId = 31;

/// Writes the record desktop 4.6.3 writes, so a library rolled back to that
/// release keeps every agent and firearm. Cloud builds before the main merge
/// left out field 7 when there was no firearm; reading defaults it.
class PlacedAgentAdapter extends TypeAdapter<PlacedAgent> {
  @override
  final typeId = placedAgentAdapterTypeId;

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
}

/// Writes the record desktop 4.6.3 writes, visual state in field 9. Cloud
/// builds before the main merge kept it as primitives in fields 10-14 instead;
/// reading prefers those when present.
class PlacedAbilityAdapter extends TypeAdapter<PlacedAbility> {
  @override
  final typeId = placedAbilityAdapterTypeId;

  @override
  PlacedAbility read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    final legacyVisualState = fields[9] as AbilityVisualState?;
    final visualState = AbilityVisualState(
      showRangeOutline:
          fields[10] as bool? ?? legacyVisualState?.showRangeOutline ?? true,
      showRangeFill:
          fields[11] as bool? ?? legacyVisualState?.showRangeFill ?? true,
      showInnerOutline:
          fields[12] as bool? ?? legacyVisualState?.showInnerOutline ?? true,
      showInnerFill:
          fields[13] as bool? ?? legacyVisualState?.showInnerFill ?? true,
      showVisionCone:
          fields[14] as bool? ?? legacyVisualState?.showVisionCone ?? true,
    );

    return PlacedAbility(
      data: fields[0] as AbilityInfo,
      position: fields[5] as Offset,
      id: fields[3] as String,
      isAlly: fields[1] == null ? true : fields[1] as bool,
      length: fields[6] == null ? 0.0 : (fields[6] as num).toDouble(),
      lineUpID: fields[7] as String?,
      rotation: fields[2] == null ? 0.0 : (fields[2] as num).toDouble(),
      visualState: visualState,
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
}

/// Writes the record desktop 4.6.3 writes, so a library rolled back to that
/// release opens with every drawing, agent, ability and lineup, and keeps them
/// when that release saves.
///
/// Cloud builds before the main merge wrote a 3.2.3-safe subset into the
/// legacy slots and the full page into JSON mirrors: agents at 13, drawings
/// at 18, the lineup graph at 19 and abilities at 20. Earlier still, drawings
/// at 15 and lineup groups at 16, which a String at 15 identifies. Reading
/// prefers any mirror present, so those pages load whole.
const int _pageAgentsJsonField = 13;
const int _pageDrawingsJsonField = 18;
const int _pageLineUpGraphJsonField = 19;
const int _pageAbilitiesJsonField = 20;

class StrategyPageAdapter extends TypeAdapter<StrategyPage> {
  @override
  final typeId = strategyPageAdapterTypeId;

  @override
  StrategyPage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    final isCloudLegacyLayout = fields[15] is String;
    final drawingsJson = (fields[_pageDrawingsJsonField] ??
        (isCloudLegacyLayout ? fields[15] : null)) as String?;
    final agentsJson = fields[_pageAgentsJsonField] as String?;
    final abilitiesJson = fields[_pageAbilitiesJsonField] as String?;
    final lineUpGraph = _readLineUpGraph(fields, isCloudLegacyLayout);

    return StrategyPage(
      id: fields[0] as String,
      name: fields[2] as String,
      isAutoNamed: fields[14] as bool?,
      drawingData: drawingsJson == null
          ? (fields[3] as List).cast<DrawingElement>()
          : DrawingProvider.fromJson(drawingsJson),
      agentData: agentsJson == null
          ? (fields[4] as List).cast<PlacedAgentNode>()
          : AgentProvider.fromJson(agentsJson),
      abilityData: abilitiesJson == null
          ? (fields[5] as List).cast<PlacedAbility>()
          : AbilityProvider.fromJson(abilitiesJson),
      textData: (fields[6] as List).cast<PlacedText>(),
      imageData: (fields[7] as List).cast<PlacedImage>(),
      utilityData: (fields[8] as List).cast<PlacedUtility>(),
      sortIndex: (fields[1] as num).toInt(),
      isAttack: fields[9] as bool,
      settings: fields[10] as StrategySettings,
      lineUpOrigins: lineUpGraph.origins,
      lineUpLandings: lineUpGraph.landings,
      lineUpLinks: lineUpGraph.links,
      lineUpGroups: fields[12] == null
          ? const []
          : (fields[12] as List).cast<LineUpGroup>(),
      lineUps:
          fields[11] == null ? const [] : (fields[11] as List).cast<LineUp>(),
    );
  }

  static LineUpGraph _readLineUpGraph(
    Map<int, dynamic> fields,
    bool isCloudLegacyLayout,
  ) {
    final graphJson = fields[_pageLineUpGraphJsonField] as String?;
    if (graphJson != null) return LineUpProvider.fromJson(graphJson);
    if (isCloudLegacyLayout) {
      final groupsJson = fields[16] as String?;
      return groupsJson == null
          ? LineUpGraph.empty
          : LineUpGraph.fromLegacyGroups(
              LineUpProvider.legacyGroupsFromJson(groupsJson),
            );
    }
    return LineUpGraph(
      origins: (fields[15] as List?)?.cast<LineUpOrigin>() ?? const [],
      landings: (fields[16] as List?)?.cast<LineUpLanding>() ?? const [],
      links: (fields[17] as List?)?.cast<LineUpLink>() ?? const [],
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
      // ignore: deprecated_member_use_from_same_package
      ..write(obj.lineUps)
      ..writeByte(12)
      // ignore: deprecated_member_use_from_same_package
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

class FreeDrawingAdapter extends TypeAdapter<FreeDrawing> {
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
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.listOfPoints)
      ..writeByte(2)
      ..write(obj.color)
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
      ..write(obj.thickness)
      ..writeByte(12)
      ..write(obj.colorValue);
  }
}

class LineAdapter extends TypeAdapter<Line> {
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
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.lineStart)
      ..writeByte(1)
      ..write(obj.lineEnd)
      ..writeByte(2)
      ..write(obj.color)
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
      ..write(obj.thickness)
      ..writeByte(10)
      ..write(obj.colorValue);
  }
}

class RectangleDrawingAdapter extends TypeAdapter<RectangleDrawing> {
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
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.start)
      ..writeByte(1)
      ..write(obj.end)
      ..writeByte(2)
      ..write(obj.color)
      ..writeByte(3)
      ..write(obj.isDotted)
      ..writeByte(4)
      ..write(obj.hasArrow)
      ..writeByte(5)
      ..write(obj.id)
      ..writeByte(6)
      ..write(obj.boundingBox)
      ..writeByte(7)
      ..write(obj.thickness)
      ..writeByte(8)
      ..write(obj.colorValue);
  }
}

class EllipseDrawingAdapter extends TypeAdapter<EllipseDrawing> {
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
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.start)
      ..writeByte(1)
      ..write(obj.end)
      ..writeByte(2)
      ..write(obj.color)
      ..writeByte(3)
      ..write(obj.thickness)
      ..writeByte(4)
      ..write(obj.isDotted)
      ..writeByte(5)
      ..write(obj.hasArrow)
      ..writeByte(6)
      ..write(obj.id)
      ..writeByte(7)
      ..write(obj.boundingBox)
      ..writeByte(8)
      ..write(obj.colorValue);
  }
}

/// Writes the record desktop 4.6.3 writes: the icon id at 4, the custom color
/// as ARGB at 6. Cloud builds before the main merge wrote a legacy icon and a
/// Color there and the exact values at 7 and 8; reading prefers those.
class FolderAdapter extends TypeAdapter<Folder> {
  @override
  final typeId = folderAdapterTypeId;

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
      iconId: FolderIconRegistry.idForStoredValue(fields[7] ?? fields[4]),
      color: fields[5] as FolderColor? ?? FolderColor.red,
      customColor: switch (fields[8] ?? fields[6]) {
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
