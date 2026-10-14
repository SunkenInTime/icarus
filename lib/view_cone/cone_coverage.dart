import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

/// View cones as a revealed floor: the floor under any cone turns one
/// lighter shade of itself, however many cones cover it, and walls, sites and
/// everything placed on the map stay as they are. This adapts VALORANT's
/// minimap, which ships a lighter "revealed" copy of each map next to the
/// normal one.
///
/// The map is drawn as always. Above it, [ConeCoverageLayer] (or
/// [RevealedFloor], for a painter that knows every cone itself) draws a
/// revealed copy of the whole map (`MapSvgColorMapper.revealed`), shown only
/// where a cone reaches. The copy is the same art, drawn in the same order,
/// so everything on the map appears exactly once either way. Everything
/// placed sits above. The cones of a page register here ([ConeArea]) instead
/// of painting themselves; a cone outside any [ConeCoverageScope] (a drag
/// preview in the app's overlay) paints itself.
class ConeCoverage extends ChangeNotifier {
  final _areas = <RenderConeArea>{};

  Iterable<RenderConeArea> get areas => _areas;

  void _add(RenderConeArea area) {
    _areas.add(area);
    notifyListeners();
  }

  void _remove(RenderConeArea area) {
    if (_areas.remove(area)) notifyListeners();
  }

  void _changed() => notifyListeners();
}

/// How much of the way a cone lifts the floor toward the theme's wall
/// colour. VALORANT's revealed minimap lifts its floor from 118 to 181
/// against white walls: 0.46 of the way.
const revealedFloorShare = 0.46;

/// The least contrast (WCAG ratio) the revealed floor keeps with the floor.
const revealedFloorMinContrast = 1.5;

/// The floor colour wherever a cone reaches, for [palette]: its floor mixed
/// toward its wall colour, so it reads on any theme whose walls read. Where
/// floor and walls are too alike for that to show, the floor is moved toward
/// white or black, whichever can show more, just far enough to keep
/// [revealedFloorMinContrast].
Color revealedFloorColor(MapThemePalette palette) {
  final floor = palette.baseColor;
  final mixed = Color.lerp(floor, palette.detailColor, revealedFloorShare)!;
  if (_contrast(mixed, floor) >= revealedFloorMinContrast) return mixed;
  const white = Color(0xFFFFFFFF), black = Color(0xFF000000);
  final toward =
      _contrast(white, floor) >= _contrast(black, floor) ? white : black;
  for (var share = 0.05; share < 1; share += 0.05) {
    final moved = Color.lerp(floor, toward, share)!;
    if (_contrast(moved, floor) >= revealedFloorMinContrast) return moved;
  }
  return toward;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Something that paints one cone's lit area, clipped to the floor, with a
/// given [fill], in its own coordinates.
abstract interface class ConeAreaPainter {
  /// How strongly this cone is drawn: below 1 for a drag preview.
  double get opacity;

  void paintArea(Canvas canvas, Size size, Paint fill);
}

/// Gives the cones below it a shared [ConeCoverage].
class ConeCoverageScope extends InheritedWidget {
  const ConeCoverageScope({
    super.key,
    required this.coverage,
    required super.child,
  });

  final ConeCoverage coverage;

  static ConeCoverage? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConeCoverageScope>()?.coverage;

  @override
  bool updateShouldNotify(ConeCoverageScope oldWidget) =>
      oldWidget.coverage != coverage;
}

/// How strongly the cones below it show, for a parent that fades them with
/// an [Opacity] the coverage layer cannot see (a page transition).
class ConeFade extends InheritedWidget {
  const ConeFade({super.key, required this.opacity, required super.child});

  final double opacity;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConeFade>()?.opacity ?? 1;

  @override
  bool updateShouldNotify(ConeFade oldWidget) => oldWidget.opacity != opacity;
}

/// One cone of [size], painted by [painter]: into the page's
/// [ConeCoverageLayer] when there is one, otherwise by itself as [fallback]
/// paints it.
class ConeArea extends StatelessWidget {
  const ConeArea({
    super.key,
    required this.size,
    required this.painter,
    required this.fallback,
  });

  final Size size;
  final ConeAreaPainter painter;

  /// How the cone paints itself with no layer to join.
  final CustomPainter fallback;

  @override
  Widget build(BuildContext context) {
    final coverage = ConeCoverageScope.maybeOf(context);
    if (coverage == null) {
      return RepaintBoundary(child: CustomPaint(size: size, painter: fallback));
    }
    return _ConeAreaSlot(
      coverage: coverage,
      size: size,
      painter: painter,
      fade: ConeFade.of(context),
    );
  }
}

class _ConeAreaSlot extends LeafRenderObjectWidget {
  const _ConeAreaSlot({
    required this.coverage,
    required this.size,
    required this.painter,
    required this.fade,
  });

  final ConeCoverage coverage;
  final Size size;
  final ConeAreaPainter painter;
  final double fade;

  @override
  RenderConeArea createRenderObject(BuildContext context) => RenderConeArea(
        coverage: coverage,
        preferredSize: size,
        painter: painter,
        fade: fade,
      );

  @override
  void updateRenderObject(BuildContext context, RenderConeArea renderObject) {
    renderObject
      ..coverage = coverage
      ..preferredSize = size
      ..painter = painter
      ..fade = fade;
  }
}

/// A cone's place on the page: it paints nothing itself, and tells its
/// [ConeCoverage] whenever what it would paint changes.
class RenderConeArea extends RenderBox {
  RenderConeArea({
    required ConeCoverage coverage,
    required Size preferredSize,
    required ConeAreaPainter painter,
    required double fade,
  })  : _coverage = coverage,
        _preferredSize = preferredSize,
        _painter = painter,
        _fade = fade;

  ConeCoverage _coverage;
  set coverage(ConeCoverage value) {
    if (identical(value, _coverage)) return;
    if (attached) _coverage._remove(this);
    _coverage = value;
    if (attached) _coverage._add(this);
  }

  Size _preferredSize;
  set preferredSize(Size value) {
    if (value == _preferredSize) return;
    _preferredSize = value;
    markNeedsLayout();
  }

  ConeAreaPainter _painter;
  ConeAreaPainter get painter => _painter;
  set painter(ConeAreaPainter value) {
    if (identical(value, _painter)) return;
    _painter = value;
    _coverage._changed();
  }

  double _fade;

  /// How strongly this cone shows, from a [ConeFade] above it.
  double get fade => _fade;
  set fade(double value) {
    if (value == _fade) return;
    _fade = value;
    _coverage._changed();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _coverage._add(this);
  }

  @override
  void detach() {
    _coverage._remove(this);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.constrain(_preferredSize);
    // Where it sits may have moved with it; the layer paints from here.
    _coverage._changed();
  }

  @override
  bool hitTestSelf(Offset position) => false;
}

/// Paints [mask] (what cones see, opaque where they reach) and shows
/// [child] only there. Everything happens inside its own layer, so nothing
/// under it is read; [child] must draw straight to the canvas (a picture, no
/// repaint boundary of its own).
void _paintRevealed(
  PaintingContext context,
  Offset offset,
  Size size,
  RenderBox child,
  void Function(Canvas canvas) mask,
) {
  final canvas = context.canvas;
  final bounds = offset & size;
  canvas.saveLayer(bounds, Paint());
  canvas.save();
  canvas.translate(offset.dx, offset.dy);
  mask(canvas);
  canvas.restore();
  canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.srcIn);
  context.paintChild(child, offset);
  canvas.restore();
  canvas.restore();
}

/// The opaque paint a cone's reach is masked with.
final _maskFill = Paint()..color = const Color(0xFFFFFFFF);

/// Shows [child], the revealed copy of the map, wherever a cone registered
/// with [coverage] reaches.
class ConeCoverageLayer extends SingleChildRenderObjectWidget {
  const ConeCoverageLayer({
    super.key,
    required this.coverage,
    this.opacity = 1,
    required super.child,
  });

  final ConeCoverage coverage;

  /// How strongly the whole layer shows, as placed widgets are dimmed in
  /// lineup mode.
  final double opacity;

  @override
  RenderConeCoverageLayer createRenderObject(BuildContext context) =>
      RenderConeCoverageLayer(coverage: coverage, opacity: opacity);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderConeCoverageLayer renderObject,
  ) {
    renderObject
      ..coverage = coverage
      ..opacity = opacity;
  }
}

class RenderConeCoverageLayer extends RenderProxyBox {
  RenderConeCoverageLayer({
    required ConeCoverage coverage,
    required double opacity,
  })  : _coverage = coverage,
        _opacity = opacity;

  ConeCoverage _coverage;
  set coverage(ConeCoverage value) {
    if (identical(value, _coverage)) return;
    if (attached) _coverage.removeListener(markNeedsPaint);
    _coverage = value;
    if (attached) _coverage.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  double _opacity;
  set opacity(double value) {
    if (value == _opacity) return;
    _opacity = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _coverage.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _coverage.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || _opacity <= 0) return;
    // Cones by how strongly they show: cones fading together (a page
    // transition) are one group, lifted once where they overlap.
    final groups = <double, List<RenderConeArea>>{};
    for (final area in _coverage.areas) {
      if (!area.attached || !area.hasSize) continue;
      final strength = area.painter.opacity * area.fade * _opacity;
      if (strength <= 0) continue;
      groups.putIfAbsent(strength, () => []).add(area);
    }
    if (groups.isEmpty) return;
    _paintRevealed(context, offset, size, child, (canvas) {
      for (final MapEntry(key: strength, value: areas) in groups.entries) {
        if (strength < 1) {
          canvas.saveLayer(
              null, Paint()..color = Color.fromRGBO(0, 0, 0, strength));
        }
        for (final area in areas) {
          canvas.save();
          canvas.transform(area.getTransformTo(this).storage);
          area.painter.paintArea(canvas, area.size, _maskFill);
          canvas.restore();
        }
        if (strength < 1) canvas.restore();
      }
    });
  }
}

/// Shows [child], the revealed copy of the map, wherever [cones] (a painter
/// that draws every cone itself, opaque where each reaches) paints.
class RevealedFloor extends SingleChildRenderObjectWidget {
  const RevealedFloor({super.key, required this.cones, required super.child});

  final CustomPainter cones;

  @override
  RenderRevealedFloor createRenderObject(BuildContext context) =>
      RenderRevealedFloor(cones);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderRevealedFloor renderObject,
  ) {
    renderObject.cones = cones;
  }
}

class RenderRevealedFloor extends RenderProxyBox {
  RenderRevealedFloor(this._cones);

  CustomPainter _cones;
  set cones(CustomPainter value) {
    if (identical(value, _cones)) return;
    final old = _cones;
    _cones = value;
    if (value.runtimeType != old.runtimeType || value.shouldRepaint(old)) {
      markNeedsPaint();
    }
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    _paintRevealed(
        context, offset, size, child, (canvas) => _cones.paint(canvas, size));
  }
}

/// Owns a [ConeCoverage] for a view that has no state of its own to keep it
/// in, and builds that view with it.
class ConeCoverageHost extends StatefulWidget {
  const ConeCoverageHost({super.key, required this.builder});

  final Widget Function(BuildContext context, ConeCoverage coverage) builder;

  @override
  State<ConeCoverageHost> createState() => _ConeCoverageHostState();
}

class _ConeCoverageHostState extends State<ConeCoverageHost> {
  final _coverage = ConeCoverage();

  @override
  void dispose() {
    _coverage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _coverage);
}
