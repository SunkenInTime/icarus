import 'dart:math';

import 'package:icarus_library/src/json.dart';
import 'package:test/test.dart';

final class Trees {
  Trees(int seed) : random = Random(seed);

  final Random random;

  Object? leaf() => switch (random.nextInt(8)) {
    0 => random.nextInt(5),
    1 => random.nextInt(5).toDouble(),
    2 => random.nextInt(5) + 0.5,
    3 => -0.0,
    4 => ['a', 'b', ''][random.nextInt(3)],
    5 => random.nextBool(),
    6 => null,
    _ => 9007199254740991,
  };

  Object? tree(int depth) => switch (depth == 0 ? 0 : random.nextInt(3)) {
    0 => leaf(),
    1 => [for (var i = random.nextInt(4); i > 0; i--) tree(depth - 1)],
    _ => {
      for (var i = random.nextInt(4); i > 0; i--)
        ['x', 'y', 'z', 'w'][random.nextInt(4)]: tree(depth - 1),
    },
  };

  Object? lookalike(Object? value) => switch (value) {
    final Map<String, Object?> map => {
      for (final key in map.keys.toList().reversed) key: lookalike(map[key]),
    },
    final List<Object?> list => [for (final item in list) lookalike(item)],
    final int whole when random.nextBool() => whole.toDouble(),
    final double whole
        when whole == whole.truncateToDouble() &&
            whole.abs() < 1e15 &&
            random.nextBool() =>
      whole.toInt(),
    _ => random.nextInt(12) == 0 ? leaf() : value,
  };
}

void main() {
  test('agrees with comparing canonical JSON', () {
    var same = 0;
    var different = 0;
    for (var seed = 0; seed < 3000; seed++) {
      final trees = Trees(seed);
      final left = trees.tree(4);
      final right = trees.lookalike(left);
      final expected = sameJson(left, right);
      expect(sameJsonTree(left, right), expected, reason: 'seed $seed');
      expect(
        sameJsonTree(jsonValue(left), right),
        expected,
        reason: 'seed $seed, read-only view on the left',
      );
      expected ? same++ : different++;
    }
    expect(same, greaterThan(500));
    expect(different, greaterThan(200));
  });
}
