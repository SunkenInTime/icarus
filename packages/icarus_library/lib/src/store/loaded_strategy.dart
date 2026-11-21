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

final class LoadedPage {
  final elements = <String, ElementRow>{};
  final lineupGroups = <String, LineupGroupRow>{};
  final unknownKinds = <UnknownKindRow>[];
  final unplaced = <String, UnplacedRow>{};
  final foreignNames = <ForeignName>[];

  PageTally tally() {
    var tally = PageTally.empty
        .plusDamaged(unplaced.length)
        .plusNewer(unknownKinds.length);
    for (final row in elements.values) {
      tally = tally.plus(row, 1);
    }
    for (final row in lineupGroups.values) {
      tally = tally.plusGroup(row, 1);
    }
    return tally;
  }
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
        case final ForeignName name:
          foreignNames.add(name);
        case _:
          break;
      }
    }
  }

  final String digest;
  Parsed<StrategyRow> header;
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
        Placed(:final row) => row,
        Unplaced() => null,
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
        header = Placed(row);
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
