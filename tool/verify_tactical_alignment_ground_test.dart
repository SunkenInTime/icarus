import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/tactical_ground_field.dart';

void main() {
  test('composed ground field loads and interpolates every triangle center',
      () {
    const path = String.fromEnvironment('TACTICAL_GROUND_CANDIDATE');
    expect(path, isNotEmpty);
    final data =
        jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync())))
            as Map<String, dynamic>;
    final field = TacticalGroundField.fromJson(data);
    final vertices = (data['vertices'] as List).cast<num>();
    final triangles = (data['triangles'] as List).cast<int>();
    var maximumError = 0.0;
    for (var i = 0; i < triangles.length; i += 3) {
      var point = Offset.zero;
      var expected = 0.0;
      for (var j = 0; j < 3; j++) {
        final index = triangles[i + j] * 3;
        point +=
            Offset(vertices[index].toDouble(), vertices[index + 1].toDouble()) /
                3;
        expected += vertices[index + 2] / 3;
      }
      final actual = field.heightAt(point);
      expect(actual, isNotNull);
      final error = (actual! - expected).abs();
      if (error > maximumError) maximumError = error;
      expect(error, lessThan(1e-5));
    }
    // ignore: avoid_print
    print(jsonEncode({
      'triangles': triangles.length ~/ 3,
      'maximumCenterHeightErrorMeters': maximumError
    }));
  });
}
