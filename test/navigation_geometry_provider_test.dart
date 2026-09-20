import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/page_transition/agent_path.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';

import 'navigation_geometry_test.dart' show mesh, rect;

Map<String, dynamic> navigationFixture() => {
      'schemaVersion': 1,
      'map': 'split',
      'coordinateScale': 1000,
      'vertices': [200, 200, 300, 800, 200, 400, 800, 800, 400, 200, 800, 300],
      'polygons': [
        [0, 1, 2, 3]
      ],
      'triangles': [0, 0, 1, 2, 0, 0, 2, 3],
      'links': [],
      'components': [0],
      'walkable': [true],
    };

class _NavigationBundle extends CachingAssetBundle {
  _NavigationBundle({this.wrongMap = false, this.missingDefaults = false, this.damage});
  final bool wrongMap, missingDefaults;
  final String? damage;
  final requested = <String>[];
  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    if (key.endsWith('/height_catalog.json')) {
      final bytes = _navigationBytes();
      final hash = (await Sha256().hash(bytes))
          .bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
      final zeroHash = '0' * 64;
      return ByteData.sublistView(Uint8List.fromList(utf8.encode(jsonEncode({
        'version': 1,
        'format': 'icarus-height-assets-v1',
        'maps': {
          for (final map in MapValue.values)
            map.name: {
              'pack': '${map.name}.height.bin.gz',
              'packSha256': zeroHash,
              'compressedBytes': 1,
              'rawSha256': zeroHash,
              'rawBytes': 1,
              'navigation': '${map.name}_navigation.json.gz',
              'navigationSha256': hash,
              'navigationBytes': bytes.length,
              'sourceGeometrySha256': zeroHash,
              'policySha256': zeroHash,
              'observerHeightCm': 175,
              'defaultFloorElevationCm': 300,
              'heightDomainMeters': [0, 10],
              'menuElevationsCm': [175, 475],
              'uiTransform': {
                'XMultiplier': .000078,
                'YMultiplier': -.000078,
                'XScalarToAdd': .842188,
                'YScalarToAdd': .697578
              },
            }
        }
      }))));
    }
    if (!key.endsWith('_navigation.json.gz')) {
      throw StateError('Unexpected asset request: $key');
    }
    final bytes = _navigationBytes();
    if (damage == 'checksum') bytes[bytes.length - 8] ^= 1;
    if (damage == 'truncated') {
      return ByteData.sublistView(
          Uint8List.sublistView(bytes, 0, bytes.length - 8));
    }
    return ByteData.sublistView(bytes);
  }

  Uint8List _navigationBytes() {
    final data = navigationFixture();
    if (!missingDefaults) {
      data['observerHeightCm'] = 175;
      data['defaultFloorElevationCm'] = 300;
    }
    if (wrongMap) data['map'] = 'sunset';
    return Uint8List.fromList(
        const GZipEncoder().encode(utf8.encode(jsonEncode(data))));
  }
}

class _MapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.split, isAttack: true);
  void select(MapValue map) =>
      state = MapState(currentMap: map, isAttack: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('side flips preserve the same physical route despite raw artwork offset',
      () {
    // A U-shaped corridor forces a detour around the missing central floor.
    final data = mesh([
      rect(0, 0, 10, 30, 300),
      rect(10, 20, 20, 30, 300),
      rect(20, 0, 30, 30, 300),
    ], links: [
      0,
      1,
      10,
      20,
      10,
      30,
      1,
      0,
      10,
      20,
      10,
      30,
      1,
      2,
      20,
      20,
      20,
      30,
      2,
      1,
      20,
      20,
      20,
      30,
    ], components: [
      0,
      0,
      0
    ]);
    const start = Offset(5, 5), end = Offset(25, 5);
    final entries = [
      PageTransitionEntry.move(
        from: PlacedAgent(id: 'sova', type: AgentType.sova, position: start),
        to: PlacedAgent(id: 'sova', type: AgentType.sova, position: end),
      )
    ];
    final coordinates = CoordinateSystem(playAreaSize: const Size(1920, 1080));
    for (final offset in [
      Offset.zero,
      const Offset(100, 50),
      const Offset(-80, -40)
    ]) {
      final native = NavigationGeometry.fromJson(data, projectUv: (p) => p);
      final navigation = NavigationGeometryMap(
          geometry: native,
          observerHeightCm: 175,
          defaultFloorElevationCm: 300,
          defenseOffsetCanvas: offset);
      AgentTransitionPath route(bool isAttack) =>
          AgentTransitionPathPlanner.plan(
              entries: entries,
              geometry: null,
              navigation: navigation,
              requireNavigation: true,
              isAttack: isAttack,
              startAgentSize: 0,
              endAgentSize: 0,
              coordinateSystem: coordinates)['sova']!;
      final defense = route(false);
      expect(defense.isReachable, isTrue, reason: 'defense offset $offset');
      expect(defense.points.first, start);
      expect(defense.points.last, end);
      expect(defense.points.any((p) => p.dy >= 20), isTrue);
      for (var step = 0; step <= 100; step++) {
        final point = defense.positionAt(step / 100);
        expect(
            point.dx > 10.000001 &&
                point.dx < 19.999999 &&
                point.dy < 19.999999,
            isFalse,
            reason: 'defense route crossed central wall at $point');
        expect(native.floorHeightAt(point), isNotNull,
            reason: 'both sides use canonical navigation coordinates');
      }
      final attack = route(true);
      expect(attack.isReachable, isTrue);
      expect(defense.points, attack.points,
          reason: 'artwork registration must not alter a saved agent path');
    }
  });
  test('current-map navigation survives page reads and releases on map change',
      () async {
    final bundle = _NavigationBundle();
    final container = ProviderContainer(overrides: [
      mapProvider.overrideWith(_MapProvider.new),
      worldGeometryEnabledProvider.overrideWith((ref, map) => true),
      navigationGeometryBundleProvider.overrideWithValue(bundle),
    ]);
    addTearDown(container.dispose);
    final first =
        await container.read(navigationGeometryProvider(MapValue.split).future);
    await container.pump();
    final nextPage =
        await container.read(navigationGeometryProvider(MapValue.split).future);
    expect(identical(first, nextPage), isTrue);
    expect(bundle.requested, hasLength(2));
    (container.read(mapProvider.notifier) as _MapProvider)
        .select(MapValue.ascent);
    await container.pump();
    expect(
        container.exists(navigationGeometryProvider(MapValue.split)), isFalse);
  });
  test(
      'movement loads only the catalog and the navigation chart',
      () async {
    final bundle = _NavigationBundle();
    final navigation =
        await loadNavigationGeometry(MapValue.split, bundle: bundle);
    expect(bundle.requested, [
      'assets/maps/world/height_catalog.json',
      'assets/maps/world/split_navigation.json.gz'
    ]);
    expect(navigation.observerHeightCm, 175);
    expect(navigation.defaultFloorElevationCm, 300);
    final coordinates = CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final start =
        VisionGeometryMap.projectUv(MapValue.split, const Offset(.3, .4));
    final end =
        VisionGeometryMap.projectUv(MapValue.split, const Offset(.7, .6));
    final routes = AgentTransitionPathPlanner.plan(
      entries: [
        PageTransitionEntry.move(
          from: PlacedAgent(id: 'sova', type: AgentType.sova, position: start),
          to: PlacedAgent(id: 'sova', type: AgentType.sova, position: end),
        )
      ],
      geometry: null,
      navigation: navigation,
      requireNavigation: true,
      startAgentSize: 0,
      endAgentSize: 0,
      coordinateSystem: coordinates,
    );
    expect(routes['sova']!.isReachable, isTrue);
    expect(routes['sova']!.points.first, start);
    expect(routes['sova']!.points.last, end);
  });
  test('navigation rejects wrong-map sources and missing standing defaults',
      () async {
    for (final bundle in [
      _NavigationBundle(wrongMap: true),
      _NavigationBundle(missingDefaults: true)
    ]) {
      await expectLater(loadNavigationGeometry(MapValue.split, bundle: bundle),
          throwsFormatException);
    }
  });
  test('movement rejects damaged navigation gzip',
      () async {
    for (final damage in ['checksum', 'truncated']) {
      await expectLater(
          loadNavigationGeometry(MapValue.split,
              bundle: _NavigationBundle(damage: damage)),
          throwsA(isA<Object>()),
          reason: damage);
    }
  });
  for (final requireNavigation in [false, true]) {
    test(
        'missing navigation ${requireNavigation ? 'holds native movement' : 'preserves the legacy fallback'}',
        () {
      final coordinates =
          CoordinateSystem(playAreaSize: const Size(1920, 1080));
      const start = Offset(200, 300), end = Offset(500, 600);
      final routes = AgentTransitionPathPlanner.plan(
        entries: [
          PageTransitionEntry.move(
            from:
                PlacedAgent(id: 'sova', type: AgentType.sova, position: start),
            to: PlacedAgent(id: 'sova', type: AgentType.sova, position: end),
          )
        ],
        geometry: null,
        requireNavigation: requireNavigation,
        startAgentSize: 20,
        endAgentSize: 40,
        coordinateSystem: coordinates,
      );
      if (!requireNavigation) {
        expect(routes, isEmpty);
      } else {
        final path = routes['sova']!;
        expect(path.isReachable, isFalse);
        expect(path.positionAt(.999),
            start + coordinates.virtualOffsetToWorld(const Offset(10, 10)));
        expect(path.positionAt(1),
            end + coordinates.virtualOffsetToWorld(const Offset(20, 20)));
      }
    });
  }
}
