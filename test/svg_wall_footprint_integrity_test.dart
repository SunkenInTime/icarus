import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all bundled wall footprints match the complete geometry audit', () {
    String sourceHash(String path) => sha256
        .convert(
            utf8.encode(File(path).readAsStringSync().replaceAll('\r\n', '\n')))
        .toString();
    final certificate = jsonDecode(
        File('scripts/data/svg-wall-footprint-certificate.json')
            .readAsStringSync()) as Map<String, dynamic>;
    expect(certificate['status'], 'passed');
    expect(certificate['gridSvg'], 1e-8);
    final assets = certificate['assets'] as Map<String, dynamic>;
    final actualPaths = Directory('assets/maps')
        .listSync()
        .whereType<File>()
        .map((f) => f.path.replaceAll(r'\', '/'))
        .where((p) => p.contains('_svg_height_') && p.endsWith('.json.gz'))
        .toSet();
    expect(assets.keys.toSet(), actualPaths,
        reason: 'The geometry audit must cover every bundled map side.');
    expect(actualPaths.length, 26);
    for (final entry in assets.entries) {
      expect(sha256.convert(File(entry.key).readAsBytesSync()).toString(),
          entry.value['sha256'],
          reason: '${entry.key} changed after its geometry audit. Run '
              'python scripts/svg_wall_footprint_integrity.py before packaging.');
    }
    expect(sourceHash('scripts/svg_wall_footprint_integrity.py'),
        certificate['algorithmSha256']);
    expect(sourceHash('scripts/compile_reviewed_svg_height_map.py'),
        certificate['polygonReaderSha256']);
  });
}
