import '../outcome.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import 'layout.dart';
import 'stored_row.dart';

final class LoadedPage {
  final elements = <String, ElementRow>{};
  final lineupGroups = <String, LineupGroupRow>{};
}

final class LoadedStrategy implements StrategyRows {
  LoadedStrategy({
    required this.strategy,
    required Iterable<PageRow> pages,
    required Iterable<PageSettingsRow> settings,
    required Iterable<UnreadableRow> unreadable,
    required Iterable<ContentKey> contentKeys,
  }) {
    for (final page in pages) {
      _pages[page.publicId] = page;
    }
    for (final row in settings) {
      _settings[row.pagePublicId] = row;
    }
    for (final row in unreadable) {
      this.unreadable[row.key] = row;
    }
    for (final key in contentKeys) {
      switch (key) {
        case ElementContentKey(:final idSegment, :final pageSegment):
          _elementPages[idSegment] = pageSegment;
        case LineupContentKey(:final idSegment, :final pageSegment):
          _lineupPages[idSegment] = pageSegment;
        case OtherContentKey():
          break;
      }
    }
  }

  @override
  StrategyRow strategy;
  final _pages = <String, PageRow>{};
  final _settings = <String, PageSettingsRow>{};
  final unreadable = <String, UnreadableRow>{};
  final _elementPages = <String, String>{};
  final _lineupPages = <String, String>{};
  final _loaded = <String, LoadedPage>{};

  String get publicId => strategy.publicId;

  @override
  Iterable<PageRow> get pages => _pages.values;

  Map<String, PageSettingsRow> get settings => _settings;

  @override
  PageRow? page(String pagePublicId) => _pages[pagePublicId];

  @override
  PageSettingsRow? settingsOf(String pagePublicId) => _settings[pagePublicId];

  LoadedPage? loadedPage(String pagePublicId) => _loaded[segment(pagePublicId)];

  bool isLoaded(String pageSegment) => _loaded.containsKey(pageSegment);

  void addLoadedPage(
    String pageSegment,
    LoadedPage page,
    Iterable<UnreadableRow> unreadable,
  ) {
    _loaded[pageSegment] = page;
    for (final row in unreadable) {
      this.unreadable[row.key] = row;
    }
  }

  Set<String> get pageSegments => {
    for (final page in _pages.keys) segment(page),
    ..._elementPages.values,
    ..._lineupPages.values,
  };

  String? pageOfElement(String elementPublicId) =>
      _elementPages[segment(elementPublicId)];

  String? pageOfLineupGroup(String lineupPublicId) =>
      _lineupPages[segment(lineupPublicId)];

  LoadedPage _mustBeLoaded(String pageSegment) =>
      _loaded[pageSegment] ??
      (throw StateError('page $pageSegment was not loaded before applying'));

  @override
  ElementRow? element(String elementPublicId) =>
      switch (_elementPages[segment(elementPublicId)]) {
        null => null,
        final page => _mustBeLoaded(page).elements[elementPublicId],
      };

  @override
  LineupGroupRow? lineupGroup(String lineupPublicId) =>
      switch (_lineupPages[segment(lineupPublicId)]) {
        null => null,
        final page => _mustBeLoaded(page).lineupGroups[lineupPublicId],
      };

  Iterable<ElementRow> elementsOnSegment(String pageSegment) =>
      _mustBeLoaded(pageSegment).elements.values;

  @override
  Iterable<ElementRow> elementsOn(String pagePublicId) =>
      _mustBeLoaded(segment(pagePublicId)).elements.values;

  @override
  Iterable<LineupGroupRow> lineupGroupsOn(String pagePublicId) =>
      _mustBeLoaded(segment(pagePublicId)).lineupGroups.values;

  (StrategyRow, List<PageRow>) headerAfter(Iterable<RowWrite> writes) {
    var strategy = this.strategy;
    final pages = {..._pages};
    for (final write in writes) {
      switch (write.after) {
        case final StrategyRow row:
          strategy = row;
        case final PageRow row:
          pages[row.publicId] = row;
        case _:
          break;
      }
    }
    return (strategy, pages.values.toList());
  }

  void take(Iterable<RowWrite> writes) {
    for (final write in writes) {
      if (write case RowChanged(
        :final before,
      ) when rowKey(before) != rowKey(write.after)) {
        _forget(before);
      }
      _keep(write.after);
    }
  }

  void _forget(Row row) {
    switch (row) {
      case ElementRow(:final pagePublicId, :final publicId):
        _loaded[segment(pagePublicId)]?.elements.remove(publicId);
        _elementPages.remove(segment(publicId));
      case LineupGroupRow(:final pagePublicId, :final publicId):
        _loaded[segment(pagePublicId)]?.lineupGroups.remove(publicId);
        _lineupPages.remove(segment(publicId));
      case StrategyRow() || FolderRow() || PageRow() || PageSettingsRow():
        throw StateError('$row does not change key');
    }
  }

  void _keep(Row row) {
    switch (row) {
      case StrategyRow():
        strategy = row;
      case PageRow(:final publicId):
        _pages[publicId] = row;
      case PageSettingsRow(:final pagePublicId):
        _settings[pagePublicId] = row;
      case ElementRow(:final pagePublicId, :final publicId):
        _mustBeLoaded(segment(pagePublicId)).elements[publicId] = row;
        _elementPages[segment(publicId)] = segment(pagePublicId);
      case LineupGroupRow(:final pagePublicId, :final publicId):
        _mustBeLoaded(segment(pagePublicId)).lineupGroups[publicId] = row;
        _lineupPages[segment(publicId)] = segment(pagePublicId);
      case FolderRow():
        throw StateError('a folder is not a row of a strategy');
    }
  }
}
