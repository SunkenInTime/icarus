import '../outcome.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import 'layout.dart';
import 'results.dart';

const _nameTaken = 'another row holds the name of this id';

final class LoadedPage {
  final elements = <String, ElementRow>{};
  final lineupGroups = <String, LineupGroupRow>{};
  final unknownKinds = <UnknownKindRow>[];
  final foreignNames = <ForeignName>[];
}

final class LoadedStrategy {
  LoadedStrategy({
    required this.header,
    required Map<String, PageRow> pages,
    required Map<String, PageSettingsRow> settings,
    required Iterable<StoreName> names,
  }) {
    _pages.addAll(pages);
    _settings.addAll(settings);
    for (final name in names) {
      switch (name) {
        case ElementName(:final page, :final digest):
          _elementPages[digest] = page;
        case LineupName(:final page, :final digest):
          _lineupPages[digest] = page;
        case final ForeignName name:
          foreignNames.add(name);
        case _:
          break;
      }
    }
  }

  StrategyRow header;
  final foreignNames = <ForeignName>[];
  final _pages = <String, PageRow>{};
  final _settings = <String, PageSettingsRow>{};
  final _elementPages = <String, String>{};
  final _lineupPages = <String, String>{};
  final _loaded = <String, LoadedPage>{};

  Iterable<PageRow> get pages => _pages.values;

  Iterable<PageSettingsRow> get allSettings => _settings.values;

  Map<String, PageSettingsRow> get settingsByPage => {
    for (final row in _settings.values) row.pagePublicId: row,
  };

  PageRow? page(String pagePublicId) =>
      switch (_pages[digestOf(pagePublicId)]) {
        final ReadablePageRow row when row.publicId != pagePublicId =>
          UnreadablePage(
            publicId: pagePublicId,
            strategyPublicId: row.strategyPublicId,
            sortIndex: null,
            trashed: null,
            stored: row.toJson(),
            problem: _nameTaken,
          ),
        final row => row,
      };

  PageSettingsRow? settingsOf(String pagePublicId) =>
      switch (_settings[digestOf(pagePublicId)]) {
        final ReadablePageSettings row when row.pagePublicId != pagePublicId =>
          UnreadablePageSettings(
            pagePublicId: pagePublicId,
            stored: row.toJson(),
            problem: _nameTaken,
          ),
        final row => row,
      };

  String pageIdOf(String pageDigest) => switch (_pages[pageDigest]) {
    final row? => row.publicId,
    null => pageContentPrefix(pageDigest),
  };

  LoadedPage? loadedPage(String pageDigest) => _loaded[pageDigest];

  bool isLoaded(String pageDigest) => _loaded.containsKey(pageDigest);

  void addLoadedPage(String pageDigest, LoadedPage page) =>
      _loaded[pageDigest] = page;

  Set<String> get pageDigests => {
    ..._pages.keys,
    ..._elementPages.values,
    ..._lineupPages.values,
  };

  String? pageOfElement(String elementPublicId) =>
      _elementPages[digestOf(elementPublicId)];

  String? pageOfLineupGroup(String lineupPublicId) =>
      _lineupPages[digestOf(lineupPublicId)];

  LoadedPage _mustBeLoaded(String pageDigest) =>
      _loaded[pageDigest] ??
      (throw StateError('page $pageDigest was not loaded before applying'));

  ElementRow? element(String elementPublicId) {
    final digest = digestOf(elementPublicId);
    return switch (_elementPages[digest]) {
      null => null,
      final page => switch (_mustBeLoaded(page).elements[digest]) {
        final ReadableElementRow row when row.publicId != elementPublicId =>
          UnreadableElement(
            publicId: elementPublicId,
            pagePublicId: row.pagePublicId,
            stored: row.toJson(),
            problem: _nameTaken,
          ),
        final row => row,
      },
    };
  }

  LineupGroupRow? lineupGroup(String lineupPublicId) {
    final digest = digestOf(lineupPublicId);
    return switch (_lineupPages[digest]) {
      null => null,
      final page => switch (_mustBeLoaded(page).lineupGroups[digest]) {
        final ReadableLineupGroupRow row when row.publicId != lineupPublicId =>
          UnreadableLineupGroup(
            publicId: lineupPublicId,
            strategyPublicId: row.strategyPublicId,
            pagePublicId: row.pagePublicId,
            stored: row.toJson(),
            problem: _nameTaken,
          ),
        final row => row,
      },
    };
  }

  Iterable<ElementRow> elementsOnPage(String pageDigest) =>
      _mustBeLoaded(pageDigest).elements.values;

  Iterable<LineupGroupRow> lineupGroupsOnPage(String pageDigest) =>
      _mustBeLoaded(pageDigest).lineupGroups.values;

  StrategyRows rowsUnder(ReadableStrategy strategy) =>
      _LoadedRows(this, strategy);

  Row? current(Row row) => switch (nameOf(row)) {
    HeaderName() => header,
    PageName(:final digest) => _pages[digest],
    SettingsName(:final digest) => _settings[digest],
    ElementName(:final page, :final digest) => _loaded[page]?.elements[digest],
    LineupName(:final page, :final digest) =>
      _loaded[page]?.lineupGroups[digest],
    _ => null,
  };

  (ReadableStrategy, List<PageRow>, List<PageSettingsRow>) after(
    ReadableStrategy strategy,
    Iterable<RowWrite> writes,
  ) {
    var header = strategy;
    final pages = {..._pages};
    final settings = {..._settings};
    for (final write in writes) {
      switch (write.after) {
        case final ReadableStrategy row:
          header = row;
        case final PageRow row:
          pages[digestOf(row.publicId)] = row;
        case final PageSettingsRow row:
          settings[digestOf(row.pagePublicId)] = row;
        case _:
          break;
      }
    }
    return (header, pages.values.toList(), settings.values.toList());
  }

  void take(Iterable<RowWrite> writes) {
    for (final write in writes) {
      if (write case RowChanged(
        :final before,
      ) when nameOf(before).name != nameOf(write.after).name) {
        _forget(before);
      }
      _keep(write.after);
    }
  }

  void _forget(Row row) {
    switch (row) {
      case ElementRow(:final pagePublicId, :final publicId):
        _loaded[digestOf(pagePublicId)]?.elements.remove(digestOf(publicId));
        _elementPages.remove(digestOf(publicId));
      case LineupGroupRow(:final pagePublicId, :final publicId):
        _loaded[digestOf(pagePublicId)]?.lineupGroups.remove(
          digestOf(publicId),
        );
        _lineupPages.remove(digestOf(publicId));
      case StrategyRow() || FolderRow() || PageRow() || PageSettingsRow():
        throw StateError('$row does not change name');
    }
  }

  void _keep(Row row) {
    switch (row) {
      case StrategyRow():
        header = row;
      case PageRow(:final publicId):
        _pages[digestOf(publicId)] = row;
      case PageSettingsRow(:final pagePublicId):
        _settings[digestOf(pagePublicId)] = row;
      case ElementRow(:final pagePublicId, :final publicId):
        final page = digestOf(pagePublicId);
        _mustBeLoaded(page).elements[digestOf(publicId)] = row;
        _elementPages[digestOf(publicId)] = page;
      case LineupGroupRow(:final pagePublicId, :final publicId):
        final page = digestOf(pagePublicId);
        _mustBeLoaded(page).lineupGroups[digestOf(publicId)] = row;
        _lineupPages[digestOf(publicId)] = page;
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
      _loaded.elementsOnPage(digestOf(pagePublicId));

  @override
  Iterable<LineupGroupRow> lineupGroupsOn(String pagePublicId) =>
      _loaded.lineupGroupsOnPage(digestOf(pagePublicId));
}
