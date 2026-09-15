import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled measured standing aliases belong to their reviewed source', () {
    String sourceHash(String path) => sha256
        .convert(
            utf8.encode(File(path).readAsStringSync().replaceAll('\r\n', '\n')))
        .toString();
    final certificate = jsonDecode(
        File('scripts/data/standing-source-certificate.json')
            .readAsStringSync());
    expect(certificate['status'], 'passed');
    expect(certificate['algorithmSha256'],
        sourceHash('scripts/standing_source_integrity.py'));
    expect(certificate['manifestSha256'],
        sourceHash('scripts/data/map-standing-source-manifest.json'));
    final rows = certificate['rows'] as List;
    final paths = Directory('assets/maps')
        .listSync()
        .whereType<File>()
        .map((f) => f.path.replaceAll(r'\', '/'))
        .where((p) => p.contains('_svg_height_') && p.endsWith('.json.gz'))
        .toSet();
    expect(rows.map((r) => r['asset']).toSet(), paths);
    expect(rows.length, 26);
    for (final row in rows) {
      expect(row['status'], 'passed');
      expect(row['unknown'], isEmpty);
      expect(sha256.convert(File(row['asset']).readAsBytesSync()).toString(),
          row['assetSha256'],
          reason:
              'Run python scripts/standing_source_integrity.py on the reviewed source before packaging.');
    }
  });
}
