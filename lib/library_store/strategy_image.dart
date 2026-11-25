import 'dart:convert';

import 'package:icarus/const/line_provider.dart';
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
  const StrategyImage(this.rows, this.readBack);

  final StrategyToRows rows;
  final ReadBack readBack;
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
            parts.add(_ItemPart(map, strategy, page, item, row));
          case ItemConverted(row: null):
            break;
          case PageConverted(
              :final page,
              :final row,
              :final settings,
              :final lineupGroups,
            ):
            parts.add(
                _PagePart(map, strategy, page, row, settings, lineupGroups));
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
        yield StrategyImage(
          converted,
          const ReadsBackDifferently('the converter refuses it'),
        );
        return;
      case StrategyRowsMade(rows: final made):
        rows = made;
    }
    StrategyImage cannotCompare(Object error) => StrategyImage(
        converted, ReadsBackDifferently('it cannot be compared: $error'));
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
    _Part? differing;
    for (final part in parts) {
      if (known.contains(part.key)) {
        equal.add(part.key);
        continue;
      }
      try {
        if (part.readBack(rows) == part.key) {
          equal.add(part.key);
        } else {
          differing ??= part;
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
      );
      return;
    }
    if (differing == null) {
      yield StrategyImage(converted, const ReadsBackEqual());
      return;
    }
    yield null;
    try {
      yield StrategyImage(converted, differing.differences(rows));
    } on Object catch (error) {
      yield cannotCompare(error);
    }
  }
}

sealed class _Part {
  _Part(this.key);

  final String key;

  String? readBack(StrategyRowSet rows);

  ReadBack differences(StrategyRowSet rows);
}

final class _ItemPart extends _Part {
  _ItemPart(this.map, this.strategy, this.page, this.item, this.row)
      : super(itemKey(map, item));

  final MapValue map;
  final StrategyData strategy;
  final StrategyPage page;
  final PageItem item;
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

  @override
  ReadBack differences(StrategyRowSet rows) => _differences(
        strategy.copyWith(pages: [_pageHolding(page, item)]),
        _alone(rows, page.id, elements: [row]),
        'item ${item.id} on page ${page.id} reads back differently',
      );
}

final class _PagePart extends _Part {
  _PagePart(
    this.map,
    this.strategy,
    this.page,
    this.row,
    this.settings,
    this.lineupGroups,
  ) : super(pagePartKey(map, page));

  final MapValue map;
  final StrategyData strategy;
  final StrategyPage page;
  final LivePage row;
  final ReadablePageSettings settings;
  final List<LiveLineupGroup> lineupGroups;

  @override
  String? readBack(StrategyRowSet rows) => switch (strategyFromRows(
          rowsAsStored(_alone(rows, page.id, lineupGroups: lineupGroups)))) {
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

  @override
  ReadBack differences(StrategyRowSet rows) => _differences(
        strategy.copyWith(pages: [_pageHolding(page, null)]),
        _alone(rows, page.id, lineupGroups: lineupGroups),
        'page ${page.id} reads back differently',
      );
}

StrategyRowSet _alone(
  StrategyRowSet rows,
  String pageId, {
  List<ElementRow> elements = const [],
  List<LineupGroupRow> lineupGroups = const [],
}) =>
    StrategyRowSet(
      strategy: rows.strategy,
      pages: [if (rows.page(pageId) case final page?) page],
      settings: [if (rows.settingsOf(pageId) case final settings?) settings],
      elements: elements,
      lineupGroups: lineupGroups,
    );

StrategyPage _pageHolding(StrategyPage page, PageItem? item) => page.copyWith(
      agentData: [if (item case AgentItem(:final agent)) agent],
      abilityData: [if (item case AbilityItem(:final ability)) ability],
      drawingData: [if (item case DrawingItem(:final drawing)) drawing],
      textData: [if (item case TextItem(:final text)) text],
      imageData: [if (item case ImageItem(:final image)) image],
      utilityData: [if (item case UtilityItem(:final utility)) utility],
      lineUpGraph: item == null ? page.lineUpGraph : LineUpGraph.empty,
    );

ReadBack _differences(
  StrategyData original,
  StrategyRowSet rows,
  String otherwise,
) {
  final differences = switch (strategyFromRows(rowsAsStored(rows))) {
    StrategyDataMade(strategy: final made) when made.pages.length == 1 =>
      strategyDifferences(original, made),
    _ => const <StrategyDifference>[],
  };
  if (differences.isEmpty) return ReadsBackDifferently(otherwise);
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
