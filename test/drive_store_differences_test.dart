import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/store_differences.dart';
import 'package:icarus/library_store/strategy_image.dart';

ReadBack Function(String) _readsBack(Set<String> differently) =>
    (id) => differently.contains(id)
        ? const ReadsBackDifferently('lineup order')
        : const ReadsBackEqual();

void main() {
  test(
      'a difference the mirror recorded as reading back differently is listed '
      'as expected, with its reason', () {
    final judged = judgeStoreDifferences(
      differing: {'interleaved'},
      recordedDifferent: {'interleaved': 'lineupOrder pages[0].lineUpLinks'},
      readBackNow: _readsBack({'interleaved'}),
    );

    expect(judged.problems, isEmpty);
    expect(judged.expected, [
      'interleaved reads back differently, as the mirror recorded: '
          'lineupOrder pages[0].lineUpLinks',
    ]);
  });

  test('a difference the mirror did not record fails', () {
    final judged = judgeStoreDifferences(
      differing: {'interleaved', 'unexplained'},
      recordedDifferent: {'interleaved': 'lineup order'},
      readBackNow: _readsBack({'interleaved'}),
    );

    expect(judged.problems, [
      'unexplained differs from Hive, and the mirror did not record that its '
          'rows read back differently',
    ]);
  });

  test(
      'a strategy recorded as reading back differently that reads back equal '
      'fails', () {
    final judged = judgeStoreDifferences(
      differing: {},
      recordedDifferent: {'stale': 'lineup order'},
      readBackNow: _readsBack({}),
    );

    expect(judged.problems, [
      'stale is recorded as reading back differently (lineup order), but its '
          'rows read back equal',
    ]);
  });

  test(
      'a recorded strategy the store check sees no difference in, such as an '
      'agent at -0.0 the store keeps as 0, is expected and says so', () {
    final judged = judgeStoreDifferences(
      differing: {},
      recordedDifferent: {'signed-zero': 'page p0 reads back differently'},
      readBackNow: _readsBack({'signed-zero'}),
    );

    expect(judged.problems, isEmpty);
    expect(
        judged.expected.single, endsWith('the store check sees no difference'));
  });
}
