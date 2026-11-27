import 'dart:convert';

import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/strategy_image.dart'
    show ReadBack, ReadsBackDifferently, ReadsBackEqual;
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:uuid/uuid.dart';

const _rowRevision = 1;

String _derivedId(Set<String> taken, List<Object> seed) {
  for (var attempt = 0;; attempt++) {
    final id = const Uuid().v5(
      Namespace.url.value,
      jsonEncode([...seed, attempt]),
    );
    if (!taken.contains(id)) return id;
  }
}

bool _isOpaque(MapThemePalette palette) => [
      palette.baseColorValue,
      palette.detailColorValue,
      palette.highlightColorValue,
    ].every((value) => value >>> 24 == 0xFF);

int _legacyItemCount(StrategyData strategy) =>
    strategy.drawingData.length +
    strategy.agentData.length +
    strategy.abilityData.length +
    strategy.textData.length +
    strategy.imageData.length +
    strategy.utilityData.length;

List<RowsProblem> _lineupProblems(StrategyPage page) {
  final problems = <RowsProblem>[];
  void repeated(LineupPart part, Iterable<String> ids) {
    final seen = <String>{};
    for (final id in ids) {
      if (!seen.add(id)) problems.add(LineupIdRepeated(page.id, part, id));
    }
  }

  final originIds = [for (final origin in page.lineUpOrigins) origin.id];
  final landingIds = [for (final landing in page.lineUpLandings) landing.id];
  repeated(LineupPart.origin, originIds);
  repeated(LineupPart.landing, landingIds);
  repeated(LineupPart.link, [for (final link in page.lineUpLinks) link.id]);
  for (final link in page.lineUpLinks) {
    if (!originIds.contains(link.originId) ||
        !landingIds.contains(link.landingId)) {
      problems.add(LineupMissingEnd(page.id, link.id));
    }
  }
  final aimedOrigins = {for (final link in page.lineUpLinks) link.originId};
  final aimedLandings = {for (final link in page.lineUpLinks) link.landingId};
  for (final id in originIds.where((id) => !aimedOrigins.contains(id))) {
    problems.add(LineupSpotUnaimed(page.id, LineupPart.origin, id));
  }
  for (final id in landingIds.where((id) => !aimedLandings.contains(id))) {
    problems.add(LineupSpotUnaimed(page.id, LineupPart.landing, id));
  }
  return problems;
}

StrategyToRows mainStrategyToRows(
  StrategyData strategy, {
  Iterable<UnreadableElement> carried = const [],
}) {
  final problems = <RowsProblem>[];
  if (strategy.versionNumber < Settings.versionNumber) {
    problems.add(NotMigrated(strategy.versionNumber));
  } else if (strategy.versionNumber > Settings.versionNumber) {
    problems.add(WrittenByNewerBuild(strategy.versionNumber));
  }
  final legacyItems = _legacyItemCount(strategy);
  if (strategy.pages.isEmpty && legacyItems > 0) {
    problems.add(ContentOutsidePages(legacyItems));
  }
  if (strategy.themeOverridePalette case final palette?
      when !_isOpaque(palette)) {
    problems.add(const PaletteHasTransparency());
  }
  final pageIds = <String>{};
  for (final page in strategy.pages) {
    if (!pageIds.add(page.id)) problems.add(PageIdRepeated(page.id));
  }
  final carriedRows = carried.toList();
  for (final row in carriedRows) {
    if (!pageIds.contains(row.pagePublicId)) {
      problems.add(CarriedRowOffPage(row.publicId, row.pagePublicId));
    }
  }

  final takenElementIds = {for (final row in carriedRows) row.publicId};
  final everyItemId = {
    for (final page in strategy.pages)
      for (final item in pageItemsOf(page)) item.id,
  };
  final everyLinkId = {
    for (final page in strategy.pages)
      for (final link in page.lineUpLinks) link.id,
  };
  final takenGroupIds = <String>{};
  final pages = <PageRow>[];
  final settings = <PageSettingsRow>[];
  final elements = <ElementRow>[...carriedRows];
  final lineupGroups = <LineupGroupRow>[];
  final itemCounts = {for (final kind in ElementKind.values) kind: 0};
  var lineupCount = 0;

  for (final page in strategy.pages) {
    pages.add(
      LivePage(
        publicId: page.id,
        strategyPublicId: strategy.id,
        name: page.name,
        isAutoNamed: page.isAutoNamed,
        sortIndex: page.sortIndex,
        isAttack: page.isAttack,
        revision: _rowRevision,
      ),
    );
    settings.add(
      ReadablePageSettings(
        pagePublicId: page.id,
        settings: PageSettings(
          agentSize: page.settings.agentSize,
          abilitySize: page.settings.abilitySize,
          useNeutralTeamColors: page.settings.useNeutralTeamColors,
        ),
        revision: _rowRevision,
      ),
    );

    for (final items in pageItemsByKind(page)) {
      for (final (sortIndex, item) in items.indexed) {
        switch (item.payload) {
          case CouldNotRead(:final problem):
            problems.add(ItemNotJson(page.id, item.kind, item.id, problem));
          case Read(value: final payload):
            final rowId = takenElementIds.contains(item.id)
                ? _derivedId(
                    {...takenElementIds, ...everyItemId},
                    [strategy.id, page.id, item.id, sortIndex],
                  )
                : item.id;
            takenElementIds.add(rowId);
            itemCounts[item.kind] = itemCounts[item.kind]! + 1;
            elements.add(
              LiveElement(
                publicId: rowId,
                pagePublicId: page.id,
                payload: payload,
                sortIndex: sortIndex,
                revision: _rowRevision,
              ),
            );
        }
      }
    }

    final lineupProblems = _lineupProblems(page);
    problems.addAll(lineupProblems);
    if (lineupProblems.isNotEmpty) continue;
    final List<LiveLineupGroup> made;
    try {
      made = lineupGroupRowsOf(
        strategyId: strategy.id,
        pageId: page.id,
        graph: page.lineUpGraph,
        takenGroupIds: takenGroupIds,
        everyLinkId: everyLinkId,
      );
    } on JsonUnsupportedObjectError catch (error) {
      problems.add(LineupNotJson(page.id, '$error'));
      continue;
    }
    lineupCount += page.lineUpLinks.length;
    lineupGroups.addAll(made);
  }

  if (problems.isNotEmpty) return StrategyRowsRefused(strategy.id, problems);
  return StrategyRowsMade(
    rows: StrategyRowSet(
      strategy: ReadableStrategy(
        publicId: strategy.id,
        createdAt: strategy.createdAt,
        updatedAt: strategy.lastEdited,
        folderPublicId: strategy.folderID,
        name: strategy.name,
        mapData: Maps.mapNames[strategy.mapData]!,
        themeProfileId: strategy.themeProfileId,
        themeOverridePalette: switch (strategy.themeOverridePalette) {
          final palette? => themePaletteOf(palette),
          null => null,
        },
        revision: _rowRevision,
      ),
      pages: pages,
      settings: settings,
      elements: elements,
      lineupGroups: lineupGroups,
    ),
    summary: StrategySummaryFields(
      createdAt: strategy.createdAt,
      lastEdited: strategy.lastEdited,
      pageCount: strategy.pages.length,
      itemCounts: itemCounts,
      lineupCount: lineupCount,
    ),
    supersededLegacyItems: strategy.pages.isEmpty ? 0 : legacyItems,
  );
}

final class MainStrategyImage {
  const MainStrategyImage(this.rows, this.readBack);

  final StrategyToRows rows;
  final ReadBack readBack;
}

typedef PageKey = String Function(StrategyData strategy, StrategyPage page);

final class MainStrategyImages {
  MainStrategyImages({this.pageKey = directPageKey});

  final PageKey pageKey;
  final _pagesReadingBackEqual = <String, Map<String, String>>{};

  MainStrategyImage of(StrategyData strategy) => switch (_made(strategy)) {
        (final made?, null) => MainStrategyImage(
            made,
            _settled(() => _steps(strategy, made.rows).last!),
          ),
        (_, final refused?) => refused,
        _ => throw StateError('unreachable'),
      };

  Future<MainStrategyImage> between(
    StrategyData strategy,
    Future<void> Function() breathe,
  ) async {
    final StrategyRowsMade made;
    switch (_made(strategy)) {
      case (final madeRows?, null):
        made = madeRows;
      case (_, final refused?):
        return refused;
      default:
        throw StateError('unreachable');
    }
    await breathe();
    ReadBack? readBack;
    try {
      for (final step in _steps(strategy, made.rows)) {
        if (step != null) {
          readBack = step;
        } else {
          await breathe();
        }
      }
    } on Object catch (error) {
      readBack = ReadsBackDifferently('it cannot be compared: $error');
    }
    return MainStrategyImage(made, readBack!);
  }

  void forget(String strategyId) => _pagesReadingBackEqual.remove(strategyId);

  (StrategyRowsMade?, MainStrategyImage?) _made(StrategyData strategy) {
    final rows = mainStrategyToRows(strategy);
    return switch (rows) {
      StrategyRowsRefused() => (
          null,
          MainStrategyImage(
            rows,
            const ReadsBackDifferently('the converter refuses it'),
          ),
        ),
      final StrategyRowsMade made => (made, null),
    };
  }

  static ReadBack _settled(ReadBack Function() check) {
    try {
      return check();
    } on Object catch (error) {
      return ReadsBackDifferently('it cannot be compared: $error');
    }
  }

  Iterable<ReadBack?> _steps(StrategyData strategy, StrategyRowSet rows) sync* {
    final known = _pagesReadingBackEqual[strategy.id] ?? const {};
    final equal = <String, String>{};
    final outlineEqual = _outlineReadsBackEqual(strategy, rows);
    String? differing;
    for (final page in strategy.pages) {
      yield null;
      final text = pageKey(strategy, page);
      if (known[page.id] == text ||
          _pageReadBack(rows, page.id, pageKey) == text) {
        equal[page.id] = text;
      } else {
        differing ??= page.id;
      }
    }
    _pagesReadingBackEqual[strategy.id] = equal;
    if (!outlineEqual) {
      yield const ReadsBackDifferently(
        'its fields, page order or positions read back differently',
      );
      return;
    }
    if (differing == null) {
      yield const ReadsBackEqual();
      return;
    }
    yield null;
    yield _pageDifferences(strategy, rows, differing);
  }
}

ReadBack _pageDifferences(
  StrategyData strategy,
  StrategyRowSet rows,
  String pageId,
) {
  final page = strategy.pages.firstWhere((page) => page.id == pageId);
  final back = strategyFromRows(_asStored(StrategyRowSet(
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

String _outline(StrategyData strategy) => jsonEncode([
      strategyFieldsFingerprint(strategy),
      [
        for (final page in strategy.pages) [page.id, page.sortIndex],
      ],
    ]);

String fingerprintPageKey(StrategyData strategy, StrategyPage page) =>
    jsonEncode([
      Maps.mapNames[strategy.mapData],
      pageFingerprint(page, strategy.id),
      pagePictureFileNames(page)..sort(),
    ]);

String directPageKey(StrategyData strategy, StrategyPage page) => [
      jsonEncode(Maps.mapNames[strategy.mapData]),
      jsonEncode(page.id),
      jsonEncode(page.sortIndex),
      jsonEncode(page.name),
      jsonEncode(page.isAutoNamed),
      DrawingProvider.objectToJson(page.drawingData),
      AgentProvider.objectToJson(page.agentData),
      AbilityProvider.objectToJson(page.abilityData),
      TextProvider.objectToJson(page.textData),
      PlacedImageProvider.objectToJson(page.imageData, strategy.id),
      UtilityProvider.objectToJson(page.utilityData),
      jsonEncode(page.isAttack),
      StrategySettingsProvider.objectToJson(page.settings),
      jsonEncode(page.lineUpGraph.toJson()),
      jsonEncode(pagePictureFileNames(page)..sort()),
    ].join('\n');

bool _everyRowOnAPage(StrategyRowSet rows) => [
      for (final row in rows.elements) row.pagePublicId,
      for (final row in rows.lineupGroups) row.pagePublicId,
    ].every((pageId) => rows.page(pageId) != null);

bool _outlineReadsBackEqual(StrategyData strategy, StrategyRowSet rows) =>
    _everyRowOnAPage(rows) &&
    switch (strategyFromRows(_asStored(StrategyRowSet(
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
        _outline(strategy) == _outline(back),
      StrategyDataMade() || StrategyDataRefused() => false,
    };

String? _pageReadBack(StrategyRowSet rows, String pageId, PageKey pageKey) =>
    switch (strategyFromRows(_asStored(StrategyRowSet(
      strategy: rows.strategy,
      pages: [if (rows.page(pageId) case final page?) page],
      settings: [if (rows.settingsOf(pageId) case final settings?) settings],
      elements: rows.elementsOn(pageId),
      lineupGroups: rows.lineupGroupsOn(pageId),
    )))) {
      StrategyDataMade(
        strategy: final back,
        :final unreadable,
        :final notInStrategy,
      )
          when unreadable.isEmpty &&
              notInStrategy.isEmpty &&
              back.pages.length == 1 =>
        pageKey(back, back.pages.single),
      StrategyDataMade() || StrategyDataRefused() => null,
    };

StrategyRowSet _asStored(StrategyRowSet rows) => StrategyRowSet(
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
