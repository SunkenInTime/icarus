import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/strategy/strategy_models.dart';
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

Future<StoredStrategy> readStoredStrategy(
  LibraryStore store,
  String strategyId,
) async {
  final StrategyContent content;
  switch (await store.readStrategy(strategyId)) {
    case Found(:final value):
      content = value;
    case NotFound():
      return const StoredMissing();
    case NotRead(:final failure):
      return StoredNotRead(failure);
    case InUnreadableStrategy(:final listing):
      return StoredUnreadable(
          ['the strategy row is unreadable: ${listing.ref}']);
  }
  final damaged = [for (final row in content.unplaced) 'unplaced ${row.ref}'];
  final List<ElementRow> elements;
  final List<LineupGroupRow> groups;
  switch (await _pagesOf(store, strategyId, content, damaged)) {
    case _PagesNot(:final stored):
      await store.unload(strategyId);
      return stored;
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
  final header = content.strategy;
  switch (header) {
    case UnreadableStrategy(:final problem):
      return StoredUnreadable([...damaged, 'strategy row: $problem']);
    case ReadableStrategy() when damaged.isNotEmpty:
      return StoredUnreadable(damaged);
    case ReadableStrategy():
      break;
  }
  final back = strategyFromRows(
    StrategyRowSet(
      strategy: header,
      pages: content.pages,
      settings: content.settings.values,
      elements: elements,
      lineupGroups: groups,
    ),
  );
  return switch (back) {
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
}

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
