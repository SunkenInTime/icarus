import '../outcome.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import 'layout.dart';
import 'results.dart';

final class LoadedPage {
  final elements = <String, ElementRow>{};
  final lineupGroups = <String, LineupGroupRow>{};
  final unknownKinds = <UnknownKindRow>[];
  final foreignKeys = <ForeignKey>[];
}

final class LoadedStrategy {
  LoadedStrategy({
    required this.header,
    required Iterable<PageRow> pages,
    required Iterable<PageSettingsRow> settings,
    required Iterable<StrategyAreaKey> keys,
  }) {
    for (final page in pages) {
      _pages[page.publicId] = page;
    }
    for (final row in settings) {
      _settings[row.pagePublicId] = row;
    }
    for (final key in keys) {
      switch (key) {
        case ElementAt(:final publicId, :final pagePublicId):
          _elementPages[publicId] = pagePublicId;
        case LineupAt(:final publicId, :final pagePublicId):
          _lineupPages[publicId] = pagePublicId;
        case ForeignKey():
          foreignKeys.add(key);
        case HeaderAt() || PageAt() || SettingsAt() || UnknownKindAt():
          break;
      }
    }
  }

  StrategyRow header;
  final foreignKeys = <ForeignKey>[];
  final _pages = <String, PageRow>{};
  final _settings = <String, PageSettingsRow>{};
  final _elementPages = <String, String>{};
  final _lineupPages = <String, String>{};
  final _loaded = <String, LoadedPage>{};

  Iterable<PageRow> get pages => _pages.values;

  Map<String, PageSettingsRow> get settings => _settings;

  PageRow? page(String pagePublicId) => _pages[pagePublicId];

  PageSettingsRow? settingsOf(String pagePublicId) => _settings[pagePublicId];

  LoadedPage? loadedPage(String pagePublicId) => _loaded[pagePublicId];

  bool isLoaded(String pagePublicId) => _loaded.containsKey(pagePublicId);

  void addLoadedPage(String pagePublicId, LoadedPage page) =>
      _loaded[pagePublicId] = page;

  Set<String> get pageIds => {
    ..._pages.keys,
    ..._elementPages.values,
    ..._lineupPages.values,
  };

  String? pageOfElement(String elementPublicId) =>
      _elementPages[elementPublicId];

  String? pageOfLineupGroup(String lineupPublicId) =>
      _lineupPages[lineupPublicId];

  LoadedPage _mustBeLoaded(String pagePublicId) =>
      _loaded[pagePublicId] ??
      (throw StateError('page $pagePublicId was not loaded before applying'));

  ElementRow? element(String elementPublicId) =>
      switch (_elementPages[elementPublicId]) {
        null => null,
        final page => _mustBeLoaded(page).elements[elementPublicId],
      };

  LineupGroupRow? lineupGroup(String lineupPublicId) =>
      switch (_lineupPages[lineupPublicId]) {
        null => null,
        final page => _mustBeLoaded(page).lineupGroups[lineupPublicId],
      };

  Iterable<ElementRow> elementsOn(String pagePublicId) =>
      _mustBeLoaded(pagePublicId).elements.values;

  Iterable<LineupGroupRow> lineupGroupsOn(String pagePublicId) =>
      _mustBeLoaded(pagePublicId).lineupGroups.values;

  StrategyRows rowsUnder(ReadableStrategy strategy) =>
      _LoadedRows(this, strategy);

  Row? current(Row row) => switch (row) {
    StrategyRow() => header,
    FolderRow() => null,
    PageRow(:final publicId) => _pages[publicId],
    PageSettingsRow(:final pagePublicId) => _settings[pagePublicId],
    ElementRow(:final pagePublicId, :final publicId) =>
      _loaded[pagePublicId]?.elements[publicId],
    LineupGroupRow(:final pagePublicId, :final publicId) =>
      _loaded[pagePublicId]?.lineupGroups[publicId],
  };

  (ReadableStrategy, List<PageRow>) headerAfter(
    ReadableStrategy strategy,
    Iterable<RowWrite> writes,
  ) {
    var header = strategy;
    final pages = {..._pages};
    for (final write in writes) {
      switch (write.after) {
        case final ReadableStrategy row:
          header = row;
        case final PageRow row:
          pages[row.publicId] = row;
        case _:
          break;
      }
    }
    return (header, pages.values.toList());
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
        _loaded[pagePublicId]?.elements.remove(publicId);
        _elementPages.remove(publicId);
      case LineupGroupRow(:final pagePublicId, :final publicId):
        _loaded[pagePublicId]?.lineupGroups.remove(publicId);
        _lineupPages.remove(publicId);
      case StrategyRow() || FolderRow() || PageRow() || PageSettingsRow():
        throw StateError('$row does not change key');
    }
  }

  void _keep(Row row) {
    switch (row) {
      case StrategyRow():
        header = row;
      case PageRow(:final publicId):
        _pages[publicId] = row;
      case PageSettingsRow(:final pagePublicId):
        _settings[pagePublicId] = row;
      case ElementRow(:final pagePublicId, :final publicId):
        _mustBeLoaded(pagePublicId).elements[publicId] = row;
        _elementPages[publicId] = pagePublicId;
      case LineupGroupRow(:final pagePublicId, :final publicId):
        _mustBeLoaded(pagePublicId).lineupGroups[publicId] = row;
        _lineupPages[publicId] = pagePublicId;
      case FolderRow():
        throw StateError('$row is not written as a row of a strategy');
    }
  }
}

final class _LoadedRows implements StrategyRows {
  _LoadedRows(this._loaded, this.strategy);

  final LoadedStrategy _loaded;

  @override
  final ReadableStrategy strategy;

  @override
  Iterable<PageRow> get pages => _loaded.pages;

  @override
  PageRow? page(String pagePublicId) => _loaded.page(pagePublicId);

  @override
  PageSettingsRow? settingsOf(String pagePublicId) =>
      _loaded.settingsOf(pagePublicId);

  @override
  ElementRow? element(String elementPublicId) =>
      _loaded.element(elementPublicId);

  @override
  LineupGroupRow? lineupGroup(String lineupPublicId) =>
      _loaded.lineupGroup(lineupPublicId);

  @override
  Iterable<ElementRow> elementsOn(String pagePublicId) =>
      _loaded.elementsOn(pagePublicId);

  @override
  Iterable<LineupGroupRow> lineupGroupsOn(String pagePublicId) =>
      _loaded.lineupGroupsOn(pagePublicId);
}
