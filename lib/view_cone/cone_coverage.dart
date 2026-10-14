import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

/// View cones as a revealed floor: the floor under any cone turns one
/// lighter shade of itself, however many cones cover it, and walls, sites and
/// everything placed on the map stay as they are. This adapts VALORANT's
/// minimap, which ships a lighter "revealed" copy of each map's floor.
///
/// The cones of a page register here ([ConeArea]) instead of painting
/// themselves. The map is drawn in two passes, its floor
/// (`MapSvgColorMapper.floor`) and everything else
/// (`MapSvgColorMapper.ink`); [ConeCoverageLayer] sits between them and fills
/// every cone at once in the revealed floor colour. Everything placed sits
/// above. A cone outside any [ConeCoverageScope] (a drag preview in the app's
/// overlay) paints itself.
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
/// floor and walls are too alike for that to show, a dark floor is lightened
/// and a light one darkened instead.
Color revealedFloorColor(MapThemePalette palette) {
  final floor = palette.baseColor;
  final mixed = Color.lerp(floor, palette.detailColor, revealedFloorShare)!;
  if (_contrast(mixed, floor) >= revealedFloorMinContrast) return mixed;
  return floor.computeLuminance() < 0.5
      ? Color.lerp(floor, const Color(0xFFFFFFFF), 0.35)!
      : Color.lerp(floor, const Color(0xFF000000), 0.3)!;
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

/// Every registered cone of a [ConeCoverage], filled as one revealed floor
/// in [color].
class ConeCoverageLayer extends LeafRenderObjectWidget {
  const ConeCoverageLayer({
    super.key,
    required this.coverage,
    required this.color,
    this.opacity = 1,
  });

  final ConeCoverage coverage;
  final Color color;

  /// How strongly the whole layer shows, as placed widgets are dimmed in
  /// lineup mode.
  final double opacity;

  @override
  RenderConeCoverageLayer createRenderObject(BuildContext context) =>
      RenderConeCoverageLayer(
        coverage: coverage,
        color: color,
        opacity: opacity,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderConeCoverageLayer renderObject,
  ) {
    renderObject
      ..coverage = coverage
      ..color = color
      ..opacity = opacity;
  }
}

class RenderConeCoverageLayer extends RenderBox {
  RenderConeCoverageLayer({
    required ConeCoverage coverage,
    required Color color,
    required double opacity,
  })  : _coverage = coverage,
        _color = color,
        _opacity = opacity;

  ConeCoverage _coverage;
  set coverage(ConeCoverage value) {
    if (identical(value, _coverage)) return;
    if (attached) _coverage.removeListener(markNeedsPaint);
    _coverage = value;
    if (attached) _coverage.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
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
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final areas = [
      for (final area in _coverage.areas)
        if (area.attached && area.hasSize) area,
    ];
    if (areas.isEmpty || _opacity <= 0) return;
    final canvas = context.canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    // Opaque fills in one group, so where cones overlap the floor is lifted
    // once; the group's own opacity dims them all together.
    canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, _opacity));
    for (final area in areas) {
      canvas.save();
      canvas.transform(area.getTransformTo(this).storage);
      area.painter.paintArea(
        canvas,
        area.size,
        Paint()
          ..color = _color.withValues(alpha: area.painter.opacity * area.fade),
      );
      canvas.restore();
    }
    canvas.restore();
    canvas.restore();
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
