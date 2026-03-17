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
  AdapterSpec<FreeDrawing>(),
  AdapterSpec<Line>(),
  AdapterSpec<BoundingBox>(),
  AdapterSpec<StrategySettings>(),
  AdapterSpec<PlacedUtility>(),
  AdapterSpec<UtilityType>(),
  AdapterSpec<IconData>(),
  AdapterSpec<FolderColor>(),
  AdapterSpec<StrategyPage>(),
  AdapterSpec<LineUp>(),
  AdapterSpec<SimpleImageData>(),
  AdapterSpec<AgentState>(),
  AdapterSpec<RectangleDrawing>(),
  AdapterSpec<EllipseDrawing>(),
  AdapterSpec<TraversalSpeedProfile>(),
  AdapterSpec<MapThemePalette>(),
  AdapterSpec<MapThemeProfile>(),
  AdapterSpec<AppPreferences>(),
  AdapterSpec<PlacedViewConeAgent>(),
  AdapterSpec<PlacedCircleAgent>(),
])
part 'hive_adapters.g.dart';

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
