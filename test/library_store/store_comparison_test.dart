import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart';

const held = (id: 'strategy-a', name: 'Send');

List<String> problems(
  List<ServerComparison> compared, {
  List<ExpectedStrategy> expected = const [held],
  List<LaggingRow> lagging = const [],
}) =>
    [
      for (final line in comparisonLines(
        when: 'at the end',
        readAs: 'account-a',
        held: compared,
        expected: expected,
        lagging: lagging,
      ))
        if (line.problem) line.text,
    ];

ServerComparison comparedWith({
  List<String> unjudged = const [],
  List<String>? differences = const [],
}) =>
    (
      strategyId: held.id,
      name: held.name,
      verdict: Compared(
        pages: 1,
        unjudged: unjudged,
        differences: differences,
      ),
    );

const olderMove = 'page p1: item a1: the store holds live at revision 2, '
    'the server sent live at revision 3';

void main() {
  test('a strategy equal to the server\'s copy passes', () {
    expect(problems([comparedWith()]), isEmpty);
  });

  test('a server copy whose header the store never judged fails', () {
    expect(problems([comparedWith(differences: null)]), hasLength(1));
  });

  test('a server page that could not be judged fails', () {
    expect(
      problems([
        comparedWith(unjudged: ['page p2: the page could not be read']),
      ]),
      hasLength(1),
    );
  });

  test('a strategy the script expects and the store does not hold fails', () {
    expect(problems([]), hasLength(1));
  });

  test(
      'a store holding only another account\'s strategy fails when the '
      'script expects its own', () {
    expect(
      problems([
        (
          strategyId: 'strategy-b',
          name: 'Theirs',
          verdict: const NotCompared('the work of account-b'),
        ),
      ]),
      hasLength(1),
    );
  });

  test('a script that names no strategy fails', () {
    expect(problems([comparedWith()], expected: const []), hasLength(1));
  });

  test(
      'a declared lag excuses only an older revision of its row; anything '
      'else in the strategy still fails', () {
    const lag = (row: 'a1', why: 'the teammate moved it');
    expect(
      problems([
        comparedWith(differences: [olderMove]),
      ], lagging: const [
        lag
      ]),
      isEmpty,
    );
    expect(
      problems([
        comparedWith(differences: [
          olderMove,
          'page p1: item b1: the store holds live at revision 2, the server '
              'sent live at revision 3',
          'page p1: item a1: missing from the store',
          'page p1: item a1: the store holds live at revision 4, the server '
              'sent live at revision 3',
          'page list: the store holds p1, the server sent p1, p2',
        ]),
      ], lagging: const [
        lag
      ]),
      hasLength(4),
    );
  });
}
