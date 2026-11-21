import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class RowsDigest {
  const RowsDigest();
}

final class RowsDigested extends RowsDigest {
  const RowsDigested(this.digest, this.rows);

  final String digest;
  final Map<String, String> rows;
}

final class RowsNotDigested extends RowsDigest {
  const RowsNotDigested(this.key, this.problem);

  final RowKey key;
  final String problem;

  @override
  String toString() => '$key $problem';
}

Object? _withoutRevision(Row row) => switch (row.toJsonView()) {
      final Map<String, Object?> fields => {...fields}..remove('revision'),
      final other => other,
    };

RowsDigest rowsDigestOf(StrategyRowSet rows) {
  final texts = <String, String>{};
  for (final row in rows.rows) {
    switch (encodeJson(_withoutRevision(row))) {
      case NotEncoded(:final problem):
        return RowsNotDigested(row.key, problem);
      case Encoded(:final text):
        texts['${row.key}'] = text;
    }
  }
  final keys = texts.keys.toList()..sort();
  final digest = sha256.convert(utf8.encode(jsonEncode([
    for (final key in keys) [key, texts[key]],
  ])));
  return RowsDigested('$digest', texts);
}
