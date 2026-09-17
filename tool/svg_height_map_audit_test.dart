// Whole-map audit of the bundled SVG-height visibility data.
//
// For every map and side this loads the shipped model and measures, without
// any 3D source, the three things Dara keeps finding by hand:
//
// * level jumps: neighbouring floor cells not separated by an active wall
//   whose automatic standing eye differs by more than a step;
// * blocks-from-above: wall edges with a ground drop across them that still
//   block the eye standing on the high side (ledges treated as walls);
// * floor-line walls: thin stroke pieces inside the receiver with continuous
//   ground on both sides and a tall band, next to a ground slope (ramp and
//   stair markings that were given a building's height).
//
// Renders build/svg_height_audit_<map>_<side>.png and prints a summary.
// Run: flutter test tool/svg_height_map_audit_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

const maps = [
  'abyss',
  'ascent',
  'bind',
  'breeze',
  'corrode',
  'fracture',
  'haven',
  'icebox',
  'lotus',
  'pearl',
  'split',
  'summit',
  'sunset',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('audits bundled svg-height models', () async {
    final only = Platform.environment['ICARUS_AUDIT_MAPS']?.split(',');
    final sides = Platform.environment['ICARUS_AUDIT_SIDES']?.split(',') ??
        ['attack', 'defense'];
    final report = StringBuffer();
    final summary = <Map<String, Object>>[];
    for (final map in maps) {
      if (only != null && !only.contains(map)) continue;
      for (final side in sides) {
        final audit = SvgHeightMapAudit.load(map, side);
        audit.run();
        report.writeln(audit.summary());
        summary.add(audit.summaryJson());
        await audit.render(File('build/svg_height_audit_${map}_$side.png'));
        File('build/svg_height_audit_${map}_$side.json')
            .writeAsStringSync(jsonEncode(audit.findingsJson()));
      }
    }
    File('build/svg_height_audit_summary.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(summary));
    // ignore: avoid_print
    print(report);
  }, timeout: const Timeout(Duration(minutes: 30)));
}

class SvgHeightMapAudit {
  SvgHeightMapAudit(this.map, this.side, this.model);

  static SvgHeightMapAudit load(String map, String side) {
    final path = 'assets/maps/${map}_svg_height_$side.json.gz';
    final model = SvgHeightVisibility.fromJson(
        jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
    return SvgHeightMapAudit(map, side, model);
  }

  final String map, side;
  final SvgHeightVisibility model;

  static const gridStep = 2.0;
  static const levelJumpMeters = 0.4;
  static const ledgeDropMeters = 0.8;
  static const continuousGroundMeters = 0.8;
  static const slopeProbe = 8.0;
  static const rampSlopeMeters = 0.5;

  late ui.Rect bounds;
  late int cols, rows;
  late List<double> eyeAt; // NaN where not a floor cell
  int floorCells = 0;
  final levelJumps = <_LevelJump>[];
  final blocksFromAbove = <_EdgeFinding>[];
  final floorLineWalls = <_EdgeFinding>[];
  final tallWallsInFloor = <_EdgeFinding>[];

  double get camera => model.defaultCameraHeightMeters;

  double? eyeFor(ui.Offset p) => levelFor(p)?.eye;

  ({double eye, double ground, SvgHeightSupport? support})? levelFor(
      ui.Offset p) {
    if (!model.receiverContains(p)) return null;
    final ground = model.ground?.heightAt(p);
    if (ground == null) return null;
    final support = model.standingSupportAt(p);
    final surface = support?.surfaceElevationAt(p) ?? ground;
    return (eye: surface + camera, ground: ground, support: support);
  }

  /// Cells whose automatic level sits far from the ground under them, by the
  /// support that put it there. A support 20 m above the floor lifts the eye
  /// over every wall on the map.
  final elevatedCellsBySupport = <String, int>{};
  final elevatedSupportOffset = <String, double>{};
  static const elevatedMeters = 3.0;

  /// Cells whose automatic level is below the reference ground under them:
  /// the player would be standing inside the floor. By the support chosen.
  final buriedCellsBySupport = <String, int>{};
  static const buriedMeters = 1.0;

  bool separated(ui.Offset a, ui.Offset b, double eye) {
    final delta = b - a;
    final hit = model.castRay(
        origin: a,
        directionRadians: math.atan2(delta.dy, delta.dx),
        range: delta.distance,
        absoluteEyeElevationMeters: eye);
    return hit != null;
  }

  void run() {
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    for (final r in model.receivers) {
      left = math.min(left, r.bounds.left);
      top = math.min(top, r.bounds.top);
      right = math.max(right, r.bounds.right);
      bottom = math.max(bottom, r.bounds.bottom);
    }
    bounds = ui.Rect.fromLTRB(left, top, right, bottom);
    cols = (bounds.width / gridStep).ceil() + 1;
    rows = (bounds.height / gridStep).ceil() + 1;
    eyeAt = List<double>.filled(cols * rows, double.nan);
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final p = cell(col, row);
        final level = levelFor(p);
        if (level == null) continue;
        eyeAt[row * cols + col] = level.eye;
        floorCells++;
        final support = level.support;
        if (support != null) {
          final offset = level.eye - camera - level.ground;
          if (offset.abs() >= elevatedMeters) {
            elevatedCellsBySupport.update(support.id, (n) => n + 1,
                ifAbsent: () => 1);
            elevatedSupportOffset[support.id] = offset;
          }
          if (offset <= -buriedMeters) {
            buriedCellsBySupport.update(support.id, (n) => n + 1,
                ifAbsent: () => 1);
          }
        }
      }
    }
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final a = eyeAt[row * cols + col];
        if (a.isNaN) continue;
        for (final (dr, dc) in const [(0, 1), (1, 0)]) {
          final nr = row + dr, nc = col + dc;
          if (nr >= rows || nc >= cols) continue;
          final b = eyeAt[nr * cols + nc];
          if (b.isNaN || (a - b).abs() < levelJumpMeters) continue;
          final pa = cell(col, row), pb = cell(nc, nr);
          if (separated(pa, pb, a) || separated(pb, pa, b)) continue;
          levelJumps.add(_LevelJump((pa + pb) / 2, a - camera, b - camera));
        }
      }
    }
    for (var w = 0; w < model.walls.length; w++) {
      final wall = model.walls[w];
      for (final ring in wall.rings) {
        for (var i = 0; i < ring.length; i++) {
          final a = ring[i], b = ring[(i + 1) % ring.length];
          final edge = b - a;
          final length = edge.distance;
          if (length < 1.0) continue;
          final mid = (a + b) / 2;
          final normal = ui.Offset(-edge.dy, edge.dx) / length;
          _inspectEdge(wall, mid, normal, length);
        }
      }
    }
  }

  void _inspectEdge(
      SvgHeightWall wall, ui.Offset mid, ui.Offset normal, double length) {
    // Probe just outside the ink on both sides; the wall footprint itself
    // has stroke thickness so step past it.
    ui.Offset? outside(double sign) {
      for (final d in const [0.6, 1.2, 2.0]) {
        final p = mid + normal * (sign * d);
        if (!wall.contains(p)) return p;
      }
      return null;
    }

    final p1 = outside(1), p2 = outside(-1);
    if (p1 == null || p2 == null) return;
    if (!model.receiverContains(p1) || !model.receiverContains(p2)) return;
    final g1 = model.ground?.heightAt(p1), g2 = model.ground?.heightAt(p2);
    if (g1 == null || g2 == null) return;
    final high = math.max(g1, g2), low = math.min(g1, g2);
    final highPoint = g1 >= g2 ? p1 : p2;
    final bandTop = wall.bands.isEmpty
        ? double.infinity
        : wall.bands
            .map((b) => (wall.floorElevationMeters ?? 0) + b.top)
            .reduce(math.max);
    if (high - low >= ledgeDropMeters) {
      final highEye = eyeFor(highPoint);
      if (highEye != null && wall.blocks(highEye)) {
        blocksFromAbove.add(
            _EdgeFinding(wall.id, mid, length, high, low, bandTop, highEye));
      }
      return;
    }
    if (high - low > continuousGroundMeters) return;
    final eye1 = eyeFor(p1), eye2 = eyeFor(p2);
    if (eye1 == null || eye2 == null) return;
    if (!wall.blocks(eye1) || !wall.blocks(eye2)) return;
    // Tall wall drawn inside the floor with the same ground on both sides.
    final finding =
        _EdgeFinding(wall.id, mid, length, high, low, bandTop, eye1);
    tallWallsInFloor.add(finding);
    // Ramp/stair marking: ground climbs away from the line on one side.
    for (final sign in const [1.0, -1.0]) {
      final far = mid + normal * (sign * slopeProbe);
      final gf = model.ground?.heightAt(far);
      if (gf == null || !model.receiverContains(far)) continue;
      final near = sign > 0 ? g1 : g2;
      if ((gf - near).abs() >= rampSlopeMeters) {
        floorLineWalls.add(finding);
        break;
      }
    }
  }

  /// Wall ids are fragments of one painted stroke: `p7-stroke-7-...`.
  static String strokeOf(String wallId) {
    final parts = wallId.split('-');
    return parts.length >= 3 ? parts.take(3).join('-') : wallId;
  }

  ui.Offset cell(int col, int row) =>
      ui.Offset(bounds.left + col * gridStep, bounds.top + row * gridStep);

  double _length(Iterable<_EdgeFinding> f) =>
      f.fold(0.0, (s, e) => s + e.length);

  String summary() {
    final b = StringBuffer()
      ..writeln('=== $map $side  walls=${model.walls.length} '
          'supports=${model.supports.length} floorCells=$floorCells')
      ..writeln('  level jumps (no wall between, >= ${levelJumpMeters}m): '
          '${levelJumps.length}')
      ..writeln('  blocks-from-above edges: ${blocksFromAbove.length} '
          '(${_length(blocksFromAbove).round()} svg units)')
      ..writeln('  tall walls inside floor: ${tallWallsInFloor.length} edges '
          '(${_length(tallWallsInFloor).round()} svg units); '
          'beside a slope: ${floorLineWalls.length} '
          '(${_length(floorLineWalls).round()} svg units)');
    final elevatedCells =
        elevatedCellsBySupport.values.fold<int>(0, (s, n) => s + n);
    b.writeln('  cells standing >= ${elevatedMeters}m off the ground: '
        '$elevatedCells on ${elevatedCellsBySupport.length} supports');
    final buriedCells =
        buriedCellsBySupport.values.fold<int>(0, (s, n) => s + n);
    b.writeln('  cells standing >= ${buriedMeters}m BELOW the ground: '
        '$buriedCells on ${buriedCellsBySupport.length} supports');
    final rankedBuried = buriedCellsBySupport.entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    for (final entry in rankedBuried.take(8)) {
      final support = model.supports.firstWhere((s) => s.id == entry.key);
      b.writeln(
          '    buried ${entry.key} "${support.label}" cells=${entry.value} '
          'surface=${support.surfaceElevationMeters?.toStringAsFixed(1)} '
          'at (${support.bounds.center.dx.round()},${support.bounds.center.dy.round()}) '
          'size=${support.bounds.width.round()}x${support.bounds.height.round()}');
    }
    final rankedSupports = elevatedCellsBySupport.entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    for (final entry in rankedSupports.take(6)) {
      final support = model.supports.firstWhere((s) => s.id == entry.key);
      b.writeln(
          '    support ${entry.key} "${support.label}" cells=${entry.value} '
          'offset=${elevatedSupportOffset[entry.key]!.toStringAsFixed(1)}m '
          'at (${support.bounds.center.dx.round()},${support.bounds.center.dy.round()}) '
          'size=${support.bounds.width.round()}x${support.bounds.height.round()}');
    }
    final byWall = <String, List<_EdgeFinding>>{};
    for (final f in floorLineWalls) {
      (byWall[strokeOf(f.wallId)] ??= []).add(f);
    }
    final ranked = byWall.entries.toList()
      ..sort((x, y) => _length(y.value).compareTo(_length(x.value)));
    for (final entry in ranked.take(8)) {
      final f = entry.value.first;
      b.writeln(
          '    ramp-line? ${entry.key} len=${_length(entry.value).round()} '
          'at (${f.mid.dx.round()},${f.mid.dy.round()}) ground=${f.high.toStringAsFixed(1)} '
          'bandTop=${f.bandTop.toStringAsFixed(1)} eye=${f.eye.toStringAsFixed(1)}');
    }
    final byLedge = <String, List<_EdgeFinding>>{};
    for (final f in blocksFromAbove) {
      (byLedge[strokeOf(f.wallId)] ??= []).add(f);
    }
    final rankedLedges = byLedge.entries.toList()
      ..sort((x, y) => _length(y.value).compareTo(_length(x.value)));
    for (final entry in rankedLedges.take(8)) {
      final f = entry.value.first;
      b.writeln(
          '    ledge-blocks? ${entry.key} len=${_length(entry.value).round()} '
          'at (${f.mid.dx.round()},${f.mid.dy.round()}) high=${f.high.toStringAsFixed(1)} '
          'low=${f.low.toStringAsFixed(1)} bandTop=${f.bandTop.toStringAsFixed(1)}');
    }
    final jumpsSorted = [...levelJumps]
      ..sort((x, y) => (y.a - y.b).abs().compareTo((x.a - x.b).abs()));
    for (final j in jumpsSorted.take(6)) {
      b.writeln('    jump (${j.at.dx.round()},${j.at.dy.round()}) '
          '${j.a.toStringAsFixed(2)} <-> ${j.b.toStringAsFixed(2)}');
    }
    return b.toString();
  }

  Map<String, Object> summaryJson() => {
        'map': map,
        'side': side,
        'floorCells': floorCells,
        'levelJumps': levelJumps.length,
        'blocksFromAboveEdges': blocksFromAbove.length,
        'blocksFromAboveLength': _length(blocksFromAbove),
        'tallWallsInFloorEdges': tallWallsInFloor.length,
        'floorLineEdges': floorLineWalls.length,
        'floorLineLength': _length(floorLineWalls),
        'elevatedCells':
            elevatedCellsBySupport.values.fold<int>(0, (s, n) => s + n),
        'elevatedSupports': elevatedCellsBySupport.length,
        'buriedCells':
            buriedCellsBySupport.values.fold<int>(0, (s, n) => s + n),
        'buriedSupports': buriedCellsBySupport.length,
        'buriedSupportIds': buriedCellsBySupport.keys.toList(),
      };

  Map<String, Object> findingsJson() => {
        'levelJumps': [
          for (final j in levelJumps)
            {'x': j.at.dx, 'y': j.at.dy, 'a': j.a, 'b': j.b}
        ],
        'blocksFromAbove': [for (final f in blocksFromAbove) f.toJson()],
        'floorLineWalls': [for (final f in floorLineWalls) f.toJson()],
      };

  Future<void> render(File output) async {
    const scale = 3.0;
    final area = bounds.inflate(6);
    final size = ui.Size(area.width * scale, area.height * scale);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawRect(
          ui.Offset.zero & size, ui.Paint()..color = const ui.Color(0xff141414))
      ..translate(-area.left * scale, -area.top * scale)
      ..scale(scale);
    for (final r in model.receivers) {
      canvas.drawPath(_path(r.rings, r.evenOdd),
          ui.Paint()..color = const ui.Color(0xff2b2b2b));
    }
    // Standing eye as a heat layer: blue low .. yellow high.
    final eyes = eyeAt.where((e) => !e.isNaN).toList()..sort();
    if (eyes.isNotEmpty) {
      final lo = eyes[(eyes.length * 0.02).floor()];
      final hi = eyes[(eyes.length * 0.98).floor()];
      for (var row = 0; row < rows; row++) {
        for (var col = 0; col < cols; col++) {
          final e = eyeAt[row * cols + col];
          if (e.isNaN) continue;
          final t = ((e - lo) / math.max(0.01, hi - lo)).clamp(0.0, 1.0);
          final c = ui.Color.lerp(
              const ui.Color(0xff1d4ed8), const ui.Color(0xfffacc15), t)!;
          canvas.drawRect(
              ui.Rect.fromLTWH(bounds.left + col * gridStep - 1,
                  bounds.top + row * gridStep - 1, gridStep, gridStep),
              ui.Paint()..color = c.withValues(alpha: 0.35));
        }
      }
    }
    final wallPaint = ui.Paint()
      ..color = const ui.Color(0xffb27c40)
      ..style = ui.PaintingStyle.fill;
    for (final w in model.walls) {
      canvas.drawPath(_path(w.rings, w.evenOdd), wallPaint);
    }
    void mark(Iterable<_EdgeFinding> findings, ui.Color color, double width) {
      final paint = ui.Paint()
        ..color = color
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = width;
      for (final f in findings) {
        canvas.drawCircle(f.mid, math.max(1.2, f.length / 2), paint);
      }
    }

    mark(tallWallsInFloor, const ui.Color(0x80f97316), 0.5);
    mark(floorLineWalls, const ui.Color(0xffef4444), 0.8);
    mark(blocksFromAbove, const ui.Color(0xffa855f7), 0.8);
    for (final j in levelJumps) {
      canvas.drawCircle(
          j.at, 1.0, ui.Paint()..color = const ui.Color(0xffffffff));
    }
    final image = await recorder
        .endRecording()
        .toImage(size.width.ceil(), size.height.ceil());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
  }

  static ui.Path _path(List<List<ui.Offset>> rings, bool evenOdd) {
    final path = ui.Path()
      ..fillType = evenOdd ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;
    for (final ring in rings) {
      path.addPolygon(ring, true);
    }
    return path;
  }
}

class _LevelJump {
  _LevelJump(this.at, this.a, this.b);
  final ui.Offset at;
  final double a, b;
}

class _EdgeFinding {
  _EdgeFinding(this.wallId, this.mid, this.length, this.high, this.low,
      this.bandTop, this.eye);
  final String wallId;
  final ui.Offset mid;
  final double length, high, low, bandTop, eye;
  Map<String, Object> toJson() => {
        'wall': wallId,
        'x': mid.dx,
        'y': mid.dy,
        'length': length,
        'groundHigh': high,
        'groundLow': low,
        'bandTop': bandTop,
        'eye': eye,
      };
}
