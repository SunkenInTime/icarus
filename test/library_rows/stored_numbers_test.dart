import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import 'generated_strategies.dart';

StrategyRowSet _rows(
  StrategyData strategy, [
  Map<String, int> storedNumbers = const {},
]) =>
    switch (strategyToRows(strategy, storedNumbers: storedNumbers)) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

StrategyData _back(StrategyRowSet rows) => switch (strategyFromRows(rows)) {
      StrategyDataMade(:final strategy) => strategy,
      StrategyDataRefused(:final problems) => fail('$problems'),
    };

Map<String, int> _numbers(StrategyRowSet rows) => {
      for (final row in rows.elements.cast<LiveElement>())
        row.publicId: row.sortIndex,
    };

List<String> _drawingIdsBack(StrategyRowSet rows) =>
    [for (final drawing in _back(rows).pages.first.drawingData) drawing.id];

List<String> _drawingIds(StrategyData strategy) =>
    [for (final drawing in strategy.pages.first.drawingData) drawing.id];

Map<String, int> _drawingNumbers(StrategyRowSet rows, StrategyPage page) {
  final ids = {for (final drawing in page.drawingData) drawing.id};
  return {
    for (final MapEntry(:key, :value) in _numbers(rows).entries)
      if (ids.contains(key)) key: value,
  };
}

StrategyData _withDrawings(
  StrategyData strategy,
  List<DrawingElement> Function(List<DrawingElement> drawings) change,
) {
  final page = strategy.pages.first;
  return strategy.copyWith(pages: [
    page.copyWith(drawingData: change([...page.drawingData])),
    ...strategy.pages.skip(1),
  ]);
}

DrawingElement _copyWithId(DrawingElement drawing, String id) =>
    switch (drawing) {
      final Line line => line.copyWith(id: id),
      final FreeDrawing free => free.copyWith(id: id),
      _ => fail('a drawing of kind ${drawing.runtimeType}'),
    };

void main() {
  final strategy = generatedStrategy(Optionals.set);
  final page = strategy.pages.first;

  setUpAll(() => expect(page.drawingData.length, greaterThanOrEqualTo(3)));

  test(
      'removing the first drawing keeps every other item\'s stored number, '
      'and the strategy reads back in the same order', () {
    final stored = _rows(strategy);
    final removed = _withDrawings(strategy, (d) => d..removeAt(0));

    final rows = _rows(removed, _numbers(stored));

    final kept = _numbers(rows);
    for (final MapEntry(:key, :value) in kept.entries) {
      expect(value, _numbers(stored)[key], reason: key);
    }
    expect(_drawingIdsBack(rows), _drawingIds(removed));
    expect(strategyDifferences(_back(rows), _back(_rows(removed))), isEmpty);
  });

  test('an added drawing takes the number after the last, and no other moves',
      () {
    final stored = _rows(strategy);
    final added = _withDrawings(
      strategy,
      (d) => d..add(_copyWithId(d.first, 'added-drawing')),
    );

    final rows = _rows(added, _numbers(stored));

    final before = _drawingNumbers(stored, page);
    final after = _numbers(rows);
    for (final MapEntry(:key, :value) in before.entries) {
      expect(after[key], value, reason: key);
    }
    expect(after['added-drawing'], before.values.reduce((a, b) => a > b ? a : b) + 1);
    expect(_drawingIdsBack(rows), _drawingIds(added));
    expect(strategyDifferences(_back(rows), _back(_rows(added))), isEmpty);
  });

  test('a drawing raised to the top takes the number after the last', () {
    final stored = _rows(strategy);
    final first = page.drawingData.first;
    final raised = _withDrawings(strategy, (d) => d..removeAt(0)..add(first));

    final rows = _rows(raised, _numbers(stored));

    final before = _drawingNumbers(stored, page);
    final after = _numbers(rows);
    for (final drawing in page.drawingData.skip(1)) {
      expect(after[drawing.id], before[drawing.id], reason: drawing.id);
    }
    expect(after[first.id], before.values.reduce((a, b) => a > b ? a : b) + 1);
    expect(_drawingIdsBack(rows), _drawingIds(raised));
    expect(strategyDifferences(_back(rows), _back(_rows(raised))), isEmpty);
  });

  test(
      'an item put before others whose numbers it would pass renumbers those '
      'after it, so the order is still the one asked for', () {
    final stored = _rows(strategy);
    final last = page.drawingData.last;
    final lowered = _withDrawings(
      strategy,
      (d) => d
        ..removeLast()
        ..insert(0, last),
    );

    final rows = _rows(lowered, _numbers(stored));

    expect(_drawingIdsBack(rows), _drawingIds(lowered));
    expect(strategyDifferences(_back(rows), _back(_rows(lowered))), isEmpty);
  });

  test('with no stored numbers the rows are what they were before', () {
    final rows = _rows(strategy);

    for (final items in pageItemsByKind(page)) {
      final numbers = [
        for (final item in items) _numbers(rows)[item.id],
      ];
      expect(numbers, [for (var i = 0; i < items.length; i++) i]);
    }
  });
}
