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

  /// Repaints the layer from where the cones sit now, after something above
  /// them moved them without a new layout (a drag of the selection).
  void moved() => notifyListeners();
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

/// Something that paints one cone's lit area with a given [fill], in its
/// own coordinates.
abstract interface class ConeAreaPainter {
  /// How strongly this cone is drawn: below 1 for a drag preview.
  double get opacity;

  /// Paints the lit area, also clipped to the painted floor when
  /// [clipToFloor] (when the layer it joins does not clip its map itself).
  void paintArea(Canvas canvas, Size size, Paint fill,
      {required bool clipToFloor});
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

/// Shows [child] only where [mask] (what cones see, opaque where they reach)
/// paints, and returns the layer that does it.
///
/// [child] is a repaint boundary, so the revealed map keeps one picture
/// while cones move. The mask is drawn over it with dstIn, both inside a
/// layer of their own (a clip to the whole box that saves a layer), so dstIn
/// reaches only the revealed map, never the map under it. A colour filter
/// would group them too, but the engine caches a filter's children as one
/// image, which would redraw the map into a new image with every mask.
ClipRectLayer? _paintRevealed(
  PaintingContext context,
  bool needsCompositing,
  Offset offset,
  Size size,
  RenderBox child,
  ClipRectLayer? oldLayer,
  void Function(Canvas canvas) mask,
) {
  return context.pushClipRect(needsCompositing, offset, Offset.zero & size,
      (context, offset) {
    context.paintChild(child, offset);
    final canvas = context.canvas;
    canvas.saveLayer(offset & size, Paint()..blendMode = BlendMode.dstIn);
    canvas.translate(offset.dx, offset.dy);
    mask(canvas);
    canvas.restore();
  }, clipBehavior: Clip.antiAliasWithSaveLayer, oldLayer: oldLayer);
}

/// Shows [child], the revealed copy of the map, wherever a cone registered
/// with [coverage] reaches.
class ConeCoverageLayer extends SingleChildRenderObjectWidget {
  ConeCoverageLayer({
    super.key,
    required this.coverage,
    this.opacity = 1,
    Path? floor,
    required Widget child,
  })  : clipsToFloor = floor != null,
        super(child: _cachedMap(floor, child));

  final ConeCoverage coverage;

  /// Whether the revealed map is clipped to the floor here, once, so cones
  /// need not each clip themselves.
  final bool clipsToFloor;

  /// How strongly the whole layer shows, as placed widgets are dimmed in
  /// lineup mode.
  final double opacity;

  @override
  RenderConeCoverageLayer createRenderObject(BuildContext context) =>
      RenderConeCoverageLayer(
        coverage: coverage,
        opacity: opacity,
        clipsToFloor: clipsToFloor,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderConeCoverageLayer renderObject,
  ) {
    renderObject
      ..coverage = coverage
      ..opacity = opacity
      ..clipsToFloor = clipsToFloor;
  }
}

class RenderConeCoverageLayer extends RenderProxyBox {
  RenderConeCoverageLayer({
    required ConeCoverage coverage,
    required double opacity,
    required bool clipsToFloor,
  })  : _coverage = coverage,
        _opacity = opacity,
        _clipsToFloor = clipsToFloor;

  bool _clipsToFloor;
  set clipsToFloor(bool value) {
    if (value == _clipsToFloor) return;
    _clipsToFloor = value;
    markNeedsPaint();
  }

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
    final areas = [
      for (final area in _coverage.areas)
        if (area.attached && area.hasSize) area,
    ];
    if (child == null || _opacity <= 0 || areas.isEmpty) {
      layer = null;
      return;
    }
    layer = _paintRevealed(
        context, needsCompositing, offset, size, child, layer as ClipRectLayer?,
        (canvas) {
      // Each cone's strength as an opaque grey on black (an edge pixel it
      // half covers is half as grey), lightened together: wherever cones
      // overlap, the strongest one counts, in any order. The grey then
      // becomes the mask's opacity.
      canvas.saveLayer(null, Paint()..colorFilter = _greyToOpacity);
      canvas.drawColor(const Color(0xFF000000), BlendMode.src);
      for (final area in areas) {
        final strength = area.painter.opacity * area.fade * _opacity;
        if (strength <= 0) continue;
        canvas.save();
        canvas.transform(area.getTransformTo(this).storage);
        // Its own layer, only as large as the cone's box, so however the
        // painter composes its pieces the finished cone is lightened in.
        // A little past the box, and with a hard clip: an antialiased layer
        // edge on the cone's own edge would make that edge partly
        // transparent, and partial pixels stack.
        final box = (Offset.zero & area.size).inflate(2);
        canvas.clipRect(box, doAntiAlias: false);
        canvas.saveLayer(box, Paint()..blendMode = BlendMode.lighten);
        canvas.drawColor(const Color(0xFF000000), BlendMode.src);
        area.painter.paintArea(
          canvas,
          area.size,
          Paint()
            ..color = Color.from(
                alpha: 1, red: strength, green: strength, blue: strength),
          clipToFloor: !_clipsToFloor,
        );
        canvas.restore();
        canvas.restore();
      }
      canvas.restore();
    });
  }

  /// Opaque white wherever the grey was, as opaque as the grey was light.
  static const _greyToOpacity = ColorFilter.matrix([
    0, 0, 0, 0, 255, //
    0, 0, 0, 0, 255, //
    0, 0, 0, 0, 255, //
    1, 0, 0, 0, 0, //
  ]);
}

/// Shows [child], the revealed copy of the map, wherever [cones] (a painter
/// that draws every cone itself, opaque where each reaches) paints.
class RevealedFloor extends SingleChildRenderObjectWidget {
  /// [floor], when given, is where [child] shows at all: it is clipped to it
  /// once, in the map's own cached layer, so [cones] need not clip to it.
  RevealedFloor({
    super.key,
    required this.cones,
    Path? floor,
    required Widget child,
  }) : super(child: _cachedMap(floor, child));

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
    if (child == null) {
      layer = null;
      return;
    }
    layer = _paintRevealed(context, needsCompositing, offset, size, child,
        layer as ClipRectLayer?, (canvas) => _cones.paint(canvas, size));
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

/// The revealed map in a layer of its own, clipped to [floor] if given.
///
/// Clipping the map once here, rather than every cone to the floor, is most
/// of what makes cones cheap on Windows: the engine draws there without a
/// stencil buffer, so a clip to a shape as complex as the floor is a mask
/// drawn on the CPU, and cones moving every frame need new ones.
Widget _cachedMap(Path? floor, Widget map) => RepaintBoundary(
      child: floor == null
          ? map
          : ClipPath(clipper: _FloorClipper(floor), child: map),
    );

class _FloorClipper extends CustomClipper<Path> {
  const _FloorClipper(this.floor);

  final Path floor;

  @override
  Path getClip(Size size) => floor;

  @override
  bool shouldReclip(_FloorClipper oldClipper) =>
      !identical(oldClipper.floor, floor);
}
