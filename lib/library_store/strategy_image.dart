import 'dart:convert';

import 'package:icarus/const/maps.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class ReadBack {
  const ReadBack();
}

final class ReadsBackEqual extends ReadBack {
  const ReadsBackEqual();
}

final class ReadsBackDifferently extends ReadBack {
  const ReadsBackDifferently(this.words);

  final String words;
}

final class StrategyImage {
  const StrategyImage(this.rows, this.readBack, {this.partsReadBack = 0});

  final StrategyToRows rows;
  final ReadBack readBack;
  final int partsReadBack;
}

final class StrategyImages {
  final _partsReadingBackEqual = <String, Set<String>>{};

  StrategyImage of(StrategyData strategy) =>
      _steps(strategy).whereType<StrategyImage>().single;

  Future<StrategyImage> between(
    StrategyData strategy,
    Future<void> Function() breathe,
  ) async {
    for (final step in _steps(strategy)) {
      if (step != null) return step;
      await breathe();
    }
    throw StateError('the image ended without an outcome');
  }

  void forget(String strategyId) => _partsReadingBackEqual.remove(strategyId);

  Iterable<StrategyImage?> _steps(StrategyData strategy) sync* {
    final map = strategy.mapData;
    final parts = <_Part>[];
    Object? unkeyable;
    late final String outline;
    late final StrategyToRows converted;
    for (final step in strategyToRowsInSteps(strategy)) {
      try {
        switch (step) {
          case ItemConverted(:final page, :final item, row: final row?):
            parts.add(_ItemPart(map, page, item, row));
          case ItemConverted(row: null):
            break;
          case PageConverted(:final page, :final lineupGroups):
            parts.add(_PagePart(map, page, lineupGroups));
          case RowsFinished(:final rows):
            converted = rows;
            outline = strategyOutline(strategy);
        }
      } on Object catch (error) {
        unkeyable ??= error;
      }
      yield null;
    }

    final StrategyRowSet rows;
    switch (converted) {
      case StrategyRowsRefused():
        forget(strategy.id);
        yield StrategyImage(
          converted,
          const ReadsBackDifferently('the converter refuses it'),
        );
        return;
      case StrategyRowsMade(rows: final made):
        rows = made;
    }
    StrategyImage cannotCompare(Object error) {
      forget(strategy.id);
      return StrategyImage(
          converted, ReadsBackDifferently('it cannot be compared: $error'));
    }

    if (unkeyable != null) {
      yield cannotCompare(unkeyable);
      return;
    }

    final bool outlineEqual;
    try {
      outlineEqual = outlineReadsBack(outline, rows);
    } on Object catch (error) {
      yield cannotCompare(error);
      return;
    }
    yield null;

    final known = _partsReadingBackEqual[strategy.id] ?? const <String>{};
    final equal = <String>{};
    String? differingPage;
    var partsReadBack = 0;
    for (final part in parts) {
      if (known.contains(part.key)) {
        equal.add(part.key);
        continue;
      }
      try {
        partsReadBack += 1;
        if (part.readBack(rows) == part.key) {
          equal.add(part.key);
        } else {
          differingPage ??= part.pageId;
        }
      } on Object catch (error) {
        yield cannotCompare(error);
        return;
      }
      yield null;
    }

    _partsReadingBackEqual[strategy.id] = equal;

    if (!outlineEqual) {
      yield StrategyImage(
        converted,
        const ReadsBackDifferently(
          'its fields, page order or positions read back differently',
        ),
        partsReadBack: partsReadBack,
      );
      return;
    }
    if (differingPage == null) {
      yield StrategyImage(
        converted,
        const ReadsBackEqual(),
        partsReadBack: partsReadBack,
      );
      return;
    }
    yield null;
    try {
      yield StrategyImage(
        converted,
        _pageDifferences(strategy, rows, differingPage),
        partsReadBack: partsReadBack,
      );
    } on Object catch (error) {
      yield cannotCompare(error);
    }
  }
}

sealed class _Part {
  _Part(this.pageId, this.key);

  final String pageId;
  final String key;

  String? readBack(StrategyRowSet rows);
}

final class _ItemPart extends _Part {
  _ItemPart(this.map, StrategyPage page, PageItem item, this.row)
      : super(page.id, itemKey(map, item));

  final MapValue map;
  final LiveElement row;

  @override
  String? readBack(StrategyRowSet rows) => switch (_stored(
        row,
        (json) => ElementRow.decode(json, canRead: appCanRead.element),
      )) {
        LiveElement(:final payload) => switch (PageItem.decode(payload, map)) {
            Read(value: final back) => itemKey(map, back),
            CouldNotRead() => null,
          },
        UnreadableElement() || DeletedElement() => null,
      };
}

final class _PagePart extends _Part {
  _PagePart(this.map, StrategyPage page, this.lineupGroups)
      : super(page.id, pagePartKey(map, page));

  final MapValue map;
  final List<LiveLineupGroup> lineupGroups;

  @override
  String? readBack(StrategyRowSet rows) =>
      switch (strategyFromRows(rowsAsStored(StrategyRowSet(
        strategy: rows.strategy,
        pages: [if (rows.page(pageId) case final page?) page],
        settings: [if (rows.settingsOf(pageId) case final settings?) settings],
        lineupGroups: lineupGroups,
      )))) {
        StrategyDataMade(
          strategy: final back,
          :final unreadable,
          :final notInStrategy,
        )
            when unreadable.isEmpty &&
                notInStrategy.isEmpty &&
                back.pages.length == 1 =>
          pagePartKey(map, back.pages.single),
        StrategyDataMade() || StrategyDataRefused() => null,
      };
}

ReadBack _pageDifferences(
  StrategyData strategy,
  StrategyRowSet rows,
  String pageId,
) {
  final page = strategy.pages.firstWhere((page) => page.id == pageId);
  final back = strategyFromRows(rowsAsStored(StrategyRowSet(
    strategy: rows.strategy,
    pages: [if (rows.page(pageId) case final row?) row],
    settings: [if (rows.settingsOf(pageId) case final settings?) settings],
    elements: rows.elementsOn(pageId),
    lineupGroups: rows.lineupGroupsOn(pageId),
  )));
  final differences = switch (back) {
    StrategyDataMade(strategy: final made) when made.pages.length == 1 =>
      strategyDifferences(strategy.copyWith(pages: [page]), made),
    _ => const <StrategyDifference>[],
  };
  if (differences.isEmpty) {
    return ReadsBackDifferently('page $pageId reads back differently');
  }
  return ReadsBackDifferently([
    ...differences.take(3).map((difference) => '$difference'),
    if (differences.length > 3) '${differences.length - 3} more',
  ].join(', '));
}

String itemKey(MapValue map, PageItem item) => [
      jsonEncode(Maps.mapNames[map]),
      item.kind.name,
      jsonEncode(item.data),
    ].join('\n');

String pagePartKey(MapValue map, StrategyPage page) => [
      jsonEncode(Maps.mapNames[map]),
      jsonEncode(page.id),
      jsonEncode(page.sortIndex),
      jsonEncode(page.name),
      jsonEncode(page.isAutoNamed),
      jsonEncode(page.isAttack),
      StrategySettingsProvider.objectToJson(page.settings),
      jsonEncode(page.lineUpGraph.toJson()),
      jsonEncode(lineupPictureFileNames(page)..sort()),
    ].join('\n');

String strategyOutline(StrategyData strategy) => jsonEncode([
      strategyFieldsFingerprint(strategy),
      [
        for (final page in strategy.pages) [page.id, page.sortIndex],
      ],
    ]);

bool outlineReadsBack(String outline, StrategyRowSet rows) =>
    _everyRowOnAPage(rows) &&
    switch (strategyFromRows(rowsAsStored(StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
    )))) {
      StrategyDataMade(
        strategy: final back,
        :final unreadable,
        :final notInStrategy,
      )
          when unreadable.isEmpty && notInStrategy.isEmpty =>
        strategyOutline(back) == outline,
      StrategyDataMade() || StrategyDataRefused() => false,
    };

bool _everyRowOnAPage(StrategyRowSet rows) => [
      for (final row in rows.elements) row.pagePublicId,
      for (final row in rows.lineupGroups) row.pagePublicId,
    ].every((pageId) => rows.page(pageId) != null);

StrategyRowSet rowsAsStored(StrategyRowSet rows) => StrategyRowSet(
      strategy: _stored(rows.strategy, StrategyRow.decode),
      pages: [for (final row in rows.pages) _stored(row, PageRow.decode)],
      settings: [
        for (final row in rows.settings) _stored(row, PageSettingsRow.decode),
      ],
      elements: [
        for (final row in rows.elements)
          _stored(
            row,
            (json) => ElementRow.decode(json, canRead: appCanRead.element),
          ),
      ],
      lineupGroups: [
        for (final row in rows.lineupGroups)
          _stored(
            row,
            (json) => LineupGroupRow.decode(
              json,
              canRead: appCanRead.lineupGroup,
            ),
          ),
      ],
    );

R _stored<R extends Row>(Row row, Decoded<R> Function(Object? json) decode) =>
    switch (encodeJson(row.toJsonView())) {
      Encoded(:final text) => switch (admit(text)) {
          Admitted(:final json) => switch (decode(json)) {
              Read(:final value) => value,
              CouldNotRead(:final problem) => throw StateError(problem),
            },
          NotAdmitted(:final problem) => throw StateError(problem),
        },
      NotEncoded(:final problem) => throw StateError(problem),
    };
