import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

abstract interface class LibraryRecords<T> {
  T? get(String id);

  bool containsKey(String id);

  Iterable<T> get values;

  int get length;

  bool get isNotEmpty;

  Listenable listenable({List<String?>? keys});

  Stream<String> changes();
}

final class HiveRecords<T> implements LibraryRecords<T> {
  const HiveRecords(this._box);

  final Box<T> _box;

  @override
  T? get(String id) => _box.get(id);

  @override
  bool containsKey(String id) => _box.containsKey(id);

  @override
  Iterable<T> get values => _box.values;

  @override
  int get length => _box.length;

  @override
  bool get isNotEmpty => _box.isNotEmpty;

  @override
  Listenable listenable({List<String?>? keys}) => _box.listenable(keys: keys);

  @override
  Stream<String> changes() => _box.watch().map((event) => '${event.key}');
}
