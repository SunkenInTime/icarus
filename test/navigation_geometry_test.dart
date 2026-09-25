import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';

void main() {
  test('floor lookup interpolates slopes and preserves stacked floors', () {
    final data = mesh([
      [
        const [0, 0, 100],
        const [10, 0, 200],
        const [10, 10, 200],
        const [0, 10, 100]
      ],
      rect(0, 0, 10, 10, 500),
    ]);
    final navigation = load(data);
    expect(navigation.floorHeightsAt(const Offset(5, 5)), [150, 500]);
    expect(
        navigation.floorHeightAt(const Offset(5, 5), preferredElevation: 480),
        500);
    expect(navigation.floorHeightAt(const Offset(20, 20)), isNull);
    expect(
        navigation
            .findRoute(
                start: const Offset(2, 2),
                end: const Offset(8, 8),
                startFloorHeight: 120,
                endFloorHeight: 500)
            .failure,
        'disconnected-floors');
  });

  test('refined floor values replace voxel heights without changing topology',
      () {
    final data = mesh([rect(0, 0, 10, 10, 310)])
      ..['refinedFloorHeightsCm'] = [300, 300, 300, 300];
    expect(load(data).floorHeightAt(const Offset(5, 5)), 300);
  });

  test('detailed floors preserve stair edges and separate upper floors', () {
    final data = mesh([rect(0, 0, 10, 10, 5), rect(0, 0, 10, 10, 500)]);
    final detail = mesh([
      rect(0, 0, 5, 10, 0),
      rect(5, 0, 10, 10, 20),
      rect(0, 0, 10, 10, -10),
    ]);
    final floorTriangles = (detail['triangles'] as List<int>).toList();
    for (var i = 0; i < floorTriangles.length; i += 4) floorTriangles[i] = 0;
    data['floorMesh'] = {
      'coordinateScale': 1,
      'vertices': detail['vertices'],
      'triangles': floorTriangles
    };
    final navigation = load(data);
    expect(navigation.floorHeightsAt(const Offset(4.99, 5)), [0, 500]);
    expect(navigation.floorHeightsAt(const Offset(5.01, 5)), [20, 500]);
    expect(
        navigation.floorHeightAt(const Offset(7, 5), preferredElevation: 450),
        500);
    expect(navigation.floorHeightAt(const Offset(7, 5), preferredElevation: 0),
        20);
    expect(
        navigation
            .findRoute(
                start: const Offset(2, 5),
                end: const Offset(8, 5),
                startFloorHeight: 0,
                endFloorHeight: 20)
            .isReachable,
        isTrue);
    expect(
        navigation
            .findRoute(
                start: const Offset(2, 5),
                end: const Offset(8, 5),
                startFloorHeight: 0,
                endFloorHeight: 500)
            .isReachable,
        isFalse);
  });

  test('a thin wall remains disconnected even with adjacent endpoint positions',
      () {
    final navigation =
        load(mesh([rect(0, 0, 10, 10, 0), rect(10.01, 0, 20, 10, 0)]));
    final route = navigation.findRoute(
        start: const Offset(9.99, 5), end: const Offset(10.02, 5));
    expect(route.isReachable, isFalse);
    expect(route.points, isEmpty);
  });

  test('standing origins reject nonwalkable detail and fallback parents', () {
    final data = mesh([
      rect(0, 0, 10, 10, 0),
      rect(0, 0, 10, 10, 300),
      rect(20, 0, 30, 10, 100),
    ], components: [
      0,
      -1,
      -1
    ])
      ..['walkable'] = [true, false, false];
    final detail = mesh([rect(0, 0, 10, 10, 310)]);
    final detailTriangles = (detail['triangles'] as List<int>).toList();
    for (var i = 0; i < detailTriangles.length; i += 4) detailTriangles[i] = 1;
    data['floorMesh'] = {
      'coordinateScale': 1,
      'vertices': detail['vertices'],
      'triangles': detailTriangles
    };
    final navigation = load(data);
    expect(navigation.floorHeightsAt(const Offset(5, 5)), [0]);
    expect(
        navigation.floorHeightAt(const Offset(5, 5), preferredElevation: 310),
        0);
    expect(navigation.floorHeightsAt(const Offset(25, 5)), isEmpty);
    expect(navigation.floorHeightAt(const Offset(25, 5)), isNull);
    expect(
        navigation
            .findRoute(start: const Offset(25, 5), end: const Offset(5, 5))
            .failure,
        'endpoint-outside-navigation');
  });

  test(
      'higher precision floor clipping cannot extend its encoded parent domain',
      () {
    final data = mesh([rect(0, 0, 10, 10, 100)]);
    final detail = mesh([rect(-.01, 0, 10.01, 10, 90)]);
    data['floorMesh'] = {
      'coordinateScale': 1,
      'vertices': detail['vertices'],
      'triangles': detail['triangles']
    };
    final navigation = load(data);
    expect(navigation.floorHeightAt(const Offset(5, 5)), 90);
    expect(navigation.floorHeightAt(const Offset(-.005, 5)), isNull);
    expect(navigation.floorHeightAt(const Offset(10.005, 5)), isNull);
    expect(
        navigation
            .findRoute(start: const Offset(-.005, 5), end: const Offset(5, 5))
            .isReachable,
        isFalse);
  });

  test('portals permit a real floor transition and preserve the corner', () {
    final data = mesh([
      rect(0, 0, 10, 10, 0),
      rect(10, 0, 20, 10, 0),
      rect(10, 10, 20, 20, 30),
    ], links: [
      0,
      1,
      10,
      0,
      10,
      10,
      1,
      0,
      10,
      0,
      10,
      10,
      1,
      2,
      10,
      10,
      20,
      10,
      2,
      1,
      10,
      10,
      20,
      10
    ], components: [
      0,
      0,
      0
    ]);
    final navigation = load(data);
    final route = navigation.findRoute(
        start: const Offset(2, 8),
        end: const Offset(12, 18),
        startFloorHeight: 0,
        endFloorHeight: 30);
    expect(route.isReachable, isTrue);
    expect(route.points,
        [const Offset(2, 8), const Offset(10, 10), const Offset(12, 18)]);
    final reverse = navigation.findRoute(
        start: const Offset(12, 18),
        end: const Offset(2, 8),
        startFloorHeight: 30,
        endFloorHeight: 0);
    expect(reverse.points, route.points.reversed.toList());
    expect(
        identical(
            route,
            navigation.findRoute(
                start: const Offset(2, 8),
                end: const Offset(12, 18),
                startFloorHeight: 0,
                endFloorHeight: 30)),
        isTrue);
  });

  test('source detail triangle tolerance cannot extend the polygon domain', () {
    final data = mesh([rect(0, 0, 10, 10, 100)]);
    (data['vertices'] as List<num>).addAll([10.01, 5, 100]);
    (data['triangles'] as List<int>).addAll([0, 0, 4, 3]);
    final navigation = load(data);
    expect(navigation.floorHeightAt(const Offset(9, 5)), 100);
    expect(navigation.floorHeightAt(const Offset(10.005, 5)), isNull);
  });

  test('straight connected corridors do not visit polygon centers', () {
    final navigation = load(mesh([
      rect(0, 0, 10, 10, 0),
      rect(10, 0, 20, 10, 0),
      rect(20, 0, 30, 10, 0),
    ], links: [
      0,
      1,
      10,
      0,
      10,
      10,
      1,
      0,
      10,
      0,
      10,
      10,
      1,
      2,
      20,
      0,
      20,
      10,
      2,
      1,
      20,
      0,
      20,
      10
    ], components: [
      0,
      0,
      0
    ]));
    expect(
        navigation
            .findRoute(start: const Offset(2, 3), end: const Offset(28, 7))
            .points,
        [const Offset(2, 3), const Offset(28, 7)]);
  });

  test('rotating the projection rotates the route without changing its length',
      () {
    final data = mesh([rect(0, 0, 10, 10, 0), rect(10, 0, 20, 10, 0)],
        links: [0, 1, 10, 0, 10, 10, 1, 0, 10, 0, 10, 10], components: [0, 0]);
    Offset flip(Offset p) => Offset(100 - p.dx, 100 - p.dy);
    final navigation = NavigationGeometry.fromJson(data, projectUv: flip);
    expect(
        navigation
            .findRoute(
                start: flip(const Offset(2, 3)), end: flip(const Offset(18, 7)))
            .points,
        [flip(const Offset(2, 3)), flip(const Offset(18, 7))]);
  });

  test('invalid geometry and stale floor arrays fail loading', () {
    final data = mesh([rect(0, 0, 10, 10, 0)]);
    expect(
        () => load({
              ...data,
              'refinedFloorHeightsCm': [1]
            }),
        throwsFormatException);
    expect(
        () => load({
              ...data,
              'triangles': [0, 0, 0, 0]
            }),
        throwsFormatException);
    expect(
        () => load({
              ...data,
              'triangles': [0, 0, 1, 99]
            }),
        throwsFormatException);
    expect(() => load({...data, 'schemaVersion': 7}), throwsFormatException);
  });
}

NavigationGeometry load(Map<String, dynamic> data) =>
    NavigationGeometry.fromJson(data, projectUv: (p) => p);

List<List<num>> rect(num x1, num y1, num x2, num y2, num z) => [
      [x1, y1, z],
      [x2, y1, z],
      [x2, y2, z],
      [x1, y2, z]
    ];

Map<String, dynamic> mesh(List<List<List<num>>> floors,
    {List<num> links = const [], List<int>? components}) {
  final vertices = <num>[], polygons = <List<int>>[], triangles = <int>[];
  for (var p = 0; p < floors.length; p++) {
    final first = vertices.length ~/ 3;
    for (final point in floors[p]) {
      vertices.addAll(point);
    }
    polygons.add([for (var i = 0; i < floors[p].length; i++) first + i]);
    for (var i = 1; i < floors[p].length - 1; i++) {
      triangles.addAll([p, first, first + i, first + i + 1]);
    }
  }
  return {
    'schemaVersion': 1,
    'coordinateScale': 1,
    'vertices': vertices,
    'polygons': polygons,
    'triangles': triangles,
    'links': links,
    'components': components ?? [for (var p = 0; p < floors.length; p++) p],
    'walkable': [for (final _ in floors) true]
  };
}
