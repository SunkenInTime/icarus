// Dev utility, not a real test: renders each dot-matrix loader at several
// animation phases and writes PNG frames to build/loader_previews/ so the
// designs can be reviewed without launching the app.
//
//   flutter test test/loader_preview_capture_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/dot_matrix_loaders.dart';

Future<void> _capture(
  WidgetTester tester,
  String name,
  Widget loader,
  Duration period,
) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: const Color(0xff09090b),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: loader,
            ),
          ),
        ),
      ),
    ),
  );

  // Let async work (e.g. logo decode) complete before capturing.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();

  const frames = 6;
  for (var i = 0; i < frames; i++) {
    await tester.pump(period ~/ frames);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/loader_previews/${name}_$i.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }
}

void main() {
  testWidgets('capture dot matrix loader previews', (tester) async {
    await _capture(tester, 'wing', const WingDotLoader(size: 140),
        const Duration(milliseconds: 1400));
    await _capture(tester, 'fire', const FireDotLoader(size: 140),
        const Duration(milliseconds: 1800));
    await _capture(tester, 'cube', const CubeDotLoader(size: 140),
        const Duration(milliseconds: 4200));
    await _capture(tester, 'cute', const CuteDotLoader(size: 140),
        const Duration(milliseconds: 1500));
    await _capture(tester, 'ember', const EmberSpinLoader(size: 32),
        const Duration(milliseconds: 1100));
    await _capture(tester, 'ember_lg', const EmberSpinLoader(size: 96, columns: 15),
        const Duration(milliseconds: 1100));
    await _capture(tester, 'mark', const IcarusMarkLoader(size: 140, columns: 18),
        const Duration(milliseconds: 2400));
    await _capture(tester, 'mark_sm', const IcarusMarkLoader(size: 48, columns: 12),
        const Duration(milliseconds: 2400));
    await _capture(tester, 'flight', const FlightTrailLoader(size: 96, columns: 19),
        const Duration(milliseconds: 2600));
    await _capture(tester, 'flight_sm', const FlightTrailLoader(size: 48),
        const Duration(milliseconds: 2600));
    await _capture(tester, 'feather', const FeatherFallLoader(size: 96, columns: 17),
        const Duration(milliseconds: 2600));
    await _capture(tester, 'ember_rise', const EmberRiseLoader(size: 48, columns: 13),
        const Duration(milliseconds: 2200));
    await _capture(tester, 'ping', const PingLoader(size: 48, columns: 13),
        const Duration(milliseconds: 1700));
  });
}
