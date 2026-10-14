import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/vision_occluders.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

/// Every view cone of a replay moment in one layer, drawn as the editor
/// draws placed cones (the same cut, opaque where each reaches, as the mask
/// a [RevealedFloor] shows the revealed map through; see
/// `lib/view_cone/cone_coverage.dart`), from cuts made off the UI thread. A
/// cut lagging its agent is carried along and turned with it. Smokes and
/// smoke walls are erased from each cone they hide part of.
///
/// Cones are not clipped to the painted floor here: the revealed map is,
/// once, with the map (see [RevealedFloor]). On Windows the engine can only
/// clip to a shape that complex with a mask drawn on the CPU, which with
/// cones moving every frame cost more than the cones themselves.
class ReplayConesPainter extends CustomPainter {
  ReplayConesPainter({
    required this.cones,
    required this.occluders,
    required this.model,
    required this.map,
    required this.isAttack,
    required this.apertureDegrees,
  });

  final Iterable<ReplayConeSource> cones;
  final List<VisionOccluder> occluders;

  /// The side's height model the cuts were made in.
  final SvgHeightVisibility model;
  final MapValue map;
  final bool isAttack;

  /// The cones' spread; cuts see all the way round.
  final double apertureDegrees;

  static final _conePaths = Expando<Path>();

  /// Where a cone reaches, for [RevealedFloor] to show the revealed map.
  static final _reach = Paint()..color = const Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final coordinates = CoordinateSystem.instance;
    final transform = SvgHeightMapTransform.forMap(map);
    // Height-model space to the canvas: an even scale and an offset.
    final scale = coordinates.worldHeightToScreen(transform.scale);
    final toScreen = (Offset source) => coordinates.coordinateToScreen(
        transform.sideWorldFromSource(source, isAttack: isAttack));
    final sourceToScreen = transform.sourceToScreen(isAttack: isAttack);
    for (final (:aim, :cut, :sight) in cones) {
      final cone = cut?.cone;
      final origin = cut?.origin;
      if (cut == null || cone == null || origin == null) continue;
      if (cone.polygon.length < 3) continue;
      // A flashed player's cone reaches only as far as they can see.
      final reach = _range(transform) * sight;
      // Where the agent stands now, in height-model space. Smokes do not
      // move with a lagging cut, so they are judged from here.
      final standing = _source(aim.origin, transform);
      final shadows =
          occluders.isEmpty ? null : _shadows(standing, reach, transform);
      if (shadows == _blind) continue;
      // The cut's origin lands on the agent, as the editor draws a cone,
      // whose apex is the agent even when its cut was made from a point
      // nudged out of wall ink. The cut sees all the way round; the wedge
      // the agent faces is cut from it here, so turning is never stale.
      final apex = toScreen(standing);
      final from = toScreen(origin);
      final facing =
          coordinates.rotationForSide(aim.rotation, isAttack: isAttack) -
              math.pi / 2;
      if (shadows != null) {
        canvas.saveLayer(
            Rect.fromCircle(center: apex, radius: reach * scale), Paint());
      }
      canvas.save();
      canvas.clipPath(_wedge(apex, facing, reach * scale));
      canvas.translate(apex.dx - from.dx, apex.dy - from.dy);
      canvas.transform(sourceToScreen);
      // The wedge clip already stops the cut at reach.
      final reachRect = Rect.fromCircle(center: origin, radius: reach);
      paintSvgConeArea(
        canvas,
        cone,
        _conePaths[cone] ??= Path()..addPolygon(cone.polygon, true),
        _reach,
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
  }

  /// The sector an agent at [apex] facing [facing] sees, out to [radius].
  Path _wedge(Offset apex, double facing, double radius) {
    const steps = 48;
    final aperture = apertureDegrees * math.pi / 180;
    return Path()
      ..addPolygon([
        apex,
        for (var i = 0; i <= steps; i++)
          apex +
              Offset.fromDirection(
                  facing - aperture / 2 + aperture * i / steps, radius),
      ], true);
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

  @override
  bool shouldRepaint(ReplayConesPainter oldDelegate) => true;
}
