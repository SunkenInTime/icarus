// Exercises delivered data through the production placed-agent widget.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart' show SvgAssetLoader;
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/view_cone/svg_height_cone_cache.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_view_cone_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_view_cone_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

final _mapName = Platform.environment['ICARUS_ACCEPTANCE_MAP'] ?? 'icebox';
final _mapValue = MapValue.values.byName(_mapName);
final _freeUtility =
    Platform.environment['ICARUS_ACCEPTANCE_OBSERVER'] == 'utility';
final _sourceFixturePath = Platform.environment['ICARUS_SOURCE_FIXTURE'] ??
    'test/fixtures/icebox_vision_acceptance.json';

class _Map extends MapProvider {
  @override
  MapState build() => MapState(currentMap: _mapValue, isAttack: true);
}

class _DeliveredAssets extends SvgHeightRuntimeDependencies {
  final hashes = <String, String>{};
  static const folder = String.fromEnvironment('ICARUS_ACCEPTANCE_BUNDLE',
      defaultValue: 'build/windows/x64/runner/Profile/data/flutter_assets');
  Future<Uint8List> _load(String asset) async {
    final bytes = await File('$folder/$asset').readAsBytes();
    final hash = await Sha256().hash(bytes);
    hashes[asset] =
        hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(bytes, await File(asset).readAsBytes(),
        reason: 'Delivered assets must match the audited source checkout.');
    return bytes;
  }

  @override
  Future<Uint8List> loadModel(
          SvgHeightMapRegistration registration, bool side) =>
      _load(registration.modelAsset(side));
  @override
  Future<List<int>> loadArtwork(
          SvgHeightMapRegistration registration, bool side) =>
      _load(registration.artworkAsset(side));
}

class _RecordingCache extends SvgHeightConeCache {
  _RecordingCache(super.model);
  final calls = <Map<String, dynamic>>[];
  SvgCachedCone? lastResult;
  @override
  SvgCachedCone cone(
      {required Object observerId,
      required Offset origin,
      required double directionRadians,
      required double range,
      required double apertureRadians,
      double? cameraHeightMeters,
      double supportHeightAboveFloorMeters = 0,
      String? supportId,
      double? absoluteEyeElevationMeters,
      int arcSteps = 96}) {
    final result = super.cone(
        observerId: observerId,
        origin: origin,
        directionRadians: directionRadians,
        range: range,
        apertureRadians: apertureRadians,
        cameraHeightMeters: cameraHeightMeters,
        supportHeightAboveFloorMeters: supportHeightAboveFloorMeters,
        supportId: supportId,
        absoluteEyeElevationMeters: absoluteEyeElevationMeters,
        arcSteps: arcSteps);
    lastResult = result;
    calls.add({
      'originSvg': [origin.dx, origin.dy],
      'supportId': supportId,
      'eyeMeters': result.cone.eyeElevationMeters,
      'projectedFloorVisibility': result.cone.visibilityPath != null,
      'directionRadians': directionRadians,
      'apertureRadians': apertureRadians,
      'rangeSvg': range,
      'polygon': result.cone.polygon.map((p) => [p.dx, p.dy]).toList()
    });
    return result;
  }
}

class _RecordingRuntime extends SplitSvgHeightRuntime {
  _RecordingRuntime(SvgHeightRuntime loaded)
      : a = _RecordingCache(loaded.attack),
        d = _RecordingCache(loaded.defense),
        super.forMap(_mapValue, loaded.attack, loaded.defense);
  final _RecordingCache a, d;
  @override
  _RecordingCache cache(bool side) => side ? a : d;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());
  testWidgets(
      'delivered $_mapName source expectations survive placement, side flip and drag',
      (tester) async {
    final completed = await tester.runAsync(() async {
      Future<String> fileHash(String path) async =>
          (await Sha256().hash(File(path).readAsBytesSync()))
              .bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
      final implementationHashes = <String, String>{};
      for (final path in [
        'lib/providers/svg_height_runtime_provider.dart',
        'lib/view_cone/svg_height_visibility.dart',
        'lib/view_cone/svg_floor_visibility.dart',
        'lib/view_cone/svg_height_cone_cache.dart',
        'lib/widgets/draggable_widgets/utilities/svg_height_view_cone.dart',
        'lib/widgets/draggable_widgets/agents/placed_view_cone_agent_widget.dart',
        'tool/verify_icebox_app_acceptance_test.dart',
      ]) {
        implementationHashes[path] = await fileHash(path);
      }
      const size = Size(1600, 900);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final coordinates = CoordinateSystem(playAreaSize: size);
      final dependencies = _DeliveredAssets();
      final loader = ProviderContainer(overrides: [
        svgHeightRuntimeDependenciesProvider.overrideWithValue(dependencies),
      ]);
      final lease =
          loader.listen(svgHeightRuntimeProvider(_mapValue), (_, __) {});
      addTearDown(() {
        lease.close();
        loader.dispose();
      });
      final loaded =
          await loader.read(svgHeightRuntimeProvider(_mapValue).future);
      expect(loaded, isNotNull);
      final runtime = _RecordingRuntime(loaded!);
      final container = ProviderContainer(overrides: [
        mapProvider.overrideWith(_Map.new),
        svgHeightRuntimeProvider.overrideWith((ref, map) async => runtime),
      ]);
      addTearDown(container.dispose);
      final fixture = jsonDecode(File(_sourceFixturePath).readAsStringSync());
      final cases = (fixture['cases'] as List)
          .where((r) => r['selection'] == 'automatic')
          .toList();
      final transform = SvgHeightMapTransform.forMap(_mapValue);
      // Complete SVG decoding before the first captured placement. A cold
      // asset can still be loading after pumpAndSettle returns in runAsync.
      for (final suffix in ['', '_defense']) {
        await SvgAssetLoader('assets/maps/${_mapName}_map$suffix.svg')
            .loadBytes(null);
      }
      final output = Directory(
          Platform.environment['ICARUS_REGIONAL_APP_OUTPUT'] ??
              'work/icebox-acceptance/app')
        ..createSync(recursive: true);
      final records = <Map<String, dynamic>>[];
      final boundaryKey = GlobalKey();

      Offset canonical(Map row) {
        final xy = row['svg']['attack'] as List;
        return transform.sideWorldFromSource(
            Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble()),
            isAttack: true);
      }

      PlacedViewConeAgent agentAt(Map row, {double? elevation}) =>
          PlacedViewConeAgent(
              type: AgentType.jett,
              id: 'acceptance-agent',
              position: canonical(row) -
                  coordinates.virtualOffsetToWorld(const Offset(
                      Settings.agentSize / 2, Settings.agentSize / 2)),
              presetType: UtilityType.values
                  .byName(row['preset'] as String? ?? 'viewCone90'),
              rotation:
                  (row['directionAttack'] as num).toDouble() + math.pi / 2,
              length: (row['length'] as num?)?.toDouble() ?? 200,
              visionElevation: elevation);

      Future<void> pump(PlacedViewConeAgent agent, bool attack) async {
        container.read(mapProvider.notifier).setAttack(attack);
        container.read(agentProvider.notifier).fromHive([agent]);
        final utility = PlacedUtility(
            id: agent.id,
            type: agent.presetType,
            position: agent.position +
                coordinates.virtualOffsetToWorld(const Offset(
                    Settings.agentSize / 2, Settings.agentSize / 2)) -
                coordinates
                    .virtualOffsetToWorld(ViewConeWidget.anchorPointVirtual),
            angle: 0,
            visionElevation: agent.visionElevation)
          ..rotation = agent.rotation
          ..length = agent.length;
        if (_freeUtility)
          container.read(utilityProvider.notifier).fromHive([utility]);
        await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: ShadApp(
                home: Scaffold(
                    body: RepaintBoundary(
                        key: boundaryKey,
                        child: Stack(children: [
                          Positioned(
                              left: coordinates
                                  .worldWidthToScreen(transform.offset.dx),
                              top: coordinates
                                  .worldHeightToScreen(transform.offset.dy),
                              width: coordinates.worldWidthToScreen(
                                  transform.viewBox.width * transform.scale),
                              height: coordinates.worldHeightToScreen(
                                  transform.viewBox.height * transform.scale),
                              child: SvgPicture.asset(
                                  'assets/maps/${_mapName}_map${attack ? '' : '_defense'}.svg')),
                          if (_freeUtility)
                            PlacedViewConeWidget(
                                utility: utility,
                                id: utility.id,
                                rotation: utility.rotation,
                                length: utility.length,
                                isAttack: attack,
                                onDragEnd: (_) {})
                          else
                            PlacedViewConeAgentWidget(
                                agent: agent, onDragEnd: (_, __) {}),
                        ]))))));
        if (_freeUtility) {
          await precacheImage(const AssetImage('assets/eye.webp'),
              tester.element(find.byType(ViewConeWidget)));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      void check(Map row, bool attack, String operation,
          {double? expectedEye}) {
        final call = runtime.cache(attack).calls.last;
        final xy = row['svg'][attack ? 'attack' : 'defense'] as List;
        expect((call['originSvg'][0] as num).toDouble(),
            closeTo((xy[0] as num).toDouble(), 1e-7));
        expect((call['originSvg'][1] as num).toDouble(),
            closeTo((xy[1] as num).toDouble(), 1e-7));
        expect(
            call['eyeMeters'],
            closeTo(expectedEye ?? (row['expectedEyeMeters'] as num).toDouble(),
                .02),
            reason: '${row['id']} ${attack ? 'attack' : 'defense'} $operation');
        expect((call['polygon'] as List).length, greaterThan(3));
        final result = runtime.cache(attack).lastResult!.cone;
        final visibility =
            result.visibilityPath ?? (Path()..addPolygon(result.polygon, true));
        // Dragging retains the starting agent's rotation; destination-facing
        // targets apply only when that pose was explicitly placed.
        final targets = operation == 'default-placement' ||
                operation == 'saved-lower-reference'
            ? row['visibilityTargets'] as List? ?? []
            : const [];
        for (final target in targets) {
          final xy = target['svg'][attack ? 'attack' : 'defense'] as List;
          expect(
              visibility.contains(
                  Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble())),
              target['visible'],
              reason: '${row["id"]} rendered destination');
        }
        records.add({
          'id': row['id'],
          'side': attack ? 'attack' : 'defense',
          'operation': operation,
          'expectedEyeMeters': expectedEye ?? row['expectedEyeMeters'],
          ...call
        });
      }

      for (final row in cases) {
        final agent = agentAt(row);
        final saved = agent.toJson();
        for (final attack in [true, false]) {
          await pump(agent, attack);
          check(row, attack, 'default-placement');
          expect(agent.toJson(), saved,
              reason: 'A side flip must preserve the saved placement.');
          final image = await (() async {
            final boundary = boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
            final capture = await boundary.toImage();
            final png =
                await capture.toByteData(format: ui.ImageByteFormat.png);
            capture.dispose();
            return png!;
          })();
          File('${output.path}/${row['id']}-${attack ? 'attack' : 'defense'}.png')
              .writeAsBytesSync(image.buffer.asUint8List());
          if (row['savedReferenceEyeMeters'] != null) {
            final eye = (row['savedReferenceEyeMeters'] as num).toDouble();
            await pump(agentAt(row, elevation: eye * 100), attack);
            check(row, attack, 'saved-lower-reference', expectedEye: eye);
            final boundary = boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
            final capture = await boundary.toImage();
            final png =
                await capture.toByteData(format: ui.ImageByteFormat.png);
            capture.dispose();
            File('${output.path}/${row['id']}-lower-${attack ? 'attack' : 'defense'}.png')
                .writeAsBytesSync(png!.buffer.asUint8List());
          }
        }
      }

      // Use the real pointer-drag feedback path for each reviewed movement.
      final routes = fixture['dragRoutes'] as List? ??
          [
            {
              'from': fixture['dragFrom'] ?? 'top-screens-reported',
              'to': fixture['dragTo'] ?? 'lower-pipe-reported'
            }
          ];
      for (final route in routes) {
        final start = cases.singleWhere((r) => r['id'] == route['from']);
        final destination = cases.singleWhere((r) => r['id'] == route['to']);
        for (final attack
            in fixture['dragRoutes'] == null ? [true] : [true, false]) {
          await pump(agentAt(start), attack);
          final icon = find.byType(_freeUtility ? ViewConeWidget : AgentWidget);
          expect(icon, findsOneWidget);
          final delta = coordinates.worldOffsetToScreen(
              (canonical(destination) - canonical(start)) * (attack ? 1 : -1));
          final pivot = _freeUtility
              ? coordinates.coordinateToScreen(coordinates.positionForSide(
                  canonicalPosition: canonical(start),
                  reflectionOffset: Offset.zero,
                  isAttack: attack))
              : tester.getCenter(icon);
          final gesture = await tester.startGesture(pivot,
              kind: ui.PointerDeviceKind.mouse);
          // Activate dragging even when the source poses are closer than slop.
          await gesture.moveBy(const Offset(30, 0));
          await tester.pumpAndSettle();
          await gesture.moveBy(const Offset(-30, 0));
          await tester.pumpAndSettle();
          await gesture.moveBy(delta / 2);
          await tester.pump();
          await gesture.moveBy(delta / 2);
          await tester.pumpAndSettle();
          check(destination, attack, 'pointer-drag-feedback');
          await gesture.up();
          await tester.pumpAndSettle();
        }
      }

      final regionalFile = File(
          Platform.environment['ICARUS_REGIONAL_FIXTURE'] ??
              'test/fixtures/icebox_regional_standing.json');
      final regional = jsonDecode(regionalFile.readAsStringSync());
      for (final source in (regional['defaultPlacements'] as List? ?? [])) {
        final row = Map<String, dynamic>.from(source as Map)
          ..['directionAttack'] = 0.0;
        for (final attack in [true, false]) {
          final xy = row['svg'][attack ? 'attack' : 'defense'] as List;
          final point =
              Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
          final model = runtime.model(attack);
          final eligible = (row['sourceLocalLevelsMeters'] as List)
              .cast<num>()
              .map((z) => z.toDouble())
              .where((z) => !model.walls
                  .any((w) => w.contains(point) && w.blocks(z + 1.75)))
              .toList();
          if (!model.receiverContains(point) || eligible.isEmpty) continue;
          final floor = eligible.reduce((a, b) => a > b ? a : b);
          await pump(agentAt(row), attack);
          check(row, attack, 'source-domain-default',
              expectedEye: floor + 1.75);
          final lowerEye = (row['expectedEyeMeters'] as num).toDouble();
          if (!model.walls
              .any((w) => w.contains(point) && w.blocks(lowerEye))) {
            await pump(agentAt(row, elevation: lowerEye * 100), attack);
            check(row, attack, 'source-domain-saved-level');
          }
        }
      }
      for (final path in regional['rampPaths'] as List) {
        final positions = path['nativeXY'] as List;
        for (final index in {0, positions.length ~/ 2, positions.length - 1}) {
          final xy = positions[index] as List;
          final candidates = (regional['cases'] as List).where((row) {
            final p = row['nativeXY'] as List;
            return row['domain'] == path['domain'] &&
                ((p[0] as num) - (xy[0] as num)).abs() < 1e-7 &&
                ((p[1] as num) - (xy[1] as num)).abs() < 1e-7;
          });
          final row = Map<String, dynamic>.from(candidates.first as Map)
            ..['directionAttack'] = 0.0;
          for (final attack in [true, false]) {
            final p = row['svg'][attack ? 'attack' : 'defense'] as List;
            final point =
                Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
            final model = runtime.model(attack);
            if (!model.receiverContains(point) ||
                model.walls.any((w) =>
                    w.contains(point) &&
                    w.blocks((row['expectedEyeMeters'] as num).toDouble()))) {
              continue;
            }
            await pump(
                agentAt(row,
                    elevation:
                        (row['expectedEyeMeters'] as num).toDouble() * 100),
                attack);
            check(row, attack, 'source-ramp-saved-level');
          }
        }
      }

      // Source fixtures mark joins whose local level is also the default.
      // Exercise the pointer stream across their supporting faces.
      for (final join in (regional['rampJoins'] as List).where((j) =>
          (j['cases'] as List).every((r) => r['selection'] == 'automatic'))) {
        final route = (join['cases'] as List)
            .map((r) =>
                Map<String, dynamic>.from(r as Map)..['directionAttack'] = 0.0)
            .toList();
        for (final attack in [true, false]) {
          await pump(agentAt(route.first), attack);
          final movement = await tester.startGesture(
              tester.getCenter(find.byType(AgentWidget)),
              kind: ui.PointerDeviceKind.mouse);
          // Cross the drag recognizer's slop before testing 5 cm movements.
          await movement.moveBy(const Offset(30, 0));
          await tester.pumpAndSettle();
          await movement.moveBy(const Offset(-30, 0));
          await tester.pumpAndSettle();
          for (var i = 1; i < route.length; i++) {
            final delta = coordinates.worldOffsetToScreen(
                (canonical(route[i]) - canonical(route[i - 1])) *
                    (attack ? 1 : -1));
            await movement.moveBy(delta);
            await tester.pumpAndSettle();
            check(route[i], attack, 'pointer-ramp-join');
          }
          await movement.up();
          await tester.pumpAndSettle();
        }
      }

      final fixtureHash =
          await Sha256().hash(File(_sourceFixturePath).readAsBytesSync());
      File('${output.path}/verification.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'status': 'passed',
        'map': _mapName,
        'regionalFixtureSha256':
            (await Sha256().hash(regionalFile.readAsBytesSync()))
                .bytes
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join(),
        'sourceFixtureSha256': fixtureHash.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        'surface':
            'Flutter widget integration using delivered asset files and production provider, placed agent, cache and painter. No live-game certification.',
        'assetHashes': dependencies.hashes,
        'implementationHashes': implementationHashes,
        'records': records
      }));
      await tester.pumpWidget(const SizedBox.shrink());
      return true;
    });
    expect(completed, isTrue);
  }, timeout: const Timeout(Duration(minutes: 30)));
}
