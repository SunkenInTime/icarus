import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/vision_occluders.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

/// Every view cone of a replay moment in one layer, drawn as the editor
/// draws a placed cone (the same cut, gradient and clip to the painted
/// floor) but clipped to the floor once for all of them, from cuts made off
/// the UI thread. A cut lagging its agent is carried along and turned with
/// it. Smokes and smoke walls are erased from each cone they hide part of.
class ReplayConesPainter extends CustomPainter {
  ReplayConesPainter({
    required this.cones,
    required this.occluders,
    required this.model,
    required this.map,
    required this.isAttack,
  });

  final Iterable<ReplayConeSource> cones;
  final List<VisionOccluder> occluders;

  /// The side's height model the cuts were made in.
  final SvgHeightVisibility model;
  final MapValue map;
  final bool isAttack;

  static final _conePaths = Expando<Path>();
  static final _floors = Expando<(Size, Float64List, Path)>();

  /// The editor's cone fill, see [SvgHeightViewConePainter].
  static const _coneGrey = Color.fromARGB(255, 147, 147, 147);

  @override
  void paint(Canvas canvas, Size size) {
    final coordinates = CoordinateSystem.instance;
    final transform = SvgHeightMapTransform.forMap(map);
    // Height-model space to the canvas: an even scale and an offset.
    final scale = coordinates.worldHeightToScreen(transform.scale);
    final toScreen = (Offset source) => coordinates.coordinateToScreen(
        transform.sideWorldFromSource(source, isAttack: isAttack));
    final shift = toScreen(Offset.zero);
    final sourceToScreen = Float64List(16)
      ..[0] = scale
      ..[5] = scale
      ..[10] = 1
      ..[12] = shift.dx
      ..[13] = shift.dy
      ..[15] = 1;

    canvas.save();
    // Cone pixels never land off the painted floor, nor in its holes. The
    // fill is faint at any floor edge, which wall ink mostly covers, so a
    // hard edge reads the same and spares an antialiased mask every frame.
    canvas.clipPath(_floor(size, sourceToScreen), doAntiAlias: false);
    for (final (:aim, :cut) in cones) {
      final cone = cut?.cone;
      final origin = cut?.origin;
      if (cut == null || cone == null || origin == null) continue;
      if (cone.polygon.length < 3) continue;
      final reach = _range(transform);
      // Where the agent stands now, in height-model space. Smokes do not
      // move with a lagging cut, so they are judged from here.
      final standing = _source(aim.origin, transform);
      final shadows =
          occluders.isEmpty ? null : _shadows(standing, reach, transform);
      if (shadows == _blind) continue;
      // The cut's origin lands on the agent, turned to their facing: as the
      // editor draws a cone, whose apex is the agent even when its cut was
      // made from a point nudged out of wall ink.
      final apex = toScreen(standing);
      final turn =
          coordinates.rotationForSide(aim.rotation, isAttack: isAttack) -
              coordinates.rotationForSide(cut.aim.rotation, isAttack: isAttack);
      final from = toScreen(origin);
      if (shadows != null) {
        canvas.saveLayer(
            Rect.fromCircle(center: apex, radius: reach * scale), Paint());
      }
      canvas.save();
      canvas.translate(apex.dx, apex.dy);
      canvas.rotate(turn);
      canvas.translate(-from.dx, -from.dy);
      canvas.transform(sourceToScreen);
      // The cut lies within reach, so filling it with the editor's gradient
      // is the editor's clipped circle, without a clip mask per cone.
      final reachRect = Rect.fromCircle(center: origin, radius: reach);
      paintSvgConeArea(
        canvas,
        cone,
        _conePaths[cone] ??= Path()..addPolygon(cone.polygon, true),
        Paint()
          ..shader = RadialGradient(
            colors: [_coneGrey.withValues(alpha: .5), Colors.transparent],
          ).createShader(reachRect),
        reachRect,
      );
      canvas.restore();
      if (shadows != null) {
        canvas.save();
        canvas.transform(sourceToScreen);
        canvas.drawPath(shadows, Paint()..blendMode = BlendMode.clear);
        canvas.restore();
        canvas.restore();
      }
    }
    canvas.restore();
  }

  /// A view cone's reach in height-model space.
  static double _range(SvgHeightMapTransform transform) =>
      CoordinateSystem.virtualLengthInWorld(ReplayFrameBuilder.coneLength) /
      transform.scale;

  Offset _source(Offset canonical, SvgHeightMapTransform transform) =>
      transform.sourceFromSideWorld(
        CoordinateSystem.instance.positionForSide(
          canonicalPosition: canonical,
          reflectionOffset: Offset.zero,
          isAttack: isAttack,
        ),
        isAttack: isAttack,
      );

  static final _blind = Path();

  /// What the occluders within reach hide from [origin], in height-model
  /// space; [_blind] when [origin] stands in a smoke.
  Path? _shadows(Offset origin, double reach, SvgHeightMapTransform transform) {
    final near = [
      for (final occluder in occluders)
        switch (occluder) {
          CircleOccluder() =>
            occluder.map((p) => _source(p, transform), 1 / transform.scale),
          LineOccluder() => occluder.map((p) => _source(p, transform)),
        },
    ].where((occluder) => occluder.reaches(origin, reach)).toList();
    if (near.isEmpty) return null;
    if (standsInsideSmoke(origin, near)) return _blind;
    return occluderShadows(origin, reach, near);
  }

  /// The painted floor on the canvas, built once per canvas size and side.
  Path _floor(Size size, Float64List sourceToScreen) {
    final cached = _floors[model];
    if (cached != null &&
        cached.$1 == size &&
        cached.$2[0] == sourceToScreen[0] &&
        cached.$2[12] == sourceToScreen[12] &&
        cached.$2[13] == sourceToScreen[13]) {
      return cached.$3;
    }
    Path? floor;
    for (final receiver in model.receivers) {
      final next = SvgHeightViewConePainter.ringsPath(receiver.rings,
          evenOdd: receiver.evenOdd);
      floor =
          floor == null ? next : Path.combine(PathOperation.union, floor, next);
    }
    final screen = (floor ?? Path()).transform(sourceToScreen);
    _floors[model] = (size, sourceToScreen, screen);
    return screen;
  }

  @override
  bool shouldRepaint(ReplayConesPainter oldDelegate) => true;
}
