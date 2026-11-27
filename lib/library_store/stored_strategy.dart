import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class StoredStrategy {
  const StoredStrategy();
}

final class StoredAsData extends StoredStrategy {
  const StoredAsData(this.strategy);

  final StrategyData strategy;
}

final class StoredMissing extends StoredStrategy {
  const StoredMissing();
}

final class StoredUnreadable extends StoredStrategy {
  StoredUnreadable(List<String> problems)
      : problems = List.unmodifiable(problems);

  final List<String> problems;

  @override
  String toString() => problems.join('; ');
}

final class StoredNotRead extends StoredStrategy {
  const StoredNotRead(this.failure);

  final StorageFailure failure;
}

sealed class _Pages {
  const _Pages();
}

final class _PagesRead extends _Pages {
  const _PagesRead(this.elements, this.groups);

  final List<ElementRow> elements;
  final List<LineupGroupRow> groups;
}

final class _PagesNot extends _Pages {
  const _PagesNot(this.stored);

  final StoredStrategy stored;
}

sealed class StoredRows {
  const StoredRows();
}

final class StoredRowsRead extends StoredRows {
  const StoredRowsRead(this.rows, {this.written = const WrittenNotRecorded()});

  final StrategyRowSet rows;
  final StrategyWritten written;
}

final class StoredRowsNot extends StoredRows {
  const StoredRowsNot(this.stored);

  final StoredStrategy stored;
}

Future<StoredRows> readStoredRows(LibraryStore store, String strategyId) async {
  final StrategyContent content;
  switch (await store.readStrategy(strategyId)) {
    case Found(:final value):
      content = value;
    case NotFound():
      return const StoredRowsNot(StoredMissing());
    case NotRead(:final failure):
      return StoredRowsNot(StoredNotRead(failure));
    case InUnreadableStrategy(:final listing):
      return StoredRowsNot(
        StoredUnreadable(['the strategy row is unreadable: ${listing.ref}']),
      );
  }
  final damaged = [
    for (final row in content.unplaced) 'unplaced ${row.ref}',
    for (final name in content.foreignNames)
      'a name this build does not know: $name',
  ];
  final List<ElementRow> elements;
  final List<LineupGroupRow> groups;
  switch (await _pagesOf(store, strategyId, content, damaged)) {
    case _PagesNot(:final stored):
      await store.unload(strategyId);
      return StoredRowsNot(stored);
    case _PagesRead(elements: final readElements, groups: final readGroups):
      elements = readElements;
      groups = readGroups;
  }
  await store.unload(strategyId);
  for (final row in [
    ...content.pages,
    ...content.settings.values,
    ...elements,
    ...groups,
  ]) {
    switch (row) {
      case UnreadablePage(:final problem) ||
            UnreadablePageSettings(:final problem) ||
            UnreadableElement(:final problem) ||
            UnreadableLineupGroup(:final problem):
        damaged.add('${row.key}: $problem');
      case _:
        break;
    }
  }
  return switch (content.strategy) {
    UnreadableStrategy(:final problem) =>
      StoredRowsNot(StoredUnreadable([...damaged, 'strategy row: $problem'])),
    ReadableStrategy() when damaged.isNotEmpty =>
      StoredRowsNot(StoredUnreadable(damaged)),
    final ReadableStrategy header => StoredRowsRead(
        written: content.written,
        StrategyRowSet(
          strategy: header,
          pages: content.pages,
          settings: content.settings.values,
          elements: elements,
          lineupGroups: groups,
        ),
      ),
  };
}

StoredStrategy strategyOfRows(
  StrategyRowSet rows, {
  int versionNumber = Settings.versionNumber,
}) =>
    switch (strategyFromRows(rows, versionNumber: versionNumber)) {
      StrategyDataRefused(:final problems) => StoredUnreadable([
          for (final problem in problems) 'not converted back: $problem',
        ]),
      StrategyDataMade(:final unreadable, :final notInStrategy)
          when unreadable.isNotEmpty || notInStrategy.isNotEmpty =>
        StoredUnreadable([
          for (final row in unreadable) 'cannot draw ${row.key}',
          for (final row in notInStrategy) 'not in the strategy: ${row.key}',
        ]),
      StrategyDataMade(:final strategy) => StoredAsData(strategy),
    };

Future<_Pages> _pagesOf(
  LibraryStore store,
  String strategyId,
  StrategyContent content,
  List<String> damaged,
) async {
  final elements = <ElementRow>[];
  final groups = <LineupGroupRow>[];
  for (final page in content.pages) {
    switch (await store.readPage(strategyId, page.publicId)) {
      case Found(:final value):
        elements.addAll(value.elements);
        groups.addAll(value.lineupGroups);
        damaged
          ..addAll([for (final row in value.unplaced) 'unplaced ${row.ref}'])
          ..addAll([
            for (final row in value.unknownKinds) 'unknown kind ${row.key}',
            for (final name in value.foreignNames)
              'a name this build does not know: $name',
          ]);
      case NotFound():
        damaged.add('page ${page.publicId} is listed and not found');
      case NotRead(:final failure):
        return _PagesNot(StoredNotRead(failure));
      case InUnreadableStrategy(:final listing):
        return _PagesNot(
          StoredUnreadable(['the strategy row is unreadable: ${listing.ref}']),
        );
    }
  }
  return _PagesRead(elements, groups);
}
