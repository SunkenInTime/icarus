import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive_ce.dart';

import '../store/engine.dart';
import '../store/layout.dart';
import 'failure_io.dart' if (dart.library.js_interop) 'failure_web.dart';

const _maxKeyLength = 255;

sealed class _Box {
  const _Box();

  BoxBase<String> get box;

  Future<String?> get(String key);
}

final class _HeldBox extends _Box {
  const _HeldBox(this.box);

  @override
  final Box<String> box;

  @override
  Future<String?> get(String key) async => box.get(key);
}

final class _LazyBox extends _Box {
  const _LazyBox(this.box);

  @override
  final LazyBox<String> box;

  @override
  Future<String?> get(String key) => box.get(key);
}

final class HiveEngine implements StorageEngine {
  HiveEngine(this.directory);

  static String? _directoryInUse;
  static var _enginesOpen = 0;

  final String? directory;
  var _holdsDirectory = false;

  @override
  int get maxKeyLength => _maxKeyLength;

  Future<Stored<_Box>> _box(String area) async {
    if (!_holdsDirectory) {
      if (_enginesOpen > 0 && _directoryInUse != directory) {
        return StorageFailed(
          DeviceFailure(
            'Hive already holds the store boxes for $_directoryInUse',
          ),
        );
      }
      _directoryInUse = directory;
      _enginesOpen++;
      _holdsDirectory = true;
    }
    final opening = _boxes[area] ??= _openBox(area);
    final opened = await opening;
    if (opened is StorageFailed<_Box>) {
      _boxes.removeWhere((_, value) => identical(value, opening));
    }
    return opened;
  }

  final _boxes = <String, Future<Stored<_Box>>>{};

  static String boxName(String area) => switch (area) {
    libraryArea || journalArea => 'icarus_store_$area',
    _ => 'icarus_store_${sha1.convert(utf8.encode(area))}',
  };

  Future<Stored<_Box>> _openBox(String area) => guarded(
    () async => switch (area) {
      journalArea => _HeldBox(
        await Hive.openBox<String>(
          boxName(area),
          path: directory,
          compactionStrategy: (entries, deleted) => deleted > 0,
        ),
      ),
      libraryArea => _HeldBox(
        await Hive.openBox<String>(boxName(area), path: directory),
      ),
      _ => _LazyBox(
        await Hive.openLazyBox<String>(boxName(area), path: directory),
      ),
    },
  );

  Future<Stored<T>> _with<T>(
    String area,
    Future<T> Function(_Box box) task,
  ) async => switch (await _box(area)) {
    StorageFailed(:final failure) => StorageFailed(failure),
    Done(value: final box) => guarded(() => task(box)),
  };

  @override
  Future<Stored<String?>> read(String area, String key) =>
      _with(area, (box) => box.get(key));

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) => _with(
    area,
    (box) async => [
      for (final key in box.box.keys.cast<String>())
        if (key.startsWith(prefix)) key,
    ],
  );

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) async {
    for (final key in values.keys) {
      if (key.length > _maxKeyLength) {
        return StorageFailed(KeyTooLong(area, key));
      }
    }
    return _with(area, (box) async {
      await box.box.putAll(values);
      await box.box.flush();
    });
  }

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) =>
      _with(area, (box) async {
        await box.box.deleteAll(keys);
        await box.box.flush();
      });

  Future<void> close() async {
    for (final opening in _boxes.values) {
      if (await opening case Done(value: final box)) await box.box.close();
    }
    _boxes.clear();
    if (_holdsDirectory) {
      _holdsDirectory = false;
      _enginesOpen--;
    }
  }
}
