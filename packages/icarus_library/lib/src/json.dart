import 'dart:convert';

final class JsonObject {
  const JsonObject._(this._map);

  static const empty = JsonObject._({});

  final Map<String, Object?> _map;

  Object? operator [](String key) => _view(_map[key]);

  bool containsKey(String key) => _map.containsKey(key);

  Iterable<String> get keys => _map.keys;

  Iterable<Object?> get values => _map.values.map(_view);

  Iterable<MapEntry<String, Object?>> get entries =>
      _map.entries.map((entry) => MapEntry(entry.key, _view(entry.value)));

  int get length => _map.length;

  bool get isEmpty => _map.isEmpty;

  bool get isNotEmpty => _map.isNotEmpty;

  Map<String, Object?> toMap() => viewsOf(this);

  Map<String, Object?> toJson() => _plain(_map)! as Map<String, Object?>;

  @override
  String toString() => canonicalJson(this);
}

final class JsonList extends Iterable<Object?> {
  const JsonList._(this._list);

  final List<Object?> _list;

  Object? operator [](int index) => _view(_list[index]);

  @override
  int get length => _list.length;

  @override
  Iterator<Object?> get iterator => _list.map(_view).iterator;

  List<Object?> toJson() => _plain(_list)! as List<Object?>;

  @override
  String toString() => canonicalJson(this);
}

extension JsonObjectInside on JsonObject {
  Map<String, Object?> get raw => _map;
}

extension JsonListInside on JsonList {
  List<Object?> get raw => _list;
}

JsonObject adoptJsonObject(Map<String, Object?> trusted) =>
    JsonObject._(trusted);

Object? adoptJson(Object? trusted) => _view(trusted);

Map<String, Object?> viewsOf(JsonObject object) => {
  for (final MapEntry(:key, :value) in object._map.entries) key: _view(value),
};

Object? _view(Object? raw) => switch (raw) {
  final Map<String, Object?> map => JsonObject._(map),
  final List<Object?> list => JsonList._(list),
  _ => raw,
};

Object? _raw(Object? value) => switch (value) {
  JsonObject(:final _map) => _map,
  JsonList(:final _list) => _list,
  _ => value,
};

Object? plainJson(Object? value) => _plain(value);

Object? _plain(Object? raw) => switch (raw) {
  JsonObject(:final _map) => _plain(_map),
  JsonList(:final _list) => _plain(_list),
  final Map<String, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries) key: _plain(value),
  },
  final List<Object?> list => [for (final item in list) _plain(item)],
  _ => raw,
};

final class _NotJson {
  const _NotJson();
}

const _notJson = _NotJson();

const maxJsonDepth = 128;

Object? _adopt(Object? value, [int depth = 0]) {
  switch (value) {
    case null || bool() || String():
      return value;
    case JsonObject(:final _map):
      return _map;
    case JsonList(:final _list):
      return _list;
    case num():
      return value.isFinite ? value : _notJson;
    case List<Object?>() when depth < maxJsonDepth:
      final items = List<Object?>.filled(value.length, null);
      for (var i = 0; i < value.length; i++) {
        final item = _adopt(value[i], depth + 1);
        if (identical(item, _notJson)) return _notJson;
        items[i] = item;
      }
      return List<Object?>.unmodifiable(items);
    case Map<Object?, Object?>() when depth < maxJsonDepth:
      final entries = <String, Object?>{};
      for (final MapEntry(:key, :value) in value.entries) {
        if (key is! String) return _notJson;
        final item = _adopt(value, depth + 1);
        if (identical(item, _notJson)) return _notJson;
        entries[key] = item;
      }
      return Map<String, Object?>.unmodifiable(entries);
    case _:
      return _notJson;
  }
}

sealed class Admission {
  const Admission();
}

final class Admitted extends Admission {
  const Admitted._(this.json);

  final Object? json;
}

final class NotAdmitted extends Admission {
  const NotAdmitted(this.text, this.problem);

  final String text;
  final String problem;
}

sealed class _Scan {
  const _Scan();
}

final class _Clean extends _Scan {
  const _Clean();
}

final class _Unsafe extends _Scan {
  const _Unsafe(this.problem);

  final String problem;
}

const _largestExactWhole = '9007199254740991';

const _exponentCeiling = 450359962737049;

const _mostMantissaDigits = 100;

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

bool _isExact(String digits) =>
    digits.length < _largestExactWhole.length ||
    (digits.length == _largestExactWhole.length &&
        digits.compareTo(_largestExactWhole) <= 0);

_Scan _scan(String text) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  var at = 0;
  while (at < text.length) {
    final unit = text.codeUnitAt(at);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (unit == 0x5c) {
        escaped = true;
      } else if (unit == 0x22) {
        inString = false;
      }
      at++;
      continue;
    }
    if (_isDigit(unit)) {
      final start = at;
      while (at < text.length && _isDigit(text.codeUnitAt(at))) {
        at++;
      }
      final integerDigits = at - start;
      var fraction = false;
      var fractionZeros = 0;
      var fractionDigits = 0;
      if (at < text.length && text.codeUnitAt(at) == 0x2e) {
        fraction = true;
        at++;
        final fractionStart = at;
        while (at < text.length && _isDigit(text.codeUnitAt(at))) {
          at++;
        }
        fractionDigits = at - fractionStart;
        while (fractionStart + fractionZeros < at &&
            text.codeUnitAt(fractionStart + fractionZeros) == 0x30) {
          fractionZeros++;
        }
      }
      var exponent = 0;
      var hasExponent = false;
      if (at < text.length && (text.codeUnitAt(at) | 0x20) == 0x65) {
        hasExponent = true;
        at++;
        var sign = 1;
        if (at < text.length && text.codeUnitAt(at) == 0x2d) sign = -1;
        if (at < text.length &&
            (text.codeUnitAt(at) == 0x2d || text.codeUnitAt(at) == 0x2b)) {
          at++;
        }
        while (at < text.length && _isDigit(text.codeUnitAt(at))) {
          if (exponent < _exponentCeiling) {
            exponent = exponent * 10 + text.codeUnitAt(at) - 0x30;
          }
          at++;
        }
        exponent *= sign;
      }
      if (integerDigits + fractionDigits > _mostMantissaDigits) {
        return const _Unsafe(
          'holds a number spelled with more digits than any build writes',
        );
      }
      if (!fraction && !hasExponent) {
        if (integerDigits >= _largestExactWhole.length &&
            !_isExact(text.substring(start, at))) {
          return const _Unsafe(
            'holds a whole number JavaScript cannot hold exactly',
          );
        }
        continue;
      }
      final leading = integerDigits == 1 && unit == 0x30
          ? -(fractionZeros + 1)
          : integerDigits - 1;
      if (leading + exponent >= 308 &&
          !(double.tryParse(text.substring(start, at)) ?? 0).isFinite) {
        return const _Unsafe('holds a number that is not finite');
      }
      continue;
    }
    switch (unit) {
      case 0x22:
        inString = true;
      case 0x5b || 0x7b:
        depth++;
        if (depth > maxJsonDepth) {
          return const _Unsafe('nests deeper than $maxJsonDepth');
        }
      case 0x5d || 0x7d:
        depth--;
    }
    at++;
  }
  return const _Clean();
}

Admission admit(String text) {
  if (_scan(text) case _Unsafe(:final problem)) {
    return NotAdmitted(text, problem);
  }
  final Object? parsed;
  try {
    parsed = jsonDecode(text);
  } on FormatException catch (error) {
    return NotAdmitted(text, 'not JSON: ${error.message}');
  }
  return Admitted._(_view(parsed));
}

sealed class Encoding {
  const Encoding();
}

final class Encoded extends Encoding {
  const Encoded(this.text);

  final String text;
}

final class NotEncoded extends Encoding {
  const NotEncoded(this.problem);

  final String problem;
}

Encoding encodeJson(Object? value) => isJson(value)
    ? Encoded(canonicalJson(value))
    : const NotEncoded(
        'holds a number that is not finite, nesting deeper than '
        '$maxJsonDepth, or a value that is not JSON',
      );

Object? jsonValue(Object? value) => switch (_adopt(value)) {
  _NotJson() => throw ArgumentError.value(value, 'value', 'not a JSON value'),
  final adopted => _view(adopted),
};

JsonObject? jsonObjectOrNull(Object? value) => switch (value) {
  final JsonObject object => object,
  Map<Object?, Object?>() => switch (_adopt(value)) {
    final Map<String, Object?> adopted => JsonObject._(adopted),
    _ => null,
  },
  _ => null,
};

bool isJson(Object? value) => !identical(_adopt(value), _notJson);

JsonObject jsonObject(Map<Object?, Object?> value) =>
    jsonObjectOrNull(value) ??
    (throw ArgumentError.value(value, 'value', 'not a JSON object'));

const _largestWholeAsInt = 9.2e18;

Object? _asJavaScript(Object? value, {required bool sortKeys}) =>
    switch (_raw(value)) {
      final Map<Object?, Object?> value => {
        for (final key
            in sortKeys
                ? (value.keys.cast<String>().toList()..sort())
                : value.keys.cast<String>())
          key: _asJavaScript(value[key], sortKeys: sortKeys),
      },
      final List<Object?> value => [
        for (final item in value) _asJavaScript(item, sortKeys: sortKeys),
      ],
      final double value
          when value == value.truncateToDouble() &&
              value.abs() < _largestWholeAsInt =>
        value.toInt(),
      final value => value,
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

bool _hasLongList(Object? json) => switch (_raw(json)) {
  final List<Object?> list =>
    list.length > maxArrayEntries || list.any(_hasLongList),
  final Map<Object?, Object?> map => map.values.any(_hasLongList),
  _ => false,
};
