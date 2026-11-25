import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/strategy_image.dart';
import 'package:icarus/strategy/strategy_models.dart';

import '../library_rows/library_sources.dart';
import 'shadow_copy_corpus_test.dart' show corpusVariable;

int _items(StrategyData strategy) => strategy.pages.fold(
      0,
      (sum, page) =>
          sum +
          page.agentData.length +
          page.abilityData.length +
          page.drawingData.length +
          page.textData.length +
          page.imageData.length +
          page.utilityData.length +
          page.lineUpLinks.length,
    );

double _medianMs(void Function() run) {
  for (var warm = 0; warm < 5; warm++) {
    run();
  }
  final times = <int>[];
  for (var turn = 0; turn < 21; turn++) {
    final clock = Stopwatch()..start();
    run();
    times.add(clock.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2] / 1000;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final corpus = Platform.environment[corpusVariable];

  test(
    'what the read-back check adds to a mirror write, on the strategy with '
    'the most items in the corpus',
    skip: corpus == null ? 'set $corpusVariable to a corpus folder' : false,
    () async {
      StrategyData? largest;
      for (final store in hiveStoresUnder(Directory(corpus!))) {
        for (final strategy in (await loadHiveStore(store)).strategies) {
          if (largest == null || _items(strategy) > _items(largest)) {
            largest = strategy;
          }
        }
      }
      final big = largest!;
      final held = strategyAsHiveHoldsIt(big);
      final rows = _medianMs(() => strategyToRows(held));
      final image = _medianMs(() => imageOf(held));
      // ignore: avoid_print
      print('READBACK ${_items(big)} items, ${big.pages.length} pages: '
          'rows ${rows.toStringAsFixed(2)} ms, rows and read-back '
          '${image.toStringAsFixed(2)} ms, added '
          '${(image - rows).toStringAsFixed(2)} ms (medians of 21)');
      expect(imageOf(held).readBack, isA<ReadBack>());
    },
  );
}
