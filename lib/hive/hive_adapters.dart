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
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

@GenerateAdapters([
  AdapterSpec<StrategyData>(),
  AdapterSpec<PlacedWidget>(),
  AdapterSpec<PlacedAgent>(),
  AdapterSpec<PlacedAbility>(),
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
  AdapterSpec<Folder>(),
  AdapterSpec<IconData>(),
  AdapterSpec<FolderColor>(),
  AdapterSpec<StrategyPage>(),
  AdapterSpec<LineUp>(),
  AdapterSpec<SimpleImageData>(),
  AdapterSpec<AgentState>(),
  AdapterSpec<RectangleDrawing>(),
])
part 'hive_adapters.g.dart';
