import 'package:icarus_library/icarus_library.dart';

sealed class RowTexts {
  const RowTexts();
}

final class RowsAsText extends RowTexts {
  const RowsAsText(this.rows);

  final Map<String, String> rows;
}

final class RowsNotText extends RowTexts {
  const RowsNotText(this.key, this.problem);

  final RowKey key;
  final String problem;

  @override
  String toString() => '$key $problem';
}

Object? _withoutRevision(Row row) => switch (row.toJsonView()) {
      final Map<String, Object?> fields => {...fields}..remove('revision'),
      final other => other,
    };

RowTexts rowTextsOf(StrategyRowSet rows) {
  final texts = <String, String>{};
  for (final row in rows.rows) {
    switch (encodeJson(_withoutRevision(row))) {
      case NotEncoded(:final problem):
        return RowsNotText(row.key, problem);
      case Encoded(:final text):
        texts['${row.key}'] = text;
    }
  }
  return RowsAsText(texts);
}
