import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/providers/height_runtime_provider.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_native.dart';
import 'package:icarus/view_cone/tactical_ground_field.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

class TestHeightDependencies extends HeightRuntimeDependencies {
  TestHeightDependencies(this.program);
  final ui.FragmentProgram program;
  final assets = TestHeightAssets();
  final worker = TestHeightWorker();
  final assetStarted = Completer<void>();
  final workerStarted = Completer<void>();
  Completer<void>? releaseAssets, releaseWorker;
  var openCalls = 0;
  var svgLoads = 0;

  @override
  Future<HeightAssets> loadAssets(MapValue map) async {
    if (!assetStarted.isCompleted) assetStarted.complete();
    await releaseAssets?.future;
    return assets;
  }

  @override
  Future<String> loadSvg(MapValue map, {required bool isAttack}) async {
    svgLoads++;
    return '<svg viewBox="0 0 1000 1000"><path fill="#271406" d="M0 0H1000V1000H0Z"/></svg>';
  }

  @override
  Future<ui.FragmentProgram> loadProgram() async => program;
  @override
  Future<HeightNativeWorker> openWorker(HeightAssets assets) async {
    openCalls++;
    if (!workerStarted.isCompleted) workerStarted.complete();
    await releaseWorker?.future;
    return worker;
  }
}

class TestHeightWorker implements HeightNativeWorker {
  var closeCalls = 0;
  var computeCalls = 0;
  void Function()? onCompute;
  Object? computeError, closeError;
  final computeStarted = Completer<void>();
  Completer<void>? releaseCompute;

  @override
  Future<HeightFrame> compute(int stamp, Float64List queries) async {
    computeCalls++;
    onCompute?.call();
    if (!computeStarted.isCompleted) computeStarted.complete();
    await releaseCompute?.future;
    if (computeError case final error?) throw error;
    return HeightFrame(
        stamp, Float32List(0), Uint32List(queries.length ~/ 7 + 1), {});
  }

  @override
  Future<void> close() async {
    closeCalls++;
    if (closeError case final error?) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestHeightAssets implements HeightAssets {
  @override
  DisplayWarp? displayWarp;
  @override
  final variants = <HeightAssets>[];
  @override
  VisionWorldProjection get defenseProjection => projection.defense;
  @override
  TacticalGroundField? get groundField => null;
  @override
  final projection = VisionWorldProjection(
      origin: const ui.Offset(388.8888888888889, 0),
      axisU: const ui.Offset(8, 0),
      axisV: const ui.Offset(0, 8));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestHeightFloor implements NavigationGeometry {
  @override
  int get maximumGroundChartId => 0;
  @override
  double? floorHeightAt(ui.Offset position, {double? preferredElevation}) => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final testHeightNavigation = NavigationGeometryMap(
    geometry: TestHeightFloor(),
    observerHeightCm: 175,
    defaultFloorElevationCm: 0);
