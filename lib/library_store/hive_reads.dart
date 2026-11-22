import 'package:flutter/foundation.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';

sealed class HiveRead<T> {
  const HiveRead();
}

final class InHive<T> extends HiveRead<T> {
  const InHive(this.value);

  final T value;
}

final class NotInHive<T> extends HiveRead<T> {
  const NotInHive();
}

final class HiveStillWriting<T> extends HiveRead<T> {
  const HiveStillWriting();
}

final class HiveSnapshot {
  HiveSnapshot({
    required this.library,
    required Set<String> strategiesWriting,
    required Set<String> foldersWriting,
  })  : strategiesWriting = Set.unmodifiable(strategiesWriting),
        foldersWriting = Set.unmodifiable(foldersWriting);

  final HiveLibrary library;
  final Set<String> strategiesWriting;
  final Set<String> foldersWriting;

  int get writes => strategiesWriting.length + foldersWriting.length;
}

abstract interface class LibraryBoxes {
  StrategyData? strategy(String id);

  Folder? folder(String id);

  Iterable<StrategyData> get strategies;

  Iterable<Folder> get folders;
}

final class _HiveBoxes implements LibraryBoxes {
  const _HiveBoxes();

  @override
  StrategyData? strategy(String id) =>
      const LocalLibrary().storedStrategy(id);

  @override
  Folder? folder(String id) => const LocalLibrary().storedFolder(id);

  @override
  Iterable<StrategyData> get strategies =>
      const LocalLibrary().storedStrategies;

  @override
  Iterable<Folder> get folders => const LocalLibrary().storedFolders;
}

List<Stream<Object?>> libraryBoxEvents() => const LocalLibrary().boxEvents();

Set<String> libraryBoxFileNames() => const LocalLibrary().boxFileNames();

final class HiveReads {
  HiveReads() : _boxes = const _HiveBoxes();

  @visibleForTesting
  HiveReads.over(this._boxes);

  final LibraryBoxes _boxes;
  final _strategiesWriting = <String, int>{};
  final _foldersWriting = <String, int>{};

  bool strategyWriting(String id) => _strategiesWriting.containsKey(id);

  bool folderWriting(String id) => _foldersWriting.containsKey(id);

  void writing(LibraryTouch touch) {
    for (final id in touch.strategies) {
      _strategiesWriting[id] = (_strategiesWriting[id] ?? 0) + 1;
    }
    for (final id in touch.folders) {
      _foldersWriting[id] = (_foldersWriting[id] ?? 0) + 1;
    }
  }

  void answered(LibraryTouch touch) {
    _settle(_strategiesWriting, touch.strategies);
    _settle(_foldersWriting, touch.folders);
  }

  static void _settle(Map<String, int> writing, List<String> ids) {
    for (final id in ids) {
      switch (writing[id]) {
        case null || 1:
          writing.remove(id);
        case final count:
          writing[id] = count - 1;
      }
    }
  }

  HiveRead<StrategyData> strategy(String id) => strategyWriting(id)
      ? const HiveStillWriting()
      : switch (_boxes.strategy(id)) {
          final strategy? => InHive(strategyAsHiveHoldsIt(strategy)),
          null => const NotInHive(),
        };

  HiveRead<Folder> folder(String id) => folderWriting(id)
      ? const HiveStillWriting()
      : switch (_boxes.folder(id)) {
          final folder? => InHive(folderAsHiveHoldsIt(folder)),
          null => const NotInHive(),
        };

  HiveSnapshot library() => HiveSnapshot(
        library: HiveLibrary(
          strategies: [
            for (final strategy in _boxes.strategies)
              if (!strategyWriting(strategy.id)) strategy,
          ],
          folders: [
            for (final folder in _boxes.folders)
              if (!folderWriting(folder.id)) folder,
          ],
        ),
        strategiesWriting: _strategiesWriting.keys.toSet(),
        foldersWriting: _foldersWriting.keys.toSet(),
      );
}
