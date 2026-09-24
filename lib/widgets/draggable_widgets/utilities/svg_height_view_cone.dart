import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/map_artwork_registration.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

class SvgHeightMapTransform {
  SvgHeightMapTransform._(this.map)
      : viewBox = Maps.mapViewBox[map]!,
        defenseArtworkOffset = mapDefenseArtworkOffsetSvg[map]! {
    scale = math.min(mapWidth / viewBox.width, worldHeight / viewBox.height);
    offset = Offset(
      (worldWidth - viewBox.width * scale) / 2,
      (worldHeight - viewBox.height * scale) / 2,
    );
  }

  static const worldHeight = 1000.0;
  static const mapWidth = worldHeight * CoordinateSystem.defaultMapAspectRatio;
  static const worldWidth = worldHeight * 16 / 9;
  static final _transforms = <MapValue, SvgHeightMapTransform>{};

  factory SvgHeightMapTransform.forMap(MapValue map) =>
      _transforms.putIfAbsent(map, () => SvgHeightMapTransform._(map));

  final MapValue map;
  final Size viewBox;
  final Offset defenseArtworkOffset;
  late final double scale;
  late final Offset offset;

  Offset sourceFromSideWorld(Offset point, {required bool isAttack}) =>
      (point - offset) / scale +
      (isAttack ? Offset.zero : defenseArtworkOffset);

  Offset sideWorldFromSource(Offset point, {required bool isAttack}) =>
      offset +
      (point - (isAttack ? Offset.zero : defenseArtworkOffset)) * scale;
}

/// Compatibility accessors for Split-specific tests and audit tools.
class SplitSvgMapTransform {
  const SplitSvgMapTransform._();

  static final _transform = SvgHeightMapTransform.forMap(MapValue.split);
  static Size get viewBox => _transform.viewBox;
  static double get worldHeight => SvgHeightMapTransform.worldHeight;
  static double get mapWidth => SvgHeightMapTransform.mapWidth;
  static double get worldWidth => SvgHeightMapTransform.worldWidth;
  static double get scale => _transform.scale;
  static Offset get offset => _transform.offset;

  static Offset sourceFromSideWorld(Offset point, {required bool isAttack}) =>
      _transform.sourceFromSideWorld(point, isAttack: isAttack);

  static Offset sideWorldFromSource(Offset point, {required bool isAttack}) =>
      _transform.sideWorldFromSource(point, isAttack: isAttack);
}

/// A mounted child owns one cache key. Preview cones with no persisted ID still
/// remain independent, and unmounting removes only that observer's cached cone.
class SvgHeightViewCone extends StatefulWidget {
  const SvgHeightViewCone({
    super.key,
    required this.runtime,
    required this.canonicalOrigin,
    required this.rotation,
    required this.range,
    required this.angle,
    required this.isAttack,
    this.elevation,
    this.opacity = 1,
  });

  final SvgHeightRuntime runtime;
  final Offset canonicalOrigin;
  final double rotation, range, angle;
  final bool isAttack;
  final double? elevation;
  final double opacity;

  @override
  State<SvgHeightViewCone> createState() => _SvgHeightViewConeState();
}

class _SvgHeightViewConeState extends State<SvgHeightViewCone> {
  static final _receiverPaths = Expando<Path>();
  final _observer = Object();
  Object? _paintInputs;
  SvgHeightViewConePainter? _painter;
  Object? _receiverKey;
  Path? _rotatedReceiver;

  @override
  void didUpdateWidget(SvgHeightViewCone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.isAttack != widget.isAttack) {
      oldWidget.runtime.cache(oldWidget.isAttack).removeObserver(_observer);
    }
  }

  @override
  void dispose() {
    widget.runtime.cache(widget.isAttack).removeObserver(_observer);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coordinates = CoordinateSystem.instance;
    final model = widget.runtime.model(widget.isAttack);
    final mapTransform = SvgHeightMapTransform.forMap(widget.runtime.map);
    final sideOrigin = coordinates.positionForSide(
      canonicalPosition: widget.canonicalOrigin,
      reflectionOffset: Offset.zero,
      isAttack: widget.isAttack,
    );
    final rawOrigin =
        mapTransform.sourceFromSideWorld(sideOrigin, isAttack: widget.isAttack);
    // An agent hugging a wall has its centre inside the stroke's ink for a
    // few frames at a time. Stand the cone just outside that ink, or just
    // inside the floor edge, rather than blinking it off.
    final sourceOrigin = model.standablePointNear(rawOrigin);
    if (sourceOrigin == null) {
      return const SizedBox.expand();
    }

    final support = model.standingSupportAt(sourceOrigin,
        savedEyeElevationCm: widget.elevation);
    final result = widget.runtime.cache(widget.isAttack).cone(
          observerId: _observer,
          origin: sourceOrigin,
          directionRadians: widget.rotation - math.pi / 2,
          range: widget.range / mapTransform.scale,
          apertureRadians: widget.angle,
          supportId: support?.id,
        );

    final size = Size(
      coordinates.worldHeightToScreen(widget.range) * 2,
      coordinates.worldHeightToScreen(widget.range),
    );
    final paintInputs = (
      result.cone,
      sideOrigin,
      widget.rotation,
      widget.isAttack,
      size,
      coordinates.worldOffsetToScreen(const Offset(1, 1)),
      widget.opacity,
    );
    if (_paintInputs == paintInputs) {
      return RepaintBoundary(child: CustomPaint(size: size, painter: _painter));
    }
    final apex = Offset(size.width / 2, size.height);
    final inverse = -widget.rotation;
    final cosine = math.cos(inverse), sine = math.sin(inverse);

    final sourceReceiver = _receiverPaths[model] ??= _combinedReceiver(model);
    final sx = coordinates.worldWidthToScreen(mapTransform.scale);
    final sy = coordinates.worldHeightToScreen(mapTransform.scale);
    final transform = Float64List(16)
      ..[0] = cosine * sx
      ..[1] = sine * sy
      ..[4] = -sine * sx
      ..[5] = cosine * sy
      ..[10] = 1
      ..[15] = 1;
    transform[12] = apex.dx -
        transform[0] * sourceOrigin.dx -
        transform[4] * sourceOrigin.dy;
    transform[13] = apex.dy -
        transform[1] * sourceOrigin.dx -
        transform[5] * sourceOrigin.dy;
    // During a drag only the translation changes frame to frame. Keep the
    // rotated, scaled receiver path and translate it on the canvas, so the
    // clip path object stays the same and the raster cache can keep it.
    final receiverKey = (model, cosine, sine, sx, sy);
    if (_receiverKey != receiverKey) {
      _receiverKey = receiverKey;
      _rotatedReceiver = sourceReceiver.transform(Float64List(16)
        ..[0] = transform[0]
        ..[1] = transform[1]
        ..[4] = transform[4]
        ..[5] = transform[5]
        ..[10] = 1
        ..[15] = 1);
    }
    _paintInputs = paintInputs;
    _painter = SvgHeightViewConePainter.fromPaths(
      visibility: result.cone.visibilityPath?.transform(transform) ??
          result.cone.outlinePath(transform),
      receiver: _rotatedReceiver!,
      receiverOffset: Offset(transform[12], transform[13]),
      apex: apex,
      radius: coordinates.worldHeightToScreen(widget.range),
      opacity: widget.opacity,
    );
    return RepaintBoundary(child: CustomPaint(size: size, painter: _painter));
  }

  static Path _combinedReceiver(SvgHeightVisibility model) {
    Path? combined;
    for (final receiver in model.receivers) {
      final next = SvgHeightViewConePainter._path(receiver.rings,
          evenOdd: receiver.evenOdd);
      combined = combined == null
          ? next
          : Path.combine(PathOperation.union, combined, next);
    }
    return combined ?? Path();
  }
}

class SvgHeightViewConePainter extends CustomPainter {
  const SvgHeightViewConePainter({
    required this.visibilityPolygon,
    required this.receiverRings,
    required this.receiverEvenOdd,
    required this.apex,
    required this.radius,
    this.opacity = 1,
  })  : receiverOffset = Offset.zero,
        _visibility = null,
        _receiver = null;

  const SvgHeightViewConePainter.fromPaths(
      {required Path visibility,
      required Path receiver,
      required this.apex,
      required this.radius,
      this.receiverOffset = Offset.zero,
      this.opacity = 1})
      : _visibility = visibility,
        _receiver = receiver,
        visibilityPolygon = const [],
        receiverRings = const [],
        receiverEvenOdd = false;

  final Path? _visibility, _receiver;

  final List<Offset> visibilityPolygon;
  final List<List<Offset>> receiverRings;
  final bool receiverEvenOdd;
  final Offset apex;
  final double radius;
  final double opacity;

  /// Translation applied to [_receiver] at paint time; see the widget.
  final Offset receiverOffset;

  @override
  void paint(Canvas canvas, Size size) {
    if ((_visibility == null && visibilityPolygon.length < 3) ||
        (_receiver == null && receiverRings.isEmpty)) return;
    final visibility =
        _visibility ?? _path([visibilityPolygon], evenOdd: false);
    final receiver =
        _receiver ?? _path(receiverRings, evenOdd: receiverEvenOdd);
    canvas.save();
    canvas.clipPath(visibility);
    // Receiver fill is the last geometric clip. No cone pixels can appear in
    // the SVG's blank exterior or in authored holes in the playable fill.
    canvas.translate(receiverOffset.dx, receiverOffset.dy);
    canvas.clipPath(receiver);
    canvas.translate(-receiverOffset.dx, -receiverOffset.dy);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color.fromARGB(255, 147, 147, 147).withValues(alpha: .5 * opacity),
          Colors.transparent,
        ],
        stops: const [0, 1],
      ).createShader(Rect.fromCircle(center: apex, radius: radius));
    canvas.drawCircle(apex, radius, paint);
    canvas.restore();
  }

  static Path _path(List<List<Offset>> rings, {required bool evenOdd}) {
    final path = Path()
      ..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
    for (final ring in rings) {
      if (ring.isEmpty) continue;
      path.moveTo(ring.first.dx, ring.first.dy);
      for (final point in ring.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      path.close();
    }
    return path;
  }

  @override
  bool shouldRepaint(SvgHeightViewConePainter oldDelegate) =>
      oldDelegate._visibility != _visibility ||
      oldDelegate._receiver != _receiver ||
      oldDelegate.visibilityPolygon != visibilityPolygon ||
      oldDelegate.receiverRings != receiverRings ||
      oldDelegate.receiverEvenOdd != receiverEvenOdd ||
      oldDelegate.apex != apex ||
      oldDelegate.radius != radius ||
      oldDelegate.receiverOffset != receiverOffset ||
      oldDelegate.opacity != opacity;
}
