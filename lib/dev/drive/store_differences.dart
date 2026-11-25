import 'package:icarus/library_store/strategy_image.dart';

final class StoreDifferences {
  const StoreDifferences({required this.expected, required this.problems});

  final List<String> expected;
  final List<String> problems;
}

StoreDifferences judgeStoreDifferences({
  required Set<String> differing,
  required Map<String, String> recordedDifferent,
  required ReadBack Function(String strategyId) readBackNow,
}) {
  final expected = <String>[];
  final problems = <String>[];
  for (final id in differing.difference(recordedDifferent.keys.toSet())) {
    problems.add('$id differs from Hive, and the mirror did not record that '
        'its rows read back differently');
  }
  for (final MapEntry(key: id, value: words) in recordedDifferent.entries) {
    switch (readBackNow(id)) {
      case ReadsBackEqual():
        problems.add('$id is recorded as reading back differently ($words), '
            'but its rows read back equal');
      case ReadsBackDifferently():
        expected.add('$id reads back differently, as the mirror recorded: '
            '$words${differing.contains(id) ? '' : '; the store check sees no difference'}');
    }
  }
  return StoreDifferences(
    expected: expected..sort(),
    problems: problems..sort(),
  );
}
