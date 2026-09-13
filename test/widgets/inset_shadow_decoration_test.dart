import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/inset_shadow_decoration.dart';

const _size = Size(120, 40);
const _fill = Color(0xff27272a);

Future<_Pixels> _render(WidgetTester tester, Decoration decoration) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: _size.width,
            height: _size.height + 1,
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: _size.width,
                height: _size.height,
                decoration: decoration,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // Engine futures only resolve inside runAsync; the fake-async test zone
  // never completes them.
  late _Pixels pixels;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final dump = Platform.environment['INSET_SHADOW_DUMP'];
    if (dump != null) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(dump).writeAsBytesSync(png!.buffer.asUint8List());
    }
    pixels = _Pixels(image.width, (await image.toByteData())!);
  });
  return pixels;
}

class _Pixels {
  const _Pixels(this.width, this.bytes);

  final int width;
  final ByteData bytes;

  Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      bytes.getUint8(i + 3),
      bytes.getUint8(i),
      bytes.getUint8(i + 1),
      bytes.getUint8(i + 2),
    );
  }
}

void main() {
  testWidgets('raised rim lightens the edges and the top edge most',
      (tester) async {
    final image = await _render(
      tester,
      InsetShadowDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(6),
        shadows: Settings.raisedRim,
      ),
    );
    final centre = image.at(60, 20);
    final top = image.at(60, 0);
    final bottom = image.at(60, 39);
    final left = image.at(0, 20);
    final inside = image.at(60, 2);

    expect(centre, _fill, reason: 'the face keeps the plain fill');
    expect(inside, _fill, reason: 'the edges are one pixel deep');
    expect(left, _fill, reason: 'the sides stay bare');
    expect(top.r, greaterThan(centre.r), reason: 'top edge is lit');
    expect(bottom.r, lessThan(centre.r), reason: 'bottom edge is shaded');
  });

  testWidgets('gradient paints over the fill and drop shadows fall outside',
      (tester) async {
    final image = await _render(
      tester,
      InsetShadowDecoration(
        gradient: Settings.raisedGradient(_fill),
        borderRadius: BorderRadius.circular(6),
        boxShadows: const [Settings.raisedDropShadow],
      ),
    );
    expect(image.at(60, 4).r, greaterThan(image.at(60, 35).r),
        reason: 'the fill runs lighter at the top');
    expect(image.at(60, 40).a, greaterThan(0),
        reason: 'the shadow lands one pixel under the box');
  });

  testWidgets('a blurred inset shadow darkens toward the edge',
      (tester) async {
    final image = await _render(
      tester,
      const InsetShadowDecoration(
        color: Color(0xffffffff),
        shadows: [
          InsetShadow(color: Color(0xff000000), blurRadius: 8),
        ],
      ),
    );
    final centre = image.at(60, 20);
    final nearEdge = image.at(60, 1);
    final midway = image.at(60, 4);
    expect(centre, const Color(0xffffffff));
    expect(nearEdge.r, lessThan(midway.r));
    expect(midway.r, lessThan(centre.r));
  });

  testWidgets('without shadows nothing paints outside the fill',
      (tester) async {
    final image = await _render(
      tester,
      const InsetShadowDecoration(color: _fill),
    );
    expect(image.at(0, 0), _fill);
    expect(image.at(119, 39), _fill);
  });

  test('tweens from a plain rounded BoxDecoration', () {
    final from = BoxDecoration(
      color: _fill,
      borderRadius: BorderRadius.circular(6),
    );
    final to = Settings.raisedPrimary(6);
    final mid = Decoration.lerp(from, to, 0.5);
    expect(mid, isA<InsetShadowDecoration>());
    final raised = mid! as InsetShadowDecoration;
    expect(raised.shadows, hasLength(2));
    expect(raised.shadows.first.color.a, closeTo(0.07, 0.01),
        reason: 'the top light fades in halfway');
    expect(Decoration.lerp(to, from, 0.75), isA<InsetShadowDecoration>());
  });
}
