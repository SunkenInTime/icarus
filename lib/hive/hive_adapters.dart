// ignore_for_file: unused_import, unnecessary_import

import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Offset;

import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

@GenerateAdapters([
  AdapterSpec<StrategyData>(),
  AdapterSpec<PlacedWidget>(),
  AdapterSpec<PlacedAgent>(),
  AdapterSpec<PlacedAbility>(),
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
  AdapterSpec<StrategyPage>(),
  AdapterSpec<LineUp>(),
  AdapterSpec<LineUpGroup>(),
  AdapterSpec<LineUpItem>(),
  AdapterSpec<SimpleImageData>(),
  AdapterSpec<AgentState>(),
  AdapterSpec<TraversalSpeedProfile>(),
  AdapterSpec<MapThemePalette>(),
  AdapterSpec<MapThemeProfile>(),
  AdapterSpec<AppPreferences>(),
  AdapterSpec<PlacedViewConeAgent>(),
  AdapterSpec<PlacedCircleAgent>(),
])
part 'hive_adapters.g.dart';

const int freeDrawingAdapterTypeId = 11;
const int lineAdapterTypeId = 12;
const int rectangleDrawingAdapterTypeId = 24;
const int ellipseDrawingAdapterTypeId = 31;

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

class FolderAdapter extends TypeAdapter<Folder> {
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
      icon: fields[4] as IconData,
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
      ..write(obj.icon)
      ..writeByte(5)
      ..write(obj.color)
      ..writeByte(6)
      ..write(obj.customColor?.toARGB32());
  }
}
