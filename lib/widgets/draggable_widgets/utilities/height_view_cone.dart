import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/height_runtime_provider.dart';
import 'package:icarus/view_cone/receiver_compositor.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

/// The surrounding draggable retains its established anchor and rotation.
/// Completed meshes keep their original world pose while a newer query runs.
/// A pending drag never carries an old mesh to a different location.
class HeightViewCone extends StatefulWidget {
  const HeightViewCone(
      {super.key,
      required this.runtime,
      required this.canonicalOrigin,
      required this.rotation,
      required this.range,
      required this.angle,
      required this.isAttack,
      required this.zoom,
      this.elevation});
  final HeightRuntime runtime;
  final Offset canonicalOrigin;

  /// Display-side rotation in radians, normalized-world range, cone radians,
  /// and the surrounding canvas zoom. Saved positions remain attack-side.
  final double rotation, range, angle, zoom;
  final bool isAttack;
  final double? elevation;

  @override
  State<HeightViewCone> createState() => _HeightViewConeState();
}

class _HeightViewConeState extends State<HeightViewCone> {
  final _slot = Object();
  Float32List? _mesh;
  _Pose? _completedPose;
  late ui.FragmentShader _shader;
  _Pose? _pose;
  var _revision = 0, _completedRevision = 0, _epoch = 0;

  @override
  void initState() {
    super.initState();
    _shader = widget.runtime.program.fragmentShader();
    _request();
  }

  @override
  void didUpdateWidget(HeightViewCone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.isAttack != widget.isAttack) {
      _epoch++;
      _removeQueries(oldWidget.runtime);
      oldWidget.runtime.renderer.removeCone(_slot);
      _shader.dispose();
      _shader = widget.runtime.program.fragmentShader();
      _mesh = null;
      _completedPose = null;
    } else if (oldWidget.canonicalOrigin == widget.canonicalOrigin &&
        oldWidget.rotation == widget.rotation &&
        oldWidget.range == widget.range &&
        oldWidget.angle == widget.angle &&
        oldWidget.elevation == widget.elevation) {
      return;
    }
    _request();
  }

  void _request() {
    final previous = _pose;
    final pose = _pose = _Pose.forWidget(widget);
    if (previous != null && previous.queryRuntime != pose?.queryRuntime) {
      _epoch++;
      previous.queryRuntime.queue.remove(_slot);
      _mesh = null;
      _completedPose = null;
    }
    final revision = ++_revision;
    if (pose == null) {
      _epoch++;
      _removeQueries(widget.runtime);
      widget.runtime.renderer.removeCone(_slot);
      _mesh = null;
      _completedPose = null;
      return;
    }
    final epoch = _epoch;
    void complete(Float32List mesh) {
      if (!mounted || epoch != _epoch || revision <= _completedRevision) return;
      setState(() {
        _mesh = mesh;
        _completedPose = pose;
        _completedRevision = revision;
      });
    }

    pose.queryRuntime.queue
        .request(_slot, pose.query, onComputed: complete)
        .then((mesh) {
      if (mesh != null) complete(mesh);
    }, onError: (Object error, StackTrace stack) {
      if (mounted && epoch == _epoch)
        setState(() {
          _mesh = null;
          _completedPose = null;
        });
    });
  }

  @override
  void dispose() {
    _removeQueries(widget.runtime);
    widget.runtime.renderer.removeCone(_slot);
    _shader.dispose();
    super.dispose();
  }

  void _removeQueries(HeightRuntime runtime) {
    runtime.queue.remove(_slot);
    for (final variant in runtime.variants) {
      variant.queue.remove(_slot);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mesh = _mesh;
    final pose = _completedPose;
    if (mesh == null || pose == null) return const SizedBox.expand();
    final coordinates = CoordinateSystem.instance;
    return RepaintBoundary(
        child: CustomPaint(
            painter: _Painter(
      runtime: widget.runtime,
      slot: _slot,
      shader: _shader,
      mesh: mesh,
      pose: pose,
      anchorOrigin: _pose!.sideOrigin,
      rotation: widget.rotation,
      screenScale: coordinates.worldHeightToScreen(1),
      physicalScale: coordinates.worldHeightToScreen(1) *
          widget.zoom *
          MediaQuery.devicePixelRatioOf(context),
    )));
  }
}

class _Pose {
  _Pose(
      this.queryRuntime,
      this.query,
      this.projection,
      this.receiver,
      this.svgScale,
      this.svgOffset,
      this.sideOrigin,
      this.svgOrigin,
      this.facing);
  final HeightRuntime queryRuntime;
  final Float64List query;
  final VisionWorldProjection projection;
  final WorldReceiverMask receiver;
  final double svgScale, facing;
  final Offset svgOffset, sideOrigin, svgOrigin;

  static _Pose? forWidget(HeightViewCone widget) {
    final runtime = widget.runtime;
    final receiver = widget.isAttack ? runtime.attack : runtime.defense;
    final viewBox = receiver.viewBox;
    final scale = math.min(1240 / viewBox.width, 1000 / viewBox.height);
    final artworkTranslation = widget.isAttack
        ? Offset.zero
        : runtime.assets.projection.defense.origin -
            runtime.assets.defenseProjection.origin;
    final offset = Offset((1000 * 16 / 9 - viewBox.width * scale) / 2,
            (1000 - viewBox.height * scale) / 2) -
        viewBox.topLeft * scale +
        artworkTranslation;
    // Artwork and receiver presentation share the canonical marker reflection.
    // The SVG projection below still uses the untouched raw defense coordinates.
    final canvasProjection = widget.isAttack
        ? runtime.assets.projection
        : runtime.assets.projection.defense;
    final projection = VisionWorldProjection(
        origin: (canvasProjection.origin - offset) / scale,
        axisU: canvasProjection.axisU / scale,
        axisV: canvasProjection.axisV / scale);
    final sideOrigin = CoordinateSystem.instance.positionForSide(
        canonicalPosition: widget.canonicalOrigin,
        reflectionOffset: Offset.zero,
        isAttack: widget.isAttack);
    final displayedNativeOrigin = canvasProjection.toMeters(sideOrigin);
    final nativeOrigin =
        runtime.assets.displayWarp?.sourceAt(displayedNativeOrigin) ??
            displayedNativeOrigin;
    final displayFacing = widget.rotation - math.pi / 2;
    // Saved rotations are global headings. A display correction must not turn
    // the physical view when an observer crosses a correction-mesh edge.
    final direction = canvasProjection.vectorToMeters(
        Offset(math.cos(displayFacing), math.sin(displayFacing)));
    final unit = direction / direction.distance;
    final range = widget.range * direction.distance;
    // Navigation is registered to the displayed artwork, while source queries
    // and the ground reference stay in original native coordinates.
    final navigationOrigin =
        runtime.assets.projection.toCanvas(displayedNativeOrigin);
    final preferredFloor = widget.elevation == null
        ? runtime.navigation.defaultFloorElevationCm
        : widget.elevation! - runtime.navigation.observerHeightCm;
    final floor = runtime.navigation.geometry
        .floorHeightAt(navigationOrigin, preferredElevation: preferredFloor);
    final svgOrigin = (sideOrigin - offset) / scale;
    // The baked source envelope covers native floors and painted receivers.
    // An arbitrary off-map marker has no verified observer geometry.
    if (floor == null && !receiver.containsReceiver(svgOrigin)) {
      return null;
    }
    final chart = runtime.variants.isEmpty
        ? 0
        : runtime.navigation.geometry.groundChartAt(navigationOrigin,
            preferredElevation: preferredFloor);
    if (chart < 0 || chart > runtime.variants.length) return null;
    final queryRuntime = chart == 0 ? runtime : runtime.variants[chart - 1];
    final ground = queryRuntime.assets.groundField;
    final referenceHeight = ground?.heightAt(nativeOrigin);
    if (ground != null && referenceHeight == null) return null;
    // Painted areas can extend beyond the player-radius inset of the navmesh.
    // Use the local ground reference there, not a distant map-wide floor level.
    final elevation = widget.elevation ??
        (floor ??
                (referenceHeight == null
                    ? runtime.navigation.defaultFloorElevationCm
                    : referenceHeight * 100)) +
            runtime.navigation.observerHeightCm;
    final query = Float64List.fromList([
      nativeOrigin.dx,
      nativeOrigin.dy,
      elevation / 100 - (referenceHeight ?? 0),
      unit.dx,
      unit.dy,
      range,
      widget.angle
    ]);
    final sourceSvgOrigin = projection.toCanvas(nativeOrigin);
    return _Pose(queryRuntime, query, projection, receiver, scale, offset,
        sideOrigin, sourceSvgOrigin, math.atan2(unit.dy, unit.dx));
  }
}

class _Painter extends CustomPainter {
  _Painter(
      {required this.runtime,
      required this.slot,
      required this.shader,
      required this.mesh,
      required this.pose,
      required this.rotation,
      required this.anchorOrigin,
      required this.screenScale,
      required this.physicalScale});
  final HeightRuntime runtime;
  final Object slot;
  final ui.FragmentShader shader;
  final Float32List mesh;
  final _Pose pose;
  final double rotation, screenScale, physicalScale;
  final Offset anchorOrigin;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    try {
      final transform = Matrix4.identity()
        ..translateByDouble(size.width / 2, size.height, 0, 1)
        ..rotateZ(-rotation)
        ..scaleByDouble(screenScale, screenScale, 1, 1)
        ..translateByDouble(pose.svgOffset.dx - anchorOrigin.dx,
            pose.svgOffset.dy - anchorOrigin.dy, 0, 1)
        ..scaleByDouble(pose.svgScale, pose.svgScale, 1, 1);
      canvas.transform(transform.storage);
      paintWorldReceiverVisibility(
          canvas: canvas,
          receiver: pose.receiver,
          paintVisibility: (canvas) => runtime.renderer.paintCone(
              canvas,
              mesh,
              pose.projection,
              pose.svgOrigin,
              pose.facing,
              pose.query[5],
              pose.query[6],
              physicalScale * pose.svgScale,
              const Color.fromARGB(128, 147, 147, 147),
              shader,
              coneId: slot,
              meshKey: mesh,
              displayWarp: runtime.assets.displayWarp,
              radialFalloff: 1,
              viewport: pose.receiver.viewBox));
    } finally {
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Painter oldDelegate) =>
      oldDelegate.runtime != runtime ||
      oldDelegate.mesh != mesh ||
      oldDelegate.pose != pose ||
      oldDelegate.anchorOrigin != anchorOrigin ||
      oldDelegate.rotation != rotation ||
      oldDelegate.shader != shader ||
      oldDelegate.screenScale != screenScale ||
      oldDelegate.physicalScale != physicalScale;
}
