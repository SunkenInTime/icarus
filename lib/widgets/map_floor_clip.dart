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

class _RenderMapFloorBox extends RenderProxyBox {}

/// Paints [child] only where it lies on the map's floor, so a shape colours
/// the map instead of covering walls and the space outside it. Outside a
/// [MapFloor], or before the floor is known, [child] paints whole.
class MapFloorClip extends SingleChildRenderObjectWidget {
  const MapFloorClip({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMapFloorClip(
        context.dependOnInheritedWidgetOfExactType<_MapFloorScope>()?.floor,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderMapFloorClip)
      ..floor =
          context.dependOnInheritedWidgetOfExactType<_MapFloorScope>()?.floor
      // The clip depends on where this box sits on the canvas, and a parent
      // can move it without repainting it (a page transition slides items
      // inside layers it keeps). A rebuild is the sign it may have moved.
      ..markNeedsPaint();
  }
}

class _RenderMapFloorClip extends RenderProxyBox {
  _RenderMapFloorClip(this._floor);

  Path? _floor;
  set floor(Path? value) {
    if (identical(value, _floor)) return;
    _floor = value;
    markNeedsPaint();
  }

  _RenderMapFloorBox? _floorBox() {
    for (RenderObject? node = parent; node != null; node = node.parent) {
      if (node is _RenderMapFloorBox) return node;
    }
    return null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final floor = _floor;
    final box = floor == null ? null : _floorBox();
    if (floor == null || box == null) {
      context.paintChild(child, offset);
      return;
    }
    final toBox = getTransformTo(box);
    final fromBox = Matrix4.tryInvert(toBox);
    if (fromBox == null) {
      context.paintChild(child, offset);
      return;
    }
    // The floor is clipped in the canvas's coordinates, where its path is
    // kept, so the path is never rebuilt for a shape that moves or turns.
    // Drawn straight on the canvas: the child must not be composited.
    final canvas = context.canvas;
    canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..transform(fromBox.storage)
      ..clipPath(floor)
      ..transform(toBox.storage)
      ..translate(-offset.dx, -offset.dy);
    context.paintChild(child, offset);
    canvas.restore();
  }
}
