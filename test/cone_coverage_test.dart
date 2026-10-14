import 'dart:ui' as ui;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/view_cone/cone_coverage.dart';
import 'package:icarus/widgets/map_svg_color_mapper.dart';

/// Fills its whole box, as a cone fills its lit area.
class _BoxCone extends CustomPainter implements ConeAreaPainter {
  @override
  double get opacity => 1;

  @override
  void paintArea(Canvas canvas, Size size, Paint fill) =>
      canvas.drawRect(Offset.zero & size, fill);

  @override
  void paint(Canvas canvas, Size size) =>
      paintArea(canvas, size, Paint()..color = const Color(0x80FF0000));

  @override
  bool shouldRepaint(_BoxCone oldDelegate) => false;
}

const _floor = Color(0xFF202020);
const _revealed = Color(0xFF808080);

/// A floor, the coverage layer on it, and cones at [cones] (top-left, 40 px
/// square) placed above, the way the editor stacks them.
Widget _page(ConeCoverage? coverage, List<Offset> cones, {double fade = 1}) {
  final placed = ConeFade(
      opacity: fade,
      child: Stack(children: [
        for (final at in cones)
          Positioned(
            left: at.dx,
            top: at.dy,
            child: ConeArea(
              size: const Size(40, 40),
              painter: _BoxCone(),
              fallback: _BoxCone(),
            ),
          ),
      ]));
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(
        key: const ValueKey('page'),
        child: SizedBox(
          width: 100,
          height: 100,
          child: Stack(children: [
            const Positioned.fill(child: ColoredBox(color: _floor)),
            if (coverage != null)
              Positioned.fill(
                child: ConeCoverageLayer(coverage: coverage, color: _revealed),
              ),
            Positioned.fill(
              child: coverage == null
                  ? placed
                  : ConeCoverageScope(coverage: coverage, child: placed),
            ),
          ]),
        ),
      ),
    ),
  );
}

Future<Color> Function(int x, int y) _pixels(WidgetTester tester) {
  ByteDataHolder? held;
  return (x, y) async {
    held ??= await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('page')));
      final image = await boundary.toImage();
      return ByteDataHolder(
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
        image.width,
      );
    });
    final i = (y * held!.width + x) * 4;
    final d = held!.data;
    return Color.fromARGB(
        d.getUint8(i + 3), d.getUint8(i), d.getUint8(i + 1), d.getUint8(i + 2));
  };
}

class ByteDataHolder {
  ByteDataHolder(this.data, this.width);
  final ByteData data;
  final int width;
}

void main() {
  testWidgets('overlapping cones lift the floor once, to one colour',
      (tester) async {
    final coverage = ConeCoverage();
    addTearDown(coverage.dispose);
    // Two cones overlapping on x 30..50.
    await tester
        .pumpWidget(_page(coverage, const [Offset(10, 10), Offset(30, 10)]));
    final at = _pixels(tester);
    expect(await at(20, 30), _revealed, reason: 'one cone');
    expect(await at(40, 30), _revealed, reason: 'two cones: no stacking');
    expect(await at(60, 30), _revealed, reason: 'the other cone');
    expect(await at(80, 80), _floor, reason: 'no cone');
  });

  testWidgets('a cone with no layer above it paints itself', (tester) async {
    await tester.pumpWidget(_page(null, const [Offset(10, 10)]));
    final at = _pixels(tester);
    expect(await at(20, 30), isNot(_floor));
    expect(await at(20, 30), isNot(_revealed));
  });

  testWidgets('a cone that goes stops showing', (tester) async {
    final coverage = ConeCoverage();
    addTearDown(coverage.dispose);
    await tester.pumpWidget(_page(coverage, const [Offset(10, 10)]));
    expect(coverage.areas, hasLength(1));
    await tester.pumpWidget(_page(coverage, const []));
    expect(coverage.areas, isEmpty);
    expect(await _pixels(tester)(20, 30), _floor);
  });

  test('the revealed floor sits between floor and walls, on any theme', () {
    final valorant = MapThemePalette(
      baseColorValue: 0xFF767676,
      detailColorValue: 0xFFFFFFFF,
      highlightColorValue: 0xFFF6F23E,
    );
    // VALORANT's own minimap lifts this floor to 181.
    expect(revealedFloorColor(valorant).toARGB32(), 0xFFB5B5B5);
    // A light floor with dark walls darkens instead.
    final light = MapThemePalette(
      baseColorValue: 0xFFE0E0E0,
      detailColorValue: 0xFF202020,
      highlightColorValue: 0xFF3060FF,
    );
    expect(revealedFloorColor(light).computeLuminance(),
        lessThan(light.baseColor.computeLuminance()));
  });

  testWidgets('a faded cone lifts the floor only that far', (tester) async {
    final coverage = ConeCoverage();
    addTearDown(coverage.dispose);
    await tester.pumpWidget(_page(coverage, const [Offset(10, 10)], fade: 0.5));
    final half = await _pixels(tester)(20, 30);
    // Halfway from 0x20 to 0x80.
    expect((half.r * 255).round(), closeTo(0x50, 1));
  });

  test('the floor and ink passes draw every colour exactly once', () {
    final palette = MapThemePalette(
      baseColorValue: 0xFF767676,
      detailColorValue: 0xFFFFFFFF,
      highlightColorValue: 0xFFF6F23E,
    );
    final floor = MapSvgColorMapper.floor(palette);
    final ink = MapSvgColorMapper.ink(palette);
    Color through(MapSvgColorMapper mapper, Color color) =>
        mapper.substitute(null, 'path', 'fill', color);
    for (final (source, expected) in [
      (MapSvgSourceColors.base, palette.baseColor),
      (MapSvgSourceColors.detail, palette.detailColor),
      (MapSvgSourceColors.highlight, palette.highlightColor),
      // A colour no theme controls, such as a label's.
      (const Color(0xFFABCDEF), const Color(0xFFABCDEF)),
    ]) {
      final drawn = [through(floor, source), through(ink, source)]
          .where((c) => c.a > 0)
          .toList();
      expect(drawn, hasLength(1), reason: '$source');
      expect(drawn.single.toARGB32(), expected.toARGB32());
    }
    // The site fills are 23% opaque in the art and stay so.
    final site = MapSvgSourceColors.highlight.withValues(alpha: 0.23);
    expect(through(ink, site).a, closeTo(0.23, 0.01));
    expect(through(floor, site).a, 0);
  });

  test('floor and walls too alike still get a revealed floor that shows', () {
    for (final floor in [0xFF303030, 0xFFD0D0D0]) {
      final palette = MapThemePalette(
        baseColorValue: floor,
        detailColorValue: floor,
        highlightColorValue: 0xFFF6F23E,
      );
      final revealed = revealedFloorColor(palette).computeLuminance();
      final base = palette.baseColor.computeLuminance();
      final ratio =
          (math.max(revealed, base) + 0.05) / (math.min(revealed, base) + 0.05);
      expect(ratio, greaterThanOrEqualTo(revealedFloorMinContrast),
          reason: floor.toRadixString(16));
    }
  });
}
