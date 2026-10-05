import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/providers/drawing_provider.dart';

FreeDrawing _stroke(String id, List<Offset> points) => FreeDrawing(
      id: id,
      listOfPoints: [...points],
      color: Colors.white,
      isDotted: false,
      hasArrow: false,
    );

void main() {
  setUp(() => CoordinateSystem(playAreaSize: const Size(1200, 800)));

  test('a merge reuses the built path of a stroke whose points are unchanged',
      () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final drawings = container.read(drawingProvider.notifier);
    const same = [Offset(10, 10), Offset(20, 30), Offset(40, 35)];
    drawings.fromHive([
      _stroke('same', same),
      _stroke('moved', const [Offset(0, 0), Offset(5, 5)]),
    ]);
    final before = {
      for (final d in container.read(drawingProvider).elements)
        d.id: (d as FreeDrawing).path,
    };

    drawings.mergeRemote([
      _stroke('same', same),
      _stroke('moved', const [Offset(0, 0), Offset(50, 50)]),
    ], (_) => false);

    final after = {
      for (final d in container.read(drawingProvider).elements)
        d.id: (d as FreeDrawing).path,
    };
    expect(identical(after['same'], before['same']), isTrue);
    expect(identical(after['moved'], before['moved']), isFalse);
    expect(after['moved']!.getBounds().right,
        greaterThan(before['moved']!.getBounds().right));
  });
}
