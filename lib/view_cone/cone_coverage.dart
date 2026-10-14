import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

/// View cones drawn the way VALORANT's own minimap shows what players see:
/// the floor under any cone turns one lighter shade of itself, however many
/// cones cover it, and walls, sites and everything placed on the map stay as
/// they are.
///
/// The cones of a page register here ([ConeArea]) instead of painting
/// themselves. [ConeCoverageLayer], placed on the map art, fills them all at
/// once in the revealed floor colour, and the map's ink
/// (`MapSvgColorMapper.ink`) is drawn again above it, so walls and sites read through. Everything
/// placed sits above both. A cone outside any [ConeCoverageScope] (a drag
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
/// colour. VALORANT's minimap lifts its floor from 118 to 181 against white
/// walls: 0.46 of the way.
const revealedFloorShare = 0.46;

/// The floor colour wherever a cone reaches, for [palette]: its floor mixed
/// toward its wall colour, so it reads on any theme whose walls read, light
/// floors included.
Color revealedFloorColor(MapThemePalette palette) =>
    Color.lerp(palette.baseColor, palette.detailColor, revealedFloorShare)!;

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
    return _ConeAreaSlot(coverage: coverage, size: size, painter: painter);
  }
}

class _ConeAreaSlot extends LeafRenderObjectWidget {
  const _ConeAreaSlot({
    required this.coverage,
    required this.size,
    required this.painter,
  });

  final ConeCoverage coverage;
  final Size size;
  final ConeAreaPainter painter;

  @override
  RenderConeArea createRenderObject(BuildContext context) =>
      RenderConeArea(coverage: coverage, preferredSize: size, painter: painter);

  @override
  void updateRenderObject(BuildContext context, RenderConeArea renderObject) {
    renderObject
      ..coverage = coverage
      ..preferredSize = size
      ..painter = painter;
  }
}

/// A cone's place on the page: it paints nothing itself, and tells its
/// [ConeCoverage] whenever what it would paint changes.
class RenderConeArea extends RenderBox {
  RenderConeArea({
    required ConeCoverage coverage,
    required Size preferredSize,
    required ConeAreaPainter painter,
  })  : _coverage = coverage,
        _preferredSize = preferredSize,
        _painter = painter;

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
        Paint()..color = _color.withValues(alpha: area.painter.opacity),
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
