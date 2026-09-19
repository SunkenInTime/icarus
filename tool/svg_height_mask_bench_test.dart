import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
void main() {
  test('mask bench', () {
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
        File('assets/maps/haven_svg_height_attack.json.gz').readAsBytesSync()))));
    final w = Stopwatch()..start();
    var n = 0;
    for (var i = 0; i < 400; i++) {
      final eye = 2.75 + (i % 7) * 0.5;
      final active = [for (final wall in model.walls) wall.blocks(eye)];
      n += active.length;
    }
    print('active mask: ${(w.elapsedMicroseconds / 400).round()} us per frame for ${n ~/ 400} walls');
  });
}
