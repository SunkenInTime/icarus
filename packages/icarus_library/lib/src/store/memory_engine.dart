import 'dart:collection';

import 'engine.dart';

final class MemoryEngine implements StorageEngine {
  MemoryEngine([Map<String, Map<String, String>> contents = const {}]) {
    for (final MapEntry(key: area, value: values) in contents.entries) {
      _area(area).addAll(values);
    }
  }

  final _areas = <String, SplayTreeMap<String, String>>{};

  Map<String, Map<String, String>> get contents => {
    for (final MapEntry(:key, :value) in _areas.entries)
      if (value.isNotEmpty) key: Map.unmodifiable(value),
  };

  SplayTreeMap<String, String> _area(String area) =>
      _areas.putIfAbsent(area, SplayTreeMap.new);

  @override
  Future<Stored<String?>> read(String area, String key) async =>
      Done(_areas[area]?[key]);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async => Done([
    for (final key in _areas[area]?.keys ?? const <String>[])
      if (key.startsWith(prefix)) key,
  ]);

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) async {
    _area(area).addAll(values);
    return done;
  }

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) async {
    final stored = _area(area);
    keys.forEach(stored.remove);
    return done;
  }
}
