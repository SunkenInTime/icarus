import 'dart:convert';

import '../wire.dart';

final class UnreadableRow {
  const UnreadableRow({
    required this.area,
    required this.key,
    required this.text,
    required this.problem,
  });

  final String area;
  final String key;
  final String text;
  final String problem;
}

sealed class StoredText<T> {
  const StoredText();
}

final class ReadText<T> extends StoredText<T> {
  const ReadText(this.value);

  final T value;
}

final class UnreadableText<T> extends StoredText<T> {
  const UnreadableText(this.row);

  final UnreadableRow row;
}

StoredText<T> readStored<T>(
  String area,
  String key,
  String text,
  Decoded<T> Function(Object? json) decode,
) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (error) {
    return UnreadableText(
      UnreadableRow(area: area, key: key, text: text, problem: error.message),
    );
  }
  return switch (decode(json)) {
    Read(:final value) => ReadText(value),
    CouldNotRead(:final problem) => UnreadableText(
      UnreadableRow(area: area, key: key, text: text, problem: problem),
    ),
  };
}
