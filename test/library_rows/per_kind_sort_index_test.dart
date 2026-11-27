import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import 'generated_strategies.dart';

StrategyRowSet _rows(StrategyData strategy) =>
    switch (strategyToRows(strategy)) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

StrategyData _back(StrategyRowSet rows) => switch (strategyFromRows(rows)) {
      StrategyDataMade(:final strategy) => strategy,
      StrategyDataRefused(:final problems) => fail('$problems'),
    };

List<LiveElement> _elementsOn(StrategyRowSet rows, String pageId) =>
    rows.elementsOn(pageId).cast<LiveElement>().toList();

StrategyRowSet _renumbered(
  StrategyRowSet rows,
  int Function(int pageWide) number,
) {
  final pageWide = <String, int>{};
  for (final page in rows.pages) {
    final kindOrdered = _elementsOn(rows, page.publicId)
      ..sort((a, b) =>
          switch (a.payload.kind.index.compareTo(b.payload.kind.index)) {
            0 => a.sortIndex.compareTo(b.sortIndex),
            final byKind => byKind,
          });
    for (final (index, row) in kindOrdered.indexed) {
      pageWide[row.publicId] = index;
    }
  }
  return rows.withRows([
    for (final row in rows.elements.cast<LiveElement>())
      LiveElement(
        publicId: row.publicId,
        pagePublicId: row.pagePublicId,
        payload: row.payload,
        sortIndex: number(pageWide[row.publicId]!),
        revision: row.revision,
      ),
  ]);
}

PlacedText _text(String id) =>
    PlacedText(id: id, position: const Offset(300, 300))..text = id;

String _rowIdOf(StrategyRowSet rows, String pageId, String itemId) =>
    _elementsOn(rows, pageId)
        .singleWhere((row) => row.payload.data['id'] == itemId)
        .publicId;

void main() {
  final strategy = generatedStrategy(Optionals.set);

  test('each element is numbered by its place in its own kind', () {
    final rows = _rows(strategy);
    for (final page in strategy.pages) {
      for (final kind in ElementKind.values) {
        expect(
          [
            for (final row in _elementsOn(rows, page.id))
              if (row.payload.kind == kind) row.sortIndex,
          ]..sort(),
          [
            for (var index = 0;
                index <
                    _elementsOn(rows, page.id)
                        .where((row) => row.payload.kind == kind)
                        .length;
                index++)
              index,
          ],
          reason: '${page.id} ${kind.name}',
        );
      }
    }
  });

  test(
      'a page numbered page-wide, as stores written before this numbering '
      'and cloud pages are, reads as the same strategy as one numbered per '
      'kind', () {
    final perKind = _back(_rows(strategy));
    for (final (name, number) in <(String, int Function(int))>[
      ('page-wide from 0', (index) => index),
      (
        'page-wide with gaps, as appended at the highest plus one',
        (index) => index * 7 + 3
      ),
    ]) {
      expect(
        strategyDifferences(
            perKind, _back(_renumbered(_rows(strategy), number))),
        isEmpty,
        reason: name,
      );
    }
  });

  group('an item whose id another item already holds', () {
    late StrategyData duplicated;
    late String secondPage;

    setUp(() {
      duplicated = generatedStrategy(Optionals.set);
      secondPage = duplicated.pages[1].id;
      duplicated.pages[0].textData.add(_text('shared'));
      duplicated.pages[1].textData
        ..add(_text('earlier'))
        ..add(_text('shared'));
    });

    test('keeps its row id when an item of another kind is added before it',
        () {
      final before = _rowIdOf(_rows(duplicated), secondPage, 'shared');
      expect(before, isNot('shared'));

      duplicated.pages[1].agentData.insert(
        0,
        PlacedAgent(
          id: 'added-first',
          type: AgentType.jett,
          position: const Offset(10, 10),
          isAlly: true,
        ),
      );

      expect(_rowIdOf(_rows(duplicated), secondPage, 'shared'), before);
    });

    test(
        'gets another row id when an earlier item of its own kind is removed, '
        'since that id is derived from its place in its kind', () {
      final before = _rowIdOf(_rows(duplicated), secondPage, 'shared');

      duplicated.pages[1].textData.removeWhere((text) => text.id == 'earlier');

      final after = _rowIdOf(_rows(duplicated), secondPage, 'shared');
      expect(after, isNot(before));
      expect(after, isNot('shared'));
    });
  });
}
