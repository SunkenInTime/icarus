// Run after `flutter build windows --release`:
// flutter test --no-pub tool/verify_production_height_test.dart
// Optional dart-defines: ICARUS_HEIGHT_BUNDLE, ICARUS_HEIGHT_LIBRARY,
// ICARUS_HEIGHT_CACHE, ICARUS_HEIGHT_REPORT.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/height_native.dart';
import 'package:path/path.dart' as path;

class _InstalledAssets extends CachingAssetBundle {
  _InstalledAssets(this.directory);
  final String directory;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(path.join(directory, key)).readAsBytes());
}

Future<String> _sha(Uint8List bytes) async {
  final hash = await Sha256().hash(bytes);
  return hash.bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('installed assets and native library match frozen source-origin meshes',
      () async {
    const installed = 'build/windows/x64/runner/Release';
    const library = String.fromEnvironment('ICARUS_HEIGHT_LIBRARY',
        defaultValue: '$installed/icarus_height.dll');
    const bundleDirectory = String.fromEnvironment('ICARUS_HEIGHT_BUNDLE',
        defaultValue: '$installed/data/flutter_assets');
    const cacheDirectory = String.fromEnvironment('ICARUS_HEIGHT_CACHE',
        defaultValue: 'build/height-integration-cache');
    const reportFile = String.fromEnvironment('ICARUS_HEIGHT_REPORT');
    final fixture = jsonDecode(
        await File('test/fixtures/height_native_regression.json')
            .readAsString()) as Map<String, dynamic>;
    final bundle = _InstalledAssets(path.absolute(bundleDirectory));
    final maps = <String, Object>{};
    var totalCoordinates = 0;
    for (final map in MapValue.values) {
      final watch = Stopwatch()..start();
      final assets = await loadHeightAssets(map,
          bundle: bundle, cacheRoot: Directory(path.absolute(cacheDirectory)));
      final reference = fixture['maps'][map.name] as Map<String, dynamic>;
      expect(assets.entry.packSha256, reference['packSha256']);
      final navigation =
          await loadVerifiedHeightNavigation(map, bundle: bundle);
      expect(navigation, isNotEmpty);
      final worker = await HeightNativeWorker.open(
          path.absolute(library), assets.folder, 4);
      var coordinates = 0;
      try {
        final queries = reference['queries'] as List;
        for (var first = 0; first < queries.length; first += 10) {
          final batch = queries.skip(first).take(10).toList();
          final input = Float64List.fromList([
            for (final query in batch)
              ...(query['values'] as List)
                  .map((value) => (value as num).toDouble())
          ]);
          final result = await worker.compute(first, input);
          for (var index = 0; index < batch.length; index++) {
            final mesh = result.cone(index);
            expect(mesh.length, batch[index]['floatCount'],
                reason: '${map.name} query ${first + index}');
            expect(
                await _sha(mesh.buffer
                    .asUint8List(mesh.offsetInBytes, mesh.lengthInBytes)),
                batch[index]['meshSha256'],
                reason: '${map.name} query ${first + index}');
            coordinates += mesh.length;
          }
        }
        final last = Float64List.fromList((queries.last['values'] as List)
            .map((value) => (value as num).toDouble())
            .toList());
        final finalFrame = worker.compute(999, last);
        final closing = worker.close();
        await expectLater(worker.compute(1000, last), throwsStateError);
        expect((await finalFrame).stamp, 999);
        await closing;
        maps[map.name] = {
          'queries': queries.length,
          'exactFloat32Coordinates': coordinates,
          'loadAndVerificationMillis': watch.elapsedMilliseconds,
          'native': worker.info,
          'closeDuringFrame': 'passed',
        };
      } finally {
        await worker.close();
      }
      totalCoordinates += coordinates;
    }
    final report = {
      'status': 'passed',
      'scope':
          'Packaged desktop assets, production loader, native query transfer and map disposal. No GPU or live-game certification.',
      'librarySha256': await _sha(await File(library).readAsBytes()),
      'maps': maps,
      'exactFloat32Coordinates': totalCoordinates,
    };
    if (reportFile.isNotEmpty) {
      await File(reportFile)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    }
    // Printed so CI retains a useful summary even without a report path.
    stdout.writeln(jsonEncode(report));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
