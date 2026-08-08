import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('renders representative miter corners for every map without bleed',
      () async {
    const labelWidth = 90.0;
    const tileWidth = 170.0;
    const tileHeight = 130.0;
    const columns = 4;
    final rows = MapValue.values.length;
    final size = ui.Size(
      labelWidth + tileWidth * columns,
      tileHeight * rows,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xff100a07),
    );

    var auditedCorners = 0;
    for (var mapIndex = 0; mapIndex < MapValue.values.length; mapIndex += 1) {
      final map = MapValue.values[mapIndex];
      final boundary = SvgVisionBoundary.parse(
        map: map,
        source: await rootBundle.loadString(
          'assets/maps/${Maps.mapNames[map]}_map.svg',
        ),
      );
      final corners = _representativeCorners(boundary, columns);
      expect(corners, hasLength(columns), reason: map.name);
      auditedCorners += corners.length;

      _drawLabel(canvas, map.name, ui.Offset(8, mapIndex * tileHeight + 52));
      for (var column = 0; column < corners.length; column += 1) {
        _drawCorner(
          canvas,
          corners[column],
          ui.Offset(
            labelWidth + column * tileWidth,
            mapIndex * tileHeight,
          ),
        );
      }
    }

    expect(auditedCorners, MapValue.values.length * columns);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(raw, isNotNull);
    var overlapPixels = 0;
    for (var index = 0; index < raw!.lengthInBytes; index += 4) {
      final red = raw.getUint8(index);
      final green = raw.getUint8(index + 1);
      final blue = raw.getUint8(index + 2);
      // Gray over the gold wall produces this otherwise-unused color range.
      // Edge antialiasing is included, so zero means even coverage fringes
      // remain separated in the rendered result.
      if (red > 120 && red < 170 && green > 105 && blue > 75) {
        overlapPixels += 1;
      }
    }
    expect(overlapPixels, 0,
        reason: 'gray cone pixels covered gold wall pixels');
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);
    final output = File('build/vision_corner_audit.png');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  });
}

class _CornerCase {
  const _CornerCase({
    required this.incoming,
    required this.outgoing,
    required this.join,
    required this.outerEdge,
    required this.turnAngle,
  });

  final VisionSegment incoming;
  final VisionSegment outgoing;
  final ui.Offset join;
  final VisionSegment outerEdge;
  final double turnAngle;
}

List<_CornerCase> _representativeCorners(
  VisionBoundary boundary,
  int count,
) {
  final candidates = <_CornerCase>[];
  for (final group in boundary.collisionGroups) {
    for (final path in group.paths) {
      if (path.length < 3) continue;
      final radius = group.segments
          .where((segment) => segment.collisionRadius > 1e-9)
          .map((segment) => segment.collisionRadius)
          .firstOrNull;
      if (radius == null) continue;
      final isClosed =
          (path.first - path.last).distanceSquared <= 0.001 * 0.001;
      final segmentCount = path.length - 1;
      final joinCount = isClosed ? segmentCount : segmentCount - 1;
      for (var index = 0; index < joinCount; index += 1) {
        final incoming = VisionSegment(
          path[index],
          path[index + 1],
          collisionRadius: radius,
        );
        final outgoing = VisionSegment(
          path[(index + 1) % segmentCount],
          path[(index + 2) % segmentCount],
          collisionRadius: radius,
        );
        final turn = visionCross(incoming.tangent, outgoing.tangent);
        if (turn.abs() <= 0.01) continue;
        final outside = turn > 0 ? -1.0 : 1.0;
        final join = incoming.end;
        final incomingOuter = join + incoming.normal * (outside * radius);
        final outgoingOuter = join + outgoing.normal * (outside * radius);
        final distanceAlongIncoming =
            visionCross(outgoingOuter - incomingOuter, outgoing.tangent) / turn;
        final miter = incomingOuter + incoming.tangent * distanceAlongIncoming;
        final ratio = (miter - join).distance / radius;
        if (!ratio.isFinite || ratio > 4) continue;
        final firstEdge = VisionSegment(incomingOuter, miter);
        final secondEdge = VisionSegment(miter, outgoingOuter);
        final edge =
            firstEdge.length >= secondEdge.length ? firstEdge : secondEdge;
        candidates.add(
          _CornerCase(
            incoming: incoming,
            outgoing: outgoing,
            join: join,
            outerEdge: edge,
            turnAngle: math.acos(
              (incoming.tangent.dx * outgoing.tangent.dx +
                      incoming.tangent.dy * outgoing.tangent.dy)
                  .clamp(-1.0, 1.0),
            ),
          ),
        );
      }
    }
  }

  final targets = <double>[
    math.pi / 6,
    math.pi / 3,
    math.pi / 2,
    math.pi * 3 / 4,
  ];
  final selected = <_CornerCase>[];
  for (final target in targets.take(count)) {
    final remaining =
        candidates.where((candidate) => !selected.contains(candidate));
    if (remaining.isEmpty) break;
    selected.add(
      remaining.reduce(
        (best, candidate) => (candidate.turnAngle - target).abs() <
                (best.turnAngle - target).abs()
            ? candidate
            : best,
      ),
    );
  }
  return selected;
}

void _drawCorner(ui.Canvas canvas, _CornerCase corner, ui.Offset tileOrigin) {
  const tileSize = ui.Size(170, 130);
  final radius = corner.incoming.collisionRadius;
  final edge = corner.outerEdge;
  final edgeMidpoint = (edge.start + edge.end) / 2;
  var outward = ui.Offset(-edge.delta.dy, edge.delta.dx) / edge.length;
  if ((edgeMidpoint - corner.join).dx * outward.dx +
          (edgeMidpoint - corner.join).dy * outward.dy <
      0) {
    outward = -outward;
  }
  final origin = edgeMidpoint + outward * (radius * 12);
  final facing = math.atan2(
    edgeMidpoint.dy - origin.dy,
    edgeMidpoint.dx - origin.dx,
  );
  final group = VisionCollisionGroup.geometry(
    points: [corner.incoming.start, corner.join, corner.outgoing.end],
    kind: VisionCollisionKind.structuralChain,
    isClosed: false,
    collisionRadius: radius,
  );
  final polygon = VisionPolygon.compute(
    layer: VisionGeometryLayer(
      elevation: 0,
      segments: group.collisionSegments,
    ),
    origin: origin,
    facingAngle: facing,
    coneAngle: math.pi / 3,
    range: radius * 20,
    surfaceClearance: 0.5 / (5 / radius),
  );

  final scale = 5 / radius;
  final rotation = math.pi - facing;
  final cosine = math.cos(rotation);
  final sine = math.sin(rotation);
  final target = tileOrigin + const ui.Offset(82, 65);
  ui.Offset project(ui.Offset point) {
    final delta = point - edgeMidpoint;
    return target +
        ui.Offset(
              delta.dx * cosine - delta.dy * sine,
              delta.dx * sine + delta.dy * cosine,
            ) *
            scale;
  }

  canvas.save();
  canvas.clipRect(tileOrigin & tileSize);
  canvas.drawRect(
    tileOrigin & tileSize,
    ui.Paint()..color = const ui.Color(0xff271406),
  );
  final wall = ui.Path()
    ..moveTo(
      project(corner.incoming.start).dx,
      project(corner.incoming.start).dy,
    )
    ..lineTo(project(corner.join).dx, project(corner.join).dy)
    ..lineTo(
      project(corner.outgoing.end).dx,
      project(corner.outgoing.end).dy,
    );
  canvas.drawPath(
    wall,
    ui.Paint()
      ..color = const ui.Color(0xffb27c40)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = radius * 2 * scale
      ..strokeJoin = ui.StrokeJoin.miter
      ..strokeCap = ui.StrokeCap.butt,
  );

  if (polygon.length >= 3) {
    final cone = ui.Path()
      ..moveTo(project(polygon.first).dx, project(polygon.first).dy);
    for (final point in polygon.skip(1)) {
      cone.lineTo(project(point).dx, project(point).dy);
    }
    cone.close();
    canvas.drawPath(
      cone,
      ui.Paint()..color = const ui.Color(0x997d7976),
    );
  }
  canvas.restore();
}

void _drawLabel(ui.Canvas canvas, String text, ui.Offset offset) {
  final paragraph = (ui.ParagraphBuilder(
    ui.ParagraphStyle(fontSize: 14, maxLines: 1),
  )
        ..pushStyle(ui.TextStyle(color: const ui.Color(0xffeeeeee)))
        ..addText(text))
      .build()
    ..layout(const ui.ParagraphConstraints(width: 78));
  canvas.drawParagraph(paragraph, offset);
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
