@Tags(['timing'])
library;

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'library_edit_cost_test.dart' show libraryOf;
import 'store_support.dart';
import 'support.dart';

const _budget = 1.5;

const _runs = 25;

Future<Map<String, int>> _fastest(Contents library) async {
  final store = await openStore(MemoryEngine(MemoryStorage(library)));
  final fastest = <String, int>{};
  Future<void> time(String what, LibraryChange change) async {
    final watch = Stopwatch()..start();
    savedValue(await store.editLibrary([change]));
    final micros = watch.elapsedMicroseconds;
    fastest[what] = fastest.containsKey(what)
        ? (micros < fastest[what]! ? micros : fastest[what]!)
        : micros;
  }

  for (var run = 0; run < _runs; run++) {
    final id = 'timed-$run';
    await time(
      'add',
      AddStrategy(
        StrategyRowSet(
          strategy: strategyRow(publicId: id),
          pages: [
            LivePage(
              publicId: '$id-page',
              strategyPublicId: id,
              name: 'Page 1',
              sortIndex: 0,
              isAttack: true,
              revision: 1,
            ),
          ],
          settings: [settings('$id-page')],
        ),
      ),
    );
    await time('move', MoveStrategy(id, 'folder'));
    await time('remove', RemoveStrategy(id));
  }
  await store.close();
  return fastest;
}

void main() {
  test('adding, moving and removing a strategy take no longer in a library of '
      '2,800 strategies than in one of 100, within $_budget times', () async {
    final library = await libraryOf(100);
    await _fastest(library);
    final small = await _fastest(library);
    final large = await _fastest(await libraryOf(2800));
    for (final what in small.keys) {
      final ratio = large[what]! / small[what]!;
      printOnFailure(
        '$what: ${small[what]} µs at 100, ${large[what]} µs at 2,800',
      );
      expect(ratio, lessThan(_budget), reason: what);
    }
  });
}
