// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:convert';

import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:uuid/uuid.dart';

final class StrategySummaryFields {
  const StrategySummaryFields({
    required this.createdAt,
    required this.lastEdited,
    required this.pageCount,
    required this.itemCounts,
    required this.lineupCount,
  });

  final DateTime createdAt;
  final DateTime lastEdited;
  final int pageCount;
  final Map<ElementKind, int> itemCounts;
  final int lineupCount;
}

final class StrategyTimes {
  const StrategyTimes({required this.createdAt, required this.lastEdited});

  final DateTime createdAt;
  final DateTime lastEdited;
}

sealed class StrategyToRows {
  const StrategyToRows();
}

final class StrategyRowsMade extends StrategyToRows {
  const StrategyRowsMade({
    required this.rows,
    required this.summary,
    required this.supersededLegacyItems,
  });

  final StrategyRowSet rows;
  final StrategySummaryFields summary;
  final int supersededLegacyItems;
}

final class StrategyRowsRefused extends StrategyToRows {
  const StrategyRowsRefused(this.strategyId, this.problems);

  final String strategyId;
  final List<RowsProblem> problems;
}

sealed class RowsProblem {
  const RowsProblem();
}

final class NotMigrated extends RowsProblem {
  const NotMigrated(this.versionNumber);

  final int versionNumber;
}

final class WrittenByNewerBuild extends RowsProblem {
  const WrittenByNewerBuild(this.versionNumber);

  final int versionNumber;
}

final class ContentOutsidePages extends RowsProblem {
  const ContentOutsidePages(this.items);

  final int items;
}

final class PaletteHasTransparency extends RowsProblem {
  const PaletteHasTransparency();
}

final class PageIdRepeated extends RowsProblem {
  const PageIdRepeated(this.pageId);

  final String pageId;
}

final class ItemNotJson extends RowsProblem {
  const ItemNotJson(this.pageId, this.kind, this.itemId, this.problem);

  final String pageId;
  final ElementKind kind;
  final String itemId;
  final String problem;
}

enum LineupPart { origin, landing, link }

final class LineupIdRepeated extends RowsProblem {
  const LineupIdRepeated(this.pageId, this.part, this.id);

  final String pageId;
  final LineupPart part;
  final String id;
}

final class LineupNotJson extends RowsProblem {
  const LineupNotJson(this.pageId, this.problem);

  final String pageId;
  final String problem;
}

final class LineupMissingEnd extends RowsProblem {
  const LineupMissingEnd(this.pageId, this.linkId);

  final String pageId;
  final String linkId;
}

final class LineupSpotUnaimed extends RowsProblem {
  const LineupSpotUnaimed(this.pageId, this.part, this.spotId);

  final String pageId;
  final LineupPart part;
  final String spotId;
}

final class CarriedRowOffPage extends RowsProblem {
  const CarriedRowOffPage(this.elementId, this.pageId);

  final String elementId;
  final String pageId;
}

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

List<PageItem> pageItemsOf(StrategyPage page) => [
      for (final agent in page.agentData) AgentItem(agent),
      for (final ability in page.abilityData) AbilityItem(ability),
      for (final drawing in page.drawingData) DrawingItem(drawing),
      for (final text in page.textData) TextItem(text),
      for (final image in page.imageData) ImageItem(image),
      for (final utility in page.utilityData) UtilityItem(utility),
    ];

ThemePalette themePaletteOf(MapThemePalette palette) {
  final json = palette.toJson();
  return ThemePalette(
    base: json['base'] as String,
    detail: json['detail'] as String,
    highlight: json['highlight'] as String,
  );
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

StrategyToRows strategyToRows(
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
      PageSettingsRow(
        pagePublicId: page.id,
        settings: PageSettings(
          agentSize: page.settings.agentSize,
          abilitySize: page.settings.abilitySize,
          useNeutralTeamColors: page.settings.useNeutralTeamColors,
        ),
        revision: _rowRevision,
      ),
    );

    for (final (sortIndex, item) in pageItemsOf(page).indexed) {
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

    final lineupProblems = _lineupProblems(page);
    problems.addAll(lineupProblems);
    if (lineupProblems.isNotEmpty) continue;
    final List<CloudLineupRow> made;
    try {
      made = cloudLineupRows(
        page.lineUpGraph,
        takenGroupIds: takenGroupIds,
      ).rows;
    } on JsonUnsupportedObjectError catch (error) {
      problems.add(LineupNotJson(page.id, '$error'));
      continue;
    }
    for (final (sortIndex, row) in made.indexed) {
      final data = Map<String, Object?>.from(row.payload['data'] as Map);
      final linkIds = [
        for (final link in data['links'] as List)
          (link as Map<String, dynamic>)['id'] as String,
      ];
      final groupId = linkIds.contains(row.publicId)
          ? row.publicId
          : _derivedId(
              {...takenGroupIds, ...everyLinkId},
              [strategy.id, page.id, 'lineups', ...linkIds],
            );
      takenGroupIds.add(groupId);
      lineupCount += linkIds.length;
      lineupGroups.add(
        LiveLineupGroup(
          publicId: groupId,
          strategyPublicId: strategy.id,
          pagePublicId: page.id,
          payload: LineupGroupPayload(
            payloadVersion: lineupGroupPayloadVersion,
            data: {...data, 'id': groupId},
          ),
          sortIndex: sortIndex,
          revision: _rowRevision,
        ),
      );
    }
  }

  if (problems.isNotEmpty) return StrategyRowsRefused(strategy.id, problems);
  return StrategyRowsMade(
    rows: StrategyRowSet(
      strategy: StrategyRow(
        publicId: strategy.id,
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

sealed class StrategyFromRows {
  const StrategyFromRows();
}

final class StrategyDataMade extends StrategyFromRows {
  const StrategyDataMade({
    required this.strategy,
    required this.unreadable,
    required this.notInStrategy,
  });

  final StrategyData strategy;
  final List<UnreadableElement> unreadable;
  final List<Row> notInStrategy;
}

final class StrategyDataRefused extends StrategyFromRows {
  const StrategyDataRefused(this.strategyId, this.problems);

  final String strategyId;
  final List<DataProblem> problems;
}

sealed class DataProblem {
  const DataProblem();
}

final class UnknownMap extends DataProblem {
  const UnknownMap(this.mapData);

  final String mapData;
}

final class UnreadablePalette extends DataProblem {
  const UnreadablePalette(this.palette);

  final ThemePalette palette;
}

final class RowOffPage extends DataProblem {
  const RowOffPage(this.row);

  final Row row;
}

final class UnreadableLineupGroup extends DataProblem {
  const UnreadableLineupGroup(this.pageId, this.groupId, this.problem);

  final String pageId;
  final String groupId;
  final String problem;
}

final class LineupInTwoGroups extends DataProblem {
  const LineupInTwoGroups(this.pageId, this.part, this.id);

  final String pageId;
  final LineupPart part;
  final String id;
}

sealed class _Lineups {
  const _Lineups();
}

final class _LineupsRead extends _Lineups {
  const _LineupsRead(this.graph);

  final LineUpGraph graph;
}

final class _LineupsRefused extends _Lineups {
  const _LineupsRefused(this.problems);

  final List<DataProblem> problems;
}

_Lineups _lineupGraphOf(String pageId, List<LiveLineupGroup> groups) {
  groups.sort(
    (a, b) => _bySortIndexThenId(
      (a.sortIndex, a.publicId),
      (b.sortIndex, b.publicId),
    ),
  );
  final problems = <DataProblem>[];
  final rows = <CloudLineupRow>[];
  final seen = {for (final part in LineupPart.values) part: <String>{}};
  void claim(LineupPart part, Iterable<String> ids) {
    for (final id in ids) {
      if (!seen[part]!.add(id)) {
        problems.add(LineupInTwoGroups(pageId, part, id));
      }
    }
  }

  for (final group in groups) {
    final row = CloudLineupRow(
      publicId: group.publicId,
      payload: group.payload.toJson(),
    );
    try {
      final alone = lineUpGraphFromCloudRows([row]).graph;
      claim(LineupPart.origin, alone.origins.map((origin) => origin.id));
      claim(LineupPart.landing, alone.landings.map((landing) => landing.id));
      claim(LineupPart.link, alone.links.map((link) => link.id));
      rows.add(row);
    } on FormatException catch (error) {
      problems
          .add(UnreadableLineupGroup(pageId, group.publicId, error.message));
    }
  }
  if (problems.isNotEmpty) return _LineupsRefused(problems);
  return _LineupsRead(lineUpGraphFromCloudRows(rows).graph);
}

int _bySortIndexThenId(
  (int, String) left,
  (int, String) right,
) =>
    left.$1 != right.$1
        ? left.$1.compareTo(right.$1)
        : left.$2.compareTo(right.$2);

MapValue? _mapNamed(String name) {
  for (final MapEntry(:key, :value) in Maps.mapNames.entries) {
    if (value == name) return key;
  }
  return null;
}

StrategyFromRows strategyFromRows(StrategyRowSet rows, StrategyTimes times) {
  final strategyRow = rows.strategy;
  final problems = <DataProblem>[];
  final map = _mapNamed(strategyRow.mapData);
  if (map == null) problems.add(UnknownMap(strategyRow.mapData));
  MapThemePalette? palette;
  if (strategyRow.themeOverridePalette case final stored?) {
    try {
      palette = MapThemePalette.fromJson(stored.toJson());
      if (themePaletteOf(palette) != stored) {
        problems.add(UnreadablePalette(stored));
      }
    } on FormatException {
      problems.add(UnreadablePalette(stored));
    }
  }

  final unreadable = <UnreadableElement>[];
  final notInStrategy = <Row>[];
  final livePages = <LivePage>[];
  for (final page in rows.pages) {
    switch (page) {
      case LivePage():
        livePages.add(page);
      case TrashedPage():
        notInStrategy.add(page);
    }
  }
  livePages.sort(
    (a, b) => _bySortIndexThenId(
      (a.sortIndex, a.publicId),
      (b.sortIndex, b.publicId),
    ),
  );
  final liveIds = {for (final page in livePages) page.publicId};

  final itemsByPage = {for (final id in liveIds) id: <LiveElement>[]};
  for (final element in rows.elements) {
    final page = rows.page(element.pagePublicId);
    if (page == null) {
      problems.add(RowOffPage(element));
      continue;
    }
    switch (element) {
      case UnreadableElement():
        unreadable.add(element);
      case DeletedElement():
        notInStrategy.add(element);
      case LiveElement() when page is TrashedPage:
        notInStrategy.add(element);
      case LiveElement():
        itemsByPage[page.publicId]!.add(element);
    }
  }

  final groupsByPage = {for (final id in liveIds) id: <LiveLineupGroup>[]};
  for (final group in rows.lineupGroups) {
    final page = rows.page(group.pagePublicId);
    if (page == null) {
      problems.add(RowOffPage(group));
      continue;
    }
    switch (group) {
      case DeletedLineupGroup():
        notInStrategy.add(group);
      case LiveLineupGroup() when page is TrashedPage:
        notInStrategy.add(group);
      case LiveLineupGroup():
        groupsByPage[page.publicId]!.add(group);
    }
  }

  if (map == null) return StrategyDataRefused(strategyRow.publicId, problems);

  final pages = <StrategyPage>[];
  for (final page in livePages) {
    final items = itemsByPage[page.publicId]!
      ..sort(
        (a, b) => _bySortIndexThenId(
          (a.sortIndex, a.publicId),
          (b.sortIndex, b.publicId),
        ),
      );
    final agents = <PlacedAgentNode>[];
    final abilities = <PlacedAbility>[];
    final drawings = <DrawingElement>[];
    final texts = <PlacedText>[];
    final images = <PlacedImage>[];
    final utilities = <PlacedUtility>[];
    for (final element in items) {
      switch (PageItem.decode(element.payload, map)) {
        case CouldNotRead():
          unreadable.add(
            UnreadableElement(
              publicId: element.publicId,
              pagePublicId: element.pagePublicId,
              json: element.toJson(),
            ),
          );
        case Read(value: AgentItem(:final agent)):
          agents.add(agent);
        case Read(value: AbilityItem(:final ability)):
          abilities.add(ability);
        case Read(value: DrawingItem(:final drawing)):
          drawings.add(drawing);
        case Read(value: TextItem(:final text)):
          texts.add(text);
        case Read(value: ImageItem(:final image)):
          images.add(image);
        case Read(value: UtilityItem(:final utility)):
          utilities.add(utility);
      }
    }

    final LineUpGraph graph;
    switch (_lineupGraphOf(page.publicId, groupsByPage[page.publicId]!)) {
      case _LineupsRefused(problems: final refusals):
        problems.addAll(refusals);
        continue;
      case _LineupsRead(graph: final read):
        graph = read;
    }

    final stored = rows.settingsOf(page.publicId)?.settings;
    pages.add(
      StrategyPage(
        id: page.publicId,
        name: page.name,
        isAutoNamed: page.isAutoNamed,
        drawingData: drawings,
        agentData: agents,
        abilityData: abilities,
        textData: texts,
        imageData: images,
        utilityData: utilities,
        sortIndex: page.sortIndex,
        isAttack: page.isAttack,
        settings: stored == null
            ? StrategySettings()
            : StrategySettings(
                agentSize: stored.agentSize,
                abilitySize: stored.abilitySize,
                useNeutralTeamColors: stored.useNeutralTeamColors,
              ),
        lineUpOrigins: graph.origins,
        lineUpLandings: graph.landings,
        lineUpLinks: graph.links,
      ),
    );
  }

  if (problems.isNotEmpty) {
    return StrategyDataRefused(strategyRow.publicId, problems);
  }
  return StrategyDataMade(
    strategy: StrategyData(
      id: strategyRow.publicId,
      name: strategyRow.name,
      mapData: map,
      versionNumber: Settings.versionNumber,
      lastEdited: times.lastEdited,
      createdAt: times.createdAt,
      folderID: strategyRow.folderPublicId,
      themeProfileId: strategyRow.themeProfileId,
      themeOverridePalette: palette,
      pages: pages,
    ),
    unreadable: unreadable,
    notInStrategy: notInStrategy,
  );
}
