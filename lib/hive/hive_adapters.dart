import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Offset;

import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_provider.dart';

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
])
part 'hive_adapters.g.dart';
