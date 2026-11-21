import 'json.dart';

const latestTime = 8640000000000000;

const largestSafeWhole = 9007199254740991;

sealed class Decoded<T> {
  const Decoded();
}

final class Read<T> extends Decoded<T> {
  const Read(this.value);

  final T value;
}

final class CouldNotRead<T> extends Decoded<T> {
  const CouldNotRead(this.json, this.problem);

  final Object? json;
  final String problem;
}

bool isSafeWhole(Object? value) =>
    value is num &&
    value.isFinite &&
    value == value.truncate() &&
    value >= -largestSafeWhole &&
    value <= largestSafeWhole;

final class JsonFields {
  JsonFields._(this.json);

  JsonFields.over(JsonObject object) : json = object.raw;

  String? get problem => _problem;

  final Map<String, Object?> json;
  String? _problem;

  static Decoded<T> read<T>(
    Object? raw,
    String what,
    T Function() Function(JsonFields fields) read,
  ) {
    final object = jsonObjectOrNull(raw);
    if (object == null) {
      return CouldNotRead(raw, 'Expected $what to be a JSON object');
    }
    final fields = JsonFields._(object.raw);
    final build = read(fields);
    return switch (fields._problem) {
      final problem? => CouldNotRead(raw, '$what: $problem'),
      null => Read(build()),
    };
  }

  void reject(String problem) => _problem ??= problem;

  T _expected<T>(String key, String kind, T fallback) {
    reject('expected "$key" to be $kind');
    return fallback;
  }

  bool has(String key) => json[key] != null;

  String string(String key) => switch (json[key]) {
    final String value => value,
    _ => _expected(key, 'a string', ''),
  };

  String? optionalString(String key) => has(key) ? string(key) : null;

  int whole(String key) => switch (json[key]) {
    final num value when isSafeWhole(value) => value.toInt(),
    _ => _expected(key, 'a whole number JavaScript holds exactly', 0),
  };

  int? optionalWhole(String key) => has(key) ? whole(key) : null;

  double number(String key) => switch (json[key]) {
    final num value when value.isFinite => value.toDouble(),
    _ => _expected(key, 'a number', 0),
  };

  bool boolean(String key) => switch (json[key]) {
    final bool value => value,
    _ => _expected(key, 'true or false', false),
  };

  bool? optionalBoolean(String key) => has(key) ? boolean(key) : null;

  DateTime time(String key) => switch (json[key]) {
    final num value
        when value.isFinite &&
            value == value.truncate() &&
            value >= -latestTime &&
            value <= latestTime =>
      DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true),
    _ => _expected(key, 'a time in milliseconds', DateTime.utc(1970)),
  };

  DateTime? optionalTime(String key) => has(key) ? time(key) : null;

  JsonObject rest(Set<String> known) => adoptJsonObject({
    for (final MapEntry(:key, :value) in json.entries)
      if (!known.contains(key)) key: value,
  });

  JsonObject object(String key) => switch (json[key]) {
    final Map<String, Object?> value => adoptJsonObject(value),
    _ => _expected(key, 'an object', JsonObject.empty),
  };

  T? decoded<T>(String key, Decoded<T> Function(Object? json) decode) =>
      switch (decode(adoptJson(json[key]))) {
        Read(:final value) => value,
        CouldNotRead(:final problem) => _expected(
          key,
          'readable: $problem',
          null,
        ),
      };

  T? optionalDecoded<T>(String key, Decoded<T> Function(Object? json) decode) =>
      has(key) ? decoded(key, decode) : null;
}
