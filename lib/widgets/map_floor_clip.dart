import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

/// Wraps the canvas a map is drawn on, so a [MapFloorClip] anywhere inside
/// can keep to the map's painted floor. [child] must be laid out in the
/// coordinates the map art is placed in (the canvas stack itself).
class MapFloor extends ConsumerWidget {
  const MapFloor({
    super.key,
    required this.map,
    required this.isAttack,
    required this.child,
  });

  final MapValue map;
  final bool isAttack;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model =
        ref.watch(svgHeightRuntimeProvider(map)).asData?.value?.model(isAttack);
    return _MapFloorScope(
      // Null until the map's height model loads: nothing is clipped before.
      floor: model == null
          ? null
          : SvgHeightMapTransform.forMap(
              map,
            ).floorOnScreen(model, isAttack: isAttack),
      child: _MapFloorBox(child: child),
    );
  }
}

class _MapFloorScope extends InheritedWidget {
  const _MapFloorScope({required this.floor, required super.child});

  final Path? floor;

  @override
  bool updateShouldNotify(_MapFloorScope oldWidget) =>
      !identical(oldWidget.floor, floor);
}

/// Marks the box whose coordinates the floor path is in.
class _MapFloorBox extends SingleChildRenderObjectWidget {
  const _MapFloorBox({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMapFloorBox();
}

class _RenderMapFloorBox extends RenderProxyBox {
  /// The clips under this box, which leave out what the ones above cover.
  final clips = <_RenderMapFloorClip>{};
}

/// Paints [child] only where it lies on the map's floor, so a shape colours
/// the map instead of covering walls and the space outside it. Outside a
/// [MapFloor], or before the floor is known, [child] paints whole.
///
/// With an [order], it also leaves out whatever a clip of a higher order
/// covers: where two zones cross, the map takes the top one's colour once
/// instead of both stacked.
class MapFloorClip extends SingleChildRenderObjectWidget {
  const MapFloorClip({super.key, this.order, required super.child});

  /// Where this shape sits among the page's shapes, lowest first. Null for a
  /// shape that is not one of them (a preview, an item in transition).
  final int? order;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMapFloorClip(
        context.dependOnInheritedWidgetOfExactType<_MapFloorScope>()?.floor,
        order,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderMapFloorClip)
      ..floor =
          context.dependOnInheritedWidgetOfExactType<_MapFloorScope>()?.floor
      ..order = order
      // The clip depends on where this box sits on the canvas, and a parent
      // can move it without repainting it (a page transition slides items
      // inside layers it keeps). A rebuild is the sign it may have moved.
      ..markNeedsPaint();
  }
}

class _RenderMapFloorClip extends RenderProxyBox {
  _RenderMapFloorClip(this._floor, this._order);

  Path? _floor;
  set floor(Path? value) {
    if (identical(value, _floor)) return;
    _floor = value;
    markNeedsPaint();
  }

  int? _order;
  set order(int? value) {
    if (value == _order) return;
    _order = value;
    _repaintOrdered();
  }

  _RenderMapFloorBox? _box;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    for (RenderObject? node = parent; node != null; node = node.parent) {
      if (node is _RenderMapFloorBox) {
        _box = node..clips.add(this);
        break;
      }
    }
    _repaintOrdered();
  }

  @override
  void detach() {
    _repaintOrdered();
    _box?.clips.remove(this);
    _box = null;
    super.detach();
  }

  /// The shapes under this one leave out what it covers, so they repaint
  /// when it comes, goes, moves or changes size.
  void _repaintOrdered() {
    final clips = _box?.clips;
    if (clips == null) return;
    for (final clip in clips) {
      if (!identical(clip, this) && clip.attached) clip.markNeedsPaint();
    }
  }

  @override
  void performLayout() {
    final before = hasSize ? size : null;
    super.performLayout();
    if (before != size) _repaintOrdered();
  }

  /// This box's outline in [box]'s coordinates.
  Path _outlineIn(_RenderMapFloorBox box) {
    final toBox = getTransformTo(box);
    final rect = Offset.zero & size;
    return Path()
      ..addPolygon([
        for (final corner in [
          rect.topLeft,
          rect.topRight,
          rect.bottomRight,
          rect.bottomLeft,
        ])
          MatrixUtils.transformPoint(toBox, corner),
      ], true);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final floor = _floor;
    final box = _box;
    final order = _order;
    final above = box == null || order == null
        ? const <_RenderMapFloorClip>[]
        : [
            for (final clip in box.clips)
              if (!identical(clip, this) &&
                  clip.attached &&
                  clip.hasSize &&
                  (clip._order ?? -1) > order)
                clip,
          ];
    if (box == null || (floor == null && above.isEmpty)) {
      context.paintChild(child, offset);
      return;
    }
    final toBox = getTransformTo(box);
    final fromBox = Matrix4.tryInvert(toBox);
    if (fromBox == null) {
      context.paintChild(child, offset);
      return;
    }
    // Clipped in the canvas's coordinates, where the floor's path is kept,
    // so the path is never rebuilt for a shape that moves or turns.
    // Drawn straight on the canvas: the child must not be composited.
    final canvas = context.canvas;
    canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..transform(fromBox.storage);
    if (floor != null) canvas.clipPath(floor);
    for (final clip in above) {
      canvas.clipPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(Offset.zero & box.size),
          clip._outlineIn(box),
        ),
      );
    }
    canvas
      ..transform(toBox.storage)
      ..translate(-offset.dx, -offset.dy);
    context.paintChild(child, offset);
    canvas.restore();
  }
}
