import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import '../tool/merge_stories.dart';

Object? _dataOf(Row row) => switch (row) {
  ReadableElementRow(:final payload) => payload.data.toJson(),
  ReadableLineupGroupRow(:final payload) => payload.data.toJson(),
  final other => fail('$other holds no payload'),
};

int _placeOf(Row row) => switch (row) {
  ReadableElementRow(:final sortIndex) => sortIndex,
  ReadableLineupGroupRow(:final sortIndex) => sortIndex,
  final other => fail('$other has no place'),
};

void main() {
  for (final story in mergeStories()) {
    test(story.name, () {
      var rows = storyRows;
      final outcomes = <Map<String, Object?>>[];
      for (final op in story.ops) {
        final result = applyOp(rows, op);
        outcomes.add(outcomeJson(result));
        if (result is OpApplied) rows = rows.withRows(result.rows);
      }
      expect(outcomes, story.outcomes);
      for (final MapEntry(key: id, value: fields) in story.expected.entries) {
        final row = rows.element(id) ?? rows.lineupGroup(id);
        final data = _dataOf(row!)! as Map<String, Object?>;
        for (final MapEntry(:key, :value) in fields.entries) {
          expect(
            key == placeField ? _placeOf(row) : data[key],
            value,
            reason: '$id.$key',
          );
        }
      }
    });
  }
}
