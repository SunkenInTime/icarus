import 'dart:collection';
import 'dart:convert';

final class _FrozenMap extends UnmodifiableMapView<String, Object?> {
  _FrozenMap(super.map);
}

final class _FrozenList extends UnmodifiableListView<Object?> {
  _FrozenList(super.source);
}

final class _NotJson {
  const _NotJson();
}

const _notJson = _NotJson();

Object? _freeze(Object? value) {
  switch (value) {
    case null || bool() || String() || _FrozenMap() || _FrozenList():
      return value;
    case num():
      return value.isFinite ? value : _notJson;
    case List<Object?>():
      final items = List<Object?>.filled(value.length, null);
      for (var i = 0; i < value.length; i++) {
        final item = _freeze(value[i]);
        if (identical(item, _notJson)) return _notJson;
        items[i] = item;
      }
      return _FrozenList(items);
    case Map<Object?, Object?>():
      final entries = <String, Object?>{};
      for (final MapEntry(:key, :value) in value.entries) {
        if (key is! String) return _notJson;
        final item = _freeze(value);
        if (identical(item, _notJson)) return _notJson;
        entries[key] = item;
      }
      return _FrozenMap(entries);
    case _:
      return _notJson;
  }
}

Object? frozenJson(Object? value) => switch (_freeze(value)) {
  _NotJson() => throw ArgumentError.value(value, 'value', 'not a JSON value'),
  final frozen => frozen,
};

Map<String, Object?>? frozenJsonObjectOrNull(Object? value) => switch (value) {
  Map<Object?, Object?>() => switch (_freeze(value)) {
    final Map<String, Object?> frozen => frozen,
    _ => null,
  },
  _ => null,
};

bool isJson(Object? value) => !identical(_freeze(value), _notJson);

Map<String, Object?> frozenJsonObject(Map<Object?, Object?> value) =>
    frozenJson(value)! as Map<String, Object?>;

const _largestWholeAsInt = 9.2e18;

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
              value.abs() < _largestWholeAsInt =>
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
