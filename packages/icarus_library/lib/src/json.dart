import 'dart:convert';

Object? frozenJson(Object? value) => switch (value) {
  null || bool() || String() => value,
  num() when value.isFinite => value,
  List<Object?>() => List<Object?>.unmodifiable(value.map(frozenJson)),
  Map<Object?, Object?>() => Map<String, Object?>.unmodifiable({
    for (final MapEntry(:key, :value) in value.entries)
      _jsonKey(key): frozenJson(value),
  }),
  _ => throw ArgumentError.value(value, 'value', 'not a JSON value'),
};

bool isJson(Object? value) => switch (value) {
  null || bool() || String() => true,
  num() => value.isFinite,
  List<Object?>() => value.every(isJson),
  Map<Object?, Object?>() => value.entries.every(
    (entry) => entry.key is String && isJson(entry.value),
  ),
  _ => false,
};

Map<String, Object?> frozenJsonObject(Map<Object?, Object?> value) =>
    frozenJson(value)! as Map<String, Object?>;

String _jsonKey(Object? key) => key is String
    ? key
    : throw ArgumentError.value(key, 'key', 'a JSON object key is a string');

const _largestExactWhole = 9007199254740991;

Object? _asJavaScript(Object? value, {required bool sortKeys}) =>
    switch (value) {
      Map<Object?, Object?>() => {
        for (final key
            in sortKeys
                ? (value.keys.cast<String>().toList()..sort())
                : value.keys.cast<String>())
          key: _asJavaScript(value[key], sortKeys: sortKeys),
      },
      List<Object?>() => [
        for (final item in value) _asJavaScript(item, sortKeys: sortKeys),
      ],
      double()
          when value == value.truncateToDouble() &&
              value.abs() <= _largestExactWhole =>
        value.toInt(),
      _ => value,
    };

String canonicalJson(Object? value) =>
    jsonEncode(_asJavaScript(value, sortKeys: true));

bool sameJson(Object? left, Object? right) =>
    identical(left, right) || canonicalJson(left) == canonicalJson(right);

const maxOpBytes = 900 * 1024;
const maxArrayEntries = 8000;

bool exceedsSizePolicy(Object? json) =>
    utf8.encode(jsonEncode(_asJavaScript(json, sortKeys: false))).length >
        maxOpBytes ||
    _hasLongList(json);

bool _hasLongList(Object? json) => switch (json) {
  List<Object?>() => json.length > maxArrayEntries || json.any(_hasLongList),
  Map<Object?, Object?>() => json.values.any(_hasLongList),
  _ => false,
};
