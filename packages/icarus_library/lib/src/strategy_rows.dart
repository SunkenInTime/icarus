import 'package:collection/collection.dart';

import 'rows.dart';

abstract interface class StrategyRows {
  ReadableStrategy get strategy;

  Iterable<PageRow> get pages;

  PageRow? page(String pagePublicId);

  PageSettingsRow? settingsOf(String pagePublicId);

  ElementRow? element(String elementPublicId);

  LineupGroupRow? lineupGroup(String lineupPublicId);

  Iterable<ElementRow> elementsOn(String pagePublicId);

  Iterable<LineupGroupRow> lineupGroupsOn(String pagePublicId);
}

final class StrategyRowSet implements StrategyRows {
  StrategyRowSet({
    required this.strategy,
    Iterable<PageRow> pages = const [],
    Iterable<PageSettingsRow> settings = const [],
    Iterable<ElementRow> elements = const [],
    Iterable<LineupGroupRow> lineupGroups = const [],
  }) : _pages = Map.unmodifiable({for (final row in pages) row.publicId: row}),
       _settings = Map.unmodifiable({
         for (final row in settings) row.pagePublicId: row,
       }),
       _elements = Map.unmodifiable({
         for (final row in elements) row.publicId: row,
       }),
       _lineupGroups = Map.unmodifiable({
         for (final row in lineupGroups) row.publicId: row,
       });

  @override
  final ReadableStrategy strategy;
  final Map<String, PageRow> _pages;
  final Map<String, PageSettingsRow> _settings;
  final Map<String, ElementRow> _elements;
  final Map<String, LineupGroupRow> _lineupGroups;

  @override
  Iterable<PageRow> get pages => _pages.values;

  Iterable<PageSettingsRow> get settings => _settings.values;

  Iterable<ElementRow> get elements => _elements.values;

  Iterable<LineupGroupRow> get lineupGroups => _lineupGroups.values;

  Iterable<Row> get rows => [
    strategy,
    ...pages,
    ...settings,
    ...elements,
    ...lineupGroups,
  ];

  @override
  PageRow? page(String pagePublicId) => _pages[pagePublicId];

  @override
  PageSettingsRow? settingsOf(String pagePublicId) => _settings[pagePublicId];

  @override
  ElementRow? element(String elementPublicId) => _elements[elementPublicId];

  @override
  LineupGroupRow? lineupGroup(String lineupPublicId) =>
      _lineupGroups[lineupPublicId];

  @override
  Iterable<ElementRow> elementsOn(String pagePublicId) =>
      elements.where((row) => row.pagePublicId == pagePublicId);

  @override
  Iterable<LineupGroupRow> lineupGroupsOn(String pagePublicId) =>
      lineupGroups.where((row) => row.pagePublicId == pagePublicId);

  StrategyRowSet withRows(Iterable<Row> written) {
    var strategy = this.strategy;
    final pages = {..._pages};
    final settings = {..._settings};
    final elements = {..._elements};
    final lineupGroups = {..._lineupGroups};
    for (final row in written) {
      switch (row) {
        case UnreadableStrategy():
          throw ArgumentError.value(
            row,
            'written',
            'an unreadable strategy row cannot be written',
          );
        case ReadableStrategy():
          if (row.publicId != strategy.publicId) {
            throw ArgumentError.value(
              row.publicId,
              'written',
              'other strategy',
            );
          }
          strategy = row;
        case FolderRow():
          throw ArgumentError.value(
            row,
            'written',
            'a folder is not a row of a strategy',
          );
        case PageRow():
          pages[row.publicId] = row;
        case PageSettingsRow():
          settings[row.pagePublicId] = row;
        case ElementRow():
          elements[row.publicId] = row;
        case LineupGroupRow():
          lineupGroups[row.publicId] = row;
      }
    }
    return StrategyRowSet(
      strategy: strategy,
      pages: pages.values,
      settings: settings.values,
      elements: elements.values,
      lineupGroups: lineupGroups.values,
    );
  }

  static const _rowsEqual = MapEquality<String, Row>();

  @override
  bool operator ==(Object other) =>
      other is StrategyRowSet &&
      other.strategy == strategy &&
      _rowsEqual.equals(other._pages, _pages) &&
      _rowsEqual.equals(other._settings, _settings) &&
      _rowsEqual.equals(other._elements, _elements) &&
      _rowsEqual.equals(other._lineupGroups, _lineupGroups);

  @override
  int get hashCode => Object.hash(
    strategy,
    _rowsEqual.hash(_pages),
    _rowsEqual.hash(_settings),
    _rowsEqual.hash(_elements),
    _rowsEqual.hash(_lineupGroups),
  );
}
