import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
void main() {
  test('inside bench', () {
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
        File('assets/maps/haven_svg_height_attack.json.gz').readAsBytesSync()))));
    final rnd = math.Random(1); final pts = [for (var i = 0; i < 400; i++) Offset(rnd.nextDouble() * 390, rnd.nextDouble() * 470)];
    final w = Stopwatch()..start(); var hits = 0;
    for (final p in pts) { for (final wall in model.walls) { if (wall.contains(p)) { hits++; break; } } }
    print('inside-wall scan: ${(w.elapsedMicroseconds / 400).round()} us per frame (hits $hits)');
    w.reset(); var s = 0;
    for (final p in pts) { s += model.supportsAt(p).length; }
    print('supportsAt scan: ${(w.elapsedMicroseconds / 400).round()} us per frame');
    w.reset();
    for (final p in pts) { final l = List.unmodifiable([for (var i = 0; i < 764; i++) Offset(p.dx + i, p.dy)]); s += l.length; }
    print('764 Offsets list: ${(w.elapsedMicroseconds / 400).round()} us');
  });
}
