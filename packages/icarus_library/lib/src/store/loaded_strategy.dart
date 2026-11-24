import 'package:collection/collection.dart';

import '../outcome.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import 'layout.dart';
import 'results.dart';
import 'summary.dart';

sealed class Held {
  const Held();
}

final class HeldNothing extends Held {
  const HeldNothing();
}

final class HeldRow extends Held {
  const HeldRow(this.row);

  final Row row;
}

final class HeldUnplaced extends Held {
  const HeldUnplaced(this.row);

  final UnplacedRow row;
}

R? rowWithId<R extends Row>(
  Map<String, R> byDigest,
  String id,
  String Function(R row) idOf,
) => switch (byDigest[digestOf(id)]) {
  final row? when idOf(row) == id => row,
  _ => null,
};

enum Keeping { here, cloud }

final class LoadedPage {
  final elements = <String, ElementRow>{};
  final lineupGroups = <String, LineupGroupRow>{};
  final unknownKinds = <UnknownKindRow>[];
  final unplaced = <String, UnplacedRow>{};
  final foreignNames = <ForeignName>[];

  bool get isEmpty =>
      elements.isEmpty &&
      lineupGroups.isEmpty &&
      unknownKinds.isEmpty &&
      unplaced.isEmpty;

  int get rows => elements.length + lineupGroups.length;

  PageTally tally() => PageTally.count(
    elements: elements.values,
    lineupGroups: lineupGroups.values,
    damaged: unplaced.length,
    newer: unknownKinds.length,
  );
}

final class LoadedStrategy {
  LoadedStrategy({
    required this.digest,
    required this.header,
    required this.strategyId,
    required Map<String, PageRow> pages,
    required Map<String, PageSettingsRow> settings,
    required Map<String, UnplacedRow> unplaced,
    required Iterable<StoreName> names,
  }) {
    _pages.addAll(pages);
    _settings.addAll(settings);
    this.unplaced.addAll(unplaced);
    for (final name in names) {
      switch (name) {
        case ElementName(:final page, :final digest):
          (_elementPages[digest] ??= {}).add(page);
          _contentPages.add(page);
        case LineupName(:final page, :final digest):
          (_lineupPages[digest] ??= {}).add(page);
          _contentPages.add(page);
        case UnknownKindName(:final page):
          _contentPages.add(page);
        case final StoreName cloud when isCloudName(cloud):
          keeping = Keeping.cloud;
        case final ForeignName name:
          foreignNames.add(name);
        case _:
          break;
      }
    }
  }

  final String digest;
  Keeping keeping = Keeping.here;
  StrategyHeader header;

  static LoadedStrategy image(String digest, StrategyRowSet rows) {
    final loaded = LoadedStrategy(
      digest: digest,
      header: HeaderPlaced(rows.strategy),
      strategyId: rows.strategy.publicId,
      pages: {for (final page in rows.pages) digestOf(page.publicId): page},
      settings: {
        for (final row in rows.settings) digestOf(row.pagePublicId): row,
      },
      unplaced: const {},
      names: [
        for (final row in rows.elements) nameOf(row),
        for (final row in rows.lineupGroups) nameOf(row),
      ],
    );
    final content = {
      for (final page in rows.pages) digestOf(page.publicId): LoadedPage(),
    };
    for (final row in rows.elements) {
      content[digestOf(row.pagePublicId)]!.elements[digestOf(row.publicId)] =
          row;
    }
    for (final row in rows.lineupGroups) {
      content[digestOf(row.pagePublicId)]!.lineupGroups[digestOf(
            row.publicId,
          )] =
          row;
    }
    content.forEach(loaded.addLoadedPage);
    return loaded;
  }

  Map<RowKey, (String, Row)> get heldRows => {
    if (header case HeaderPlaced(:final row))
      row.key: (const HeaderName().name, row),
    for (final MapEntry(:key, :value) in _pages.entries)
      value.key: (PageName(key).name, value),
    for (final MapEntry(:key, :value) in _settings.entries)
      value.key: (SettingsName(key).name, value),
    for (final MapEntry(key: page, value: loaded) in _loaded.entries) ...{
      for (final MapEntry(:key, :value) in loaded.elements.entries)
        value.key: (ElementName(page, key).name, value),
      for (final MapEntry(:key, :value) in loaded.lineupGroups.entries)
        value.key: (LineupName(page, key).name, value),
    },
  };

  void drop(Iterable<Row> rows) {
    for (final row in rows) {
      switch (row) {
        case ElementRow() || LineupGroupRow():
          _forget(row);
        case PageRow(:final publicId):
          _pages.remove(digestOf(publicId));
          _loaded.remove(digestOf(publicId));
          _contentPages.remove(digestOf(publicId));
        case PageSettingsRow(:final pagePublicId):
          _settings.remove(digestOf(pagePublicId));
        case StrategyRow() || FolderRow():
          throw StateError('$row is not dropped from a strategy');
      }
    }
  }

  final String? strategyId;
  final unplaced = <String, UnplacedRow>{};
  final foreignNames = <ForeignName>[];
  final _pages = <String, PageRow>{};
  final _settings = <String, PageSettingsRow>{};
  final _elementPages = <String, Set<String>>{};
  final _lineupPages = <String, Set<String>>{};
  final _contentPages = <String>{};
  final _loaded = <String, LoadedPage>{};

  String get area => StrategyArea(digest).name;

  StoredRowRef refOf(String name) => StoredRowRef(area, name);

  Iterable<PageRow> get pages => _pages.values;

  Iterable<PageSettingsRow> get allSettings => _settings.values;

  Iterable<UnplacedRow> get unplacedPages => [
    for (final MapEntry(:key, :value) in unplaced.entries)
      if (key.startsWith('page/')) value,
  ];

  Map<String, PageSettingsRow> get settingsByPage => {
    for (final row in _settings.values) row.pagePublicId: row,
  };

  PageRow? page(String pagePublicId) =>
      rowWithId(_pages, pagePublicId, (row) => row.publicId);

  PageSettingsRow? settingsOf(String pagePublicId) =>
      rowWithId(_settings, pagePublicId, (row) => row.pagePublicId);

  String? pageIdOf(String pageDigest) => _pages[pageDigest]?.publicId;

  bool hasPageRow(String pageDigest) => _pages.containsKey(pageDigest);

  Iterable<String> get pagesWithoutRow =>
      _contentPages.where((page) => !_pages.containsKey(page));

  Iterable<UnplacedRow> orphansUnder(String pageDigest) => [
    if (!_pages.containsKey(pageDigest)) ...[
      ...?_loaded[pageDigest]?.unplaced.values,
      for (final row in [...?_loaded[pageDigest]?.unknownKinds])
        UnplacedRow(
          ref: refOf(row.key),
          stored: row.text,
          problem: 'a kind this build does not know, on a page with no row',
        ),
      ...unplaced.values.where(
        (row) => row.ref.name == SettingsName(pageDigest).name,
      ),
    ],
  ];

  List<UnplacedRow> get allUnplaced => [
    ...unplaced.values,
    for (final page in pagesWithoutRow)
      if (_loaded[page] case final loaded?) ...[
        ...loaded.unplaced.values,
        for (final row in loaded.unknownKinds)
          UnplacedRow(
            ref: refOf(row.key),
            stored: row.text,
            problem: 'a kind this build does not know, on a page with no row',
          ),
      ],
  ];

  PageTally get elsewhere {
    var tally = PageTally.empty.plusDamaged(unplaced.length);
    for (final page in pagesWithoutRow) {
      if (_loaded[page] case final loaded?) {
        tally = tally
            .plusDamaged(loaded.unplaced.length)
            .plusNewer(loaded.unknownKinds.length);
      }
    }
    return tally;
  }

  int rowsCounted = 0;

  PageTally _counted(LoadedPage page) {
    rowsCounted += page.rows;
    return page.tally();
  }

  bool countedAs(String pageDigest, Map<String, PageTally> listed) {
    final page = _pages[pageDigest];
    final loaded = _loaded[pageDigest];
    if (page == null || loaded == null) return true;
    final counted = listed[page.publicId];
    return loaded.isEmpty ? counted == null : counted == _counted(loaded);
  }

  Map<String, PageTally> talliesOver(Map<String, PageTally> stored) {
    final tallies = {...stored};
    for (final MapEntry(key: digest, value: loaded) in _loaded.entries) {
      final page = _pages[digest];
      if (page == null) continue;
      if (loaded.isEmpty) {
        tallies.remove(page.publicId);
      } else {
        tallies[page.publicId] = _counted(loaded);
      }
    }
    return tallies;
  }

  LoadedPage? loadedPage(String pageDigest) => _loaded[pageDigest];

  bool isLoaded(String pageDigest) => _loaded.containsKey(pageDigest);

  void addLoadedPage(String pageDigest, LoadedPage page) =>
      _loaded[pageDigest] = page;

  Set<String> get pageDigests => {..._pages.keys, ..._contentPages};

  Iterable<String> pagesOfElement(String elementPublicId) =>
      _elementPages[digestOf(elementPublicId)] ?? const {};

  Iterable<String> pagesOfLineupGroup(String lineupPublicId) =>
      _lineupPages[digestOf(lineupPublicId)] ?? const {};

  LoadedPage _mustBeLoaded(String pageDigest) =>
      _loaded[pageDigest] ??
      (throw StateError('page $pageDigest was not loaded before applying'));

  ElementRow? element(String elementPublicId) => pagesOfElement(elementPublicId)
      .map(
        (page) => rowWithId(
          _mustBeLoaded(page).elements,
          elementPublicId,
          (row) => row.publicId,
        ),
      )
      .nonNulls
      .firstOrNull;

  LineupGroupRow? lineupGroup(String lineupPublicId) =>
      pagesOfLineupGroup(lineupPublicId)
          .map(
            (page) => rowWithId(
              _mustBeLoaded(page).lineupGroups,
              lineupPublicId,
              (row) => row.publicId,
            ),
          )
          .nonNulls
          .firstOrNull;

  Iterable<ElementRow> elementsOnPage(String pageDigest) =>
      _mustBeLoaded(pageDigest).elements.values;

  Iterable<LineupGroupRow> lineupGroupsOnPage(String pageDigest) =>
      _mustBeLoaded(pageDigest).lineupGroups.values;

  StrategyRows rowsUnder(ReadableStrategy strategy) =>
      _LoadedRows(this, strategy);

  Held heldUnder(StoreName name) {
    final row = switch (name) {
      HeaderName() => switch (header) {
        HeaderPlaced(:final row) => row,
        HeaderUnplaced() || HeaderAbsent() => null,
      },
      PageName(:final digest) => _pages[digest],
      SettingsName(:final digest) => _settings[digest],
      ElementName(:final page, :final digest) =>
        _loaded[page]?.elements[digest],
      LineupName(:final page, :final digest) =>
        _loaded[page]?.lineupGroups[digest],
      _ => null,
    };
    if (row != null) return HeldRow(row);
    final unplacedHere = switch (name) {
      ElementName(:final page) ||
      LineupName(:final page) => _loaded[page]?.unplaced[name.name],
      _ => unplaced[name.name],
    };
    return switch (unplacedHere) {
      final found? => HeldUnplaced(found),
      null => const HeldNothing(),
    };
  }

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

  void keepRow(Row row) {
    final name = nameOf(row);
    switch (name) {
      case ElementName(:final page) || LineupName(:final page):
        _loaded[page]?.unplaced.remove(name.name);
      case _:
        unplaced.remove(name.name);
    }
    _keep(row);
  }

  void forgetRow(Row row) {
    switch (row) {
      case PageRow(:final publicId):
        forgetPage(digestOf(publicId));
      case PageSettingsRow(:final pagePublicId):
        _settings.remove(digestOf(pagePublicId));
      case ElementRow() || LineupGroupRow():
        _forget(row);
      case StrategyRow() || FolderRow():
        throw StateError('$row is never forgotten alone');
    }
  }

  void forgetPage(String pageDigest) {
    _pages.remove(pageDigest);
    _settings.remove(pageDigest);
    _contentPages.remove(pageDigest);
    final loaded = _loaded.remove(pageDigest);
    for (final digest in [...?loaded?.elements.keys]) {
      _elementPages[digest]?.remove(pageDigest);
    }
    for (final digest in [...?loaded?.lineupGroups.keys]) {
      _lineupPages[digest]?.remove(pageDigest);
    }
    unplaced.removeWhere((name, _) => name == SettingsName(pageDigest).name);
  }

  void _forget(Row row) {
    switch (row) {
      case ElementRow(:final pagePublicId, :final publicId):
        _loaded[digestOf(pagePublicId)]?.elements.remove(digestOf(publicId));
        _elementPages[digestOf(publicId)]?.remove(digestOf(pagePublicId));
      case LineupGroupRow(:final pagePublicId, :final publicId):
        _loaded[digestOf(pagePublicId)]?.lineupGroups.remove(
          digestOf(publicId),
        );
        _lineupPages[digestOf(publicId)]?.remove(digestOf(pagePublicId));
      case StrategyRow() || FolderRow() || PageRow() || PageSettingsRow():
        throw StateError('$row does not change name');
    }
  }

  void _keep(Row row) {
    switch (row) {
      case StrategyRow():
        header = HeaderPlaced(row);
      case PageRow(:final publicId):
        _pages[digestOf(publicId)] = row;
      case PageSettingsRow(:final pagePublicId):
        _settings[digestOf(pagePublicId)] = row;
      case ElementRow(:final pagePublicId, :final publicId):
        final page = digestOf(pagePublicId);
        _mustBeLoaded(page).elements[digestOf(publicId)] = row;
        (_elementPages[digestOf(publicId)] ??= {}).add(page);
        _contentPages.add(page);
      case LineupGroupRow(:final pagePublicId, :final publicId):
        final page = digestOf(pagePublicId);
        _mustBeLoaded(page).lineupGroups[digestOf(publicId)] = row;
        (_lineupPages[digestOf(publicId)] ??= {}).add(page);
        _contentPages.add(page);
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

final class PendingRows implements StrategyRows {
  PendingRows(this._loaded, this.strategy);

  final LoadedStrategy _loaded;
  final _pages = <String, PageRow>{};
  final _settings = <String, PageSettingsRow>{};
  final _elements = <String, ElementRow>{};
  final _groups = <String, LineupGroupRow>{};

  @override
  ReadableStrategy strategy;

  void take(Iterable<RowWrite> writes) {
    for (final write in writes) {
      switch (write.after) {
        case final ReadableStrategy row:
          strategy = row;
        case final PageRow row:
          _pages[row.publicId] = row;
        case final PageSettingsRow row:
          _settings[row.pagePublicId] = row;
        case final ElementRow row:
          _elements[row.publicId] = row;
        case final LineupGroupRow row:
          _groups[row.publicId] = row;
        case UnreadableStrategy() || FolderRow():
          throw StateError('${write.after} is not written by an op');
      }
    }
  }

  @override
  Iterable<PageRow> get pages => [
    for (final page in _loaded.pages)
      if (!_pages.containsKey(page.publicId)) page,
    ..._pages.values,
  ];

  @override
  PageRow? page(String pagePublicId) =>
      _pages[pagePublicId] ?? _loaded.page(pagePublicId);

  @override
  PageSettingsRow? settingsOf(String pagePublicId) =>
      _settings[pagePublicId] ?? _loaded.settingsOf(pagePublicId);

  @override
  ElementRow? element(String elementPublicId) =>
      _elements[elementPublicId] ?? _loaded.element(elementPublicId);

  @override
  LineupGroupRow? lineupGroup(String lineupPublicId) =>
      _groups[lineupPublicId] ?? _loaded.lineupGroup(lineupPublicId);

  @override
  Iterable<ElementRow> elementsOn(String pagePublicId) => [
    for (final row in _loaded.elementsOnPage(digestOf(pagePublicId)))
      if (!_elements.containsKey(row.publicId)) row,
    for (final row in _elements.values)
      if (row.pagePublicId == pagePublicId) row,
  ];

  @override
  Iterable<LineupGroupRow> lineupGroupsOn(String pagePublicId) => [
    for (final row in _loaded.lineupGroupsOnPage(digestOf(pagePublicId)))
      if (!_groups.containsKey(row.publicId)) row,
    for (final row in _groups.values)
      if (row.pagePublicId == pagePublicId) row,
  ];

  PageTally tallyOn(String pagePublicId) {
    final loaded = _loaded.loadedPage(digestOf(pagePublicId));
    return PageTally.count(
      elements: elementsOn(pagePublicId),
      lineupGroups: lineupGroupsOn(pagePublicId),
      damaged: loaded?.unplaced.length ?? 0,
      newer: loaded?.unknownKinds.length ?? 0,
    );
  }
}
