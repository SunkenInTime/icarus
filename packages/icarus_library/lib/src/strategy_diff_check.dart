import 'package:collection/collection.dart';

import 'apply.dart';
import 'field_rules.dart';
import 'json.dart';
import 'ops.dart';
import 'outcome.dart';
import 'rows.dart';
import 'strategy_rows.dart';

sealed class DiffCheck {
  const DiffCheck();
}

final class DiffReached extends DiffCheck {
  const DiffReached(this.rows);

  final StrategyRowSet rows;
}

final class DiffMissed extends DiffCheck {
  const DiffMissed(this.what);

  final String what;
}

DiffCheck checkDiff(
  StrategyRowSet stored,
  StrategyRowSet target,
  List<StrategyOp> ops,
) {
  final rows = AppliedRows(stored);
  for (final (index, op) in ops.indexed) {
    switch (applyOp(rows, op)) {
      case OpApplied(:final writes):
        rows.take(writes);
      case OpUnchanged():
        return DiffMissed('op $index (${op.type.wireName}) changed nothing');
      case OpRefused(:final refusal):
        return DiffMissed('op $index (${op.type.wireName}) refused: $refusal');
    }
  }
  return checkReached(stored, target, rows.asRowSet());
}

DiffCheck checkReached(
  StrategyRowSet stored,
  StrategyRowSet target,
  StrategyRowSet rows,
) {
  final reachedRows = _Rows(rows);
  final targetRows = _Rows(target);
  final reached = _view(reachedRows, reachedRows, staysWithPage: const {});
  final targetLive = {
    for (final page in target.pages)
      if (page is LivePage) page.publicId,
  };
  final staysWithPage = {
    for (final page in stored.pages)
      if (page is TrashedPage ||
          (page is LivePage && !targetLive.contains(page.publicId)))
        page.publicId,
  };
  final targetElements = {for (final row in target.elements) row.publicId};
  final targetGroups = {for (final row in target.lineupGroups) row.publicId};
  final wantedRows = _Rows(
    StrategyRowSet(
      strategy: target.strategy,
      pages: target.pages,
      settings: target.settings,
      elements: [
        ...target.elements,
        for (final row in stored.elements)
          if (row is LiveElement &&
              !targetElements.contains(row.publicId) &&
              staysWithPage.contains(row.pagePublicId))
            row,
      ],
      lineupGroups: [
        ...target.lineupGroups,
        for (final row in stored.lineupGroups)
          if (row is LiveLineupGroup &&
              !targetGroups.contains(row.publicId) &&
              staysWithPage.contains(row.pagePublicId))
            row,
      ],
    ),
  );
  final wanted = _view(
    wantedRows,
    _Rows(
      StrategyRowSet(
        strategy: stored.strategy,
        pages: stored.pages,
        settings: stored.settings,
        elements: [
          ...stored.elements,
          for (final row in targetRows.elements)
            if (stored.element(row.publicId) == null) row,
        ],
        lineupGroups: [
          ...stored.lineupGroups,
          for (final row in targetRows.groups)
            if (stored.lineupGroup(row.publicId) == null) row,
        ],
      ),
    ),
    staysWithPage: staysWithPage,
  );
  if (sameJson(reached, wanted)) return DiffReached(rows);
  return DiffMissed(_firstDifference(wanted, reached, 'rows'));
}

final class AppliedRows implements StrategyRows {
  AppliedRows(StrategyRowSet rows) : strategy = rows.strategy {
    take([for (final row in rows.rows.skip(1)) RowAdded(row)]);
  }

  @override
  ReadableStrategy strategy;
  final _pages = <String, PageRow>{};
  final _settings = <String, PageSettingsRow>{};
  final _elements = <String, ElementRow>{};
  final _groups = <String, LineupGroupRow>{};
  final _elementsByPage = <String, Map<String, ElementRow>>{};
  final _groupsByPage = <String, Map<String, LineupGroupRow>>{};

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
          if (_elements[row.publicId] case final before?) {
            _elementsByPage[before.pagePublicId]?.remove(row.publicId);
          }
          _elements[row.publicId] = row;
          (_elementsByPage[row.pagePublicId] ??= {})[row.publicId] = row;
        case final LineupGroupRow row:
          if (_groups[row.publicId] case final before?) {
            _groupsByPage[before.pagePublicId]?.remove(row.publicId);
          }
          _groups[row.publicId] = row;
          (_groupsByPage[row.pagePublicId] ??= {})[row.publicId] = row;
        case UnreadableStrategy() || FolderRow():
          throw ArgumentError.value(write, 'writes', 'not a strategy row');
      }
    }
  }

  StrategyRowSet asRowSet() => StrategyRowSet(
    strategy: strategy,
    pages: pages,
    settings: settings,
    elements: elements,
    lineupGroups: lineupGroups,
  );

  @override
  Iterable<PageRow> get pages => _pages.values;

  Iterable<PageSettingsRow> get settings => _settings.values;

  Iterable<ElementRow> get elements => _elements.values;

  Iterable<LineupGroupRow> get lineupGroups => _groups.values;

  @override
  PageRow? page(String pagePublicId) => _pages[pagePublicId];

  @override
  PageSettingsRow? settingsOf(String pagePublicId) => _settings[pagePublicId];

  @override
  ElementRow? element(String elementPublicId) => _elements[elementPublicId];

  @override
  LineupGroupRow? lineupGroup(String lineupPublicId) => _groups[lineupPublicId];

  @override
  Iterable<ElementRow> elementsOn(String pagePublicId) =>
      _elementsByPage[pagePublicId]?.values ?? const [];

  @override
  Iterable<LineupGroupRow> lineupGroupsOn(String pagePublicId) =>
      _groupsByPage[pagePublicId]?.values ?? const [];
}

final class _Rows {
  _Rows(StrategyRows rows)
    : strategy = rows.strategy,
      pages = [
        ...switch (rows) {
          final AppliedRows applied => applied.pages,
          final StrategyRowSet set => set.pages,
          _ => throw ArgumentError.value(rows, 'rows', 'not a full row set'),
        },
      ],
      settings = [
        ...switch (rows) {
          final AppliedRows applied => applied.settings,
          final StrategyRowSet set => set.settings,
          _ => const <PageSettingsRow>[],
        },
      ],
      elements = [
        ...switch (rows) {
          final AppliedRows applied => applied.elements,
          final StrategyRowSet set => set.elements,
          _ => const <ElementRow>[],
        },
      ],
      groups = [
        ...switch (rows) {
          final AppliedRows applied => applied.lineupGroups,
          final StrategyRowSet set => set.lineupGroups,
          _ => const <LineupGroupRow>[],
        },
      ];

  final ReadableStrategy strategy;
  final List<PageRow> pages;
  final List<PageSettingsRow> settings;
  final List<ElementRow> elements;
  final List<LineupGroupRow> groups;

  Iterable<Row> get all => [...pages, ...settings, ...elements, ...groups];
}

Map<String, Object?> seenRows(StrategyRows rows) =>
    _view(_Rows(rows), _Rows(rows), staysWithPage: const {});

Map<String, Object?> _view(
  _Rows rows,
  _Rows kept, {
  required Set<String> staysWithPage,
}) {
  final live = rows.pages.whereType<LivePage>().toList()
    ..sort(
      (a, b) => switch (a.sortIndex.compareTo(b.sortIndex)) {
        0 => a.publicId.compareTo(b.publicId),
        final order => order,
      },
    );
  final settings = {for (final row in rows.settings) row.pagePublicId: row};
  final keptPages = {for (final row in kept.pages) row.publicId: row};
  final keptSettings = {for (final row in kept.settings) row.pagePublicId: row};
  final keptElements = {for (final row in kept.elements) row.publicId: row};
  final keptGroups = {for (final row in kept.groups) row.publicId: row};
  final strategy = rows.strategy;
  return {
    'strategy': {
      'publicId': strategy.publicId,
      'name': strategy.name,
      'mapData': strategy.mapData,
      'folderPublicId': strategy.folderPublicId,
      'themeProfileId': strategy.themeProfileId,
      'themeOverridePalette': _keeping(
        strategy.themeOverridePalette?.toJson(),
        kept.strategy.themeOverridePalette?.toJson(),
      ),
      'unknown': _keeping(
        strategy.unknownFields.toJson(),
        kept.strategy.unknownFields.toJson(),
      ),
    },
    'pages': [
      for (final page in live)
        {
          'publicId': page.publicId,
          'name': page.name,
          'isAutoNamed': page.isAutoNamed,
          'isAttack': page.isAttack,
          'unknown': _keeping(
            page.unknownFields.toJson(),
            switch (keptPages[page.publicId]) {
              ReadablePageRow(:final unknownFields) => unknownFields.toJson(),
              _ => null,
            },
          ),
          'settings': switch (settings[page.publicId]) {
            null => 'no settings row',
            UnreadablePageSettings() => 'unreadable',
            ReadablePageSettings(:final settings, :final unknownFields) => {
              'value': _keeping(
                settings?.toJson(),
                switch (keptSettings[page.publicId]) {
                  ReadablePageSettings(:final settings) => settings?.toJson(),
                  _ => null,
                },
              ),
              'unknown': _keeping(
                unknownFields.toJson(),
                switch (keptSettings[page.publicId]) {
                  ReadablePageSettings(:final unknownFields) =>
                    unknownFields.toJson(),
                  _ => null,
                },
              ),
            },
          },
        },
    ],
    'trashedPages': <String>{
      for (final page in rows.pages)
        if (page is TrashedPage) page.publicId,
      ...staysWithPage,
    }.sorted(),
    'elements': {
      for (final row in rows.elements)
        if (row case LiveElement(:final publicId))
          publicId: _element(row, switch (keptElements[publicId]) {
            final ReadableElementRow stored => stored,
            _ => null,
          }),
    },
    'lineupGroups': {
      for (final row in rows.groups)
        if (row case LiveLineupGroup(:final publicId))
          publicId: _group(row, switch (keptGroups[publicId]) {
            final ReadableLineupGroupRow stored => stored,
            _ => null,
          }),
    },
    'unreadable': {
      for (final row in [...rows.all, ...kept.all])
        if (row is UnreadablePage ||
            row is UnreadablePageSettings ||
            row is UnreadableElement ||
            row is UnreadableLineupGroup)
          '${row.key}': row.toJson(),
    },
  };
}

Object? _keeping(Object? wanted, Object? stored) => switch ((wanted, stored)) {
  (final Map<String, Object?> w, final Map<String, Object?> s) => {
    for (final MapEntry(:key, :value) in s.entries)
      if (!w.containsKey(key)) key: value,
    ...w,
  },
  _ => wanted,
};

final _clearable = {
  pictureIdField,
  for (final later in laterElementFields) later.field,
};

Map<String, Object?> _element(LiveElement row, ReadableElementRow? stored) {
  final data = {...row.payload.data.toJson()};
  for (final later in laterElementFields) {
    if (!later.kinds.contains(row.payload.kind)) continue;
    if (later.empty case ClearedBy(
      :final value,
    ) when sameJson(data[later.field], value)) {
      data.remove(later.field);
    }
  }
  final storedData = stored?.payload.data.toJson() ?? const {};
  return {
    'page': row.pagePublicId,
    'sortIndex': row.sortIndex,
    'kind': row.payload.kind.name,
    'payloadVersion': row.payload.payloadVersion,
    'data': {
      for (final MapEntry(:key, :value) in storedData.entries)
        if (!data.containsKey(key) && !_clearable.contains(key)) key: value,
      ...data,
    },
    'envelope': _keeping(
      row.payload.unknownFields.toJson(),
      stored?.payload.unknownFields.toJson(),
    ),
    'unknown': _keeping(
      row.unknownFields.toJson(),
      stored?.unknownFields.toJson(),
    ),
  };
}

Map<String, Object?> _group(
  LiveLineupGroup row,
  ReadableLineupGroupRow? stored,
) {
  final data = row.payload.data.toJson();
  final storedData = stored?.payload.data.toJson() ?? const {};
  return {
    'page': row.pagePublicId,
    'sortIndex': row.sortIndex,
    'payloadVersion': row.payload.payloadVersion,
    'data': {
      for (final MapEntry(:key, :value) in storedData.entries)
        if (!data.containsKey(key)) key: value,
      for (final MapEntry(:key, :value) in data.entries)
        key: switch ((value, storedData[key])) {
          (final List<Object?> items, final List<Object?> storedItems) => [
            for (final item in items)
              _keeping(
                item,
                [
                  for (final storedItem in storedItems)
                    if (storedItem is Map &&
                        item is Map &&
                        storedItem['id'] == item['id'])
                      storedItem,
                ].firstOrNull,
              ),
          ],
          _ => value,
        },
    },
    'envelope': _keeping(
      row.payload.unknownFields.toJson(),
      stored?.payload.unknownFields.toJson(),
    ),
    'unknown': _keeping(
      row.unknownFields.toJson(),
      stored?.unknownFields.toJson(),
    ),
  };
}

String _firstDifference(Object? wanted, Object? reached, String path) {
  switch ((wanted, reached)) {
    case (final Map<String, Object?> a, final Map<String, Object?> b):
      for (final key in {...a.keys, ...b.keys}) {
        if (!sameJson(a[key], b[key])) {
          return _firstDifference(a[key], b[key], '$path.$key');
        }
      }
    case (final List<Object?> a, final List<Object?> b)
        when a.length == b.length:
      for (var i = 0; i < a.length; i++) {
        if (!sameJson(a[i], b[i])) {
          return _firstDifference(a[i], b[i], '$path[$i]');
        }
      }
    case _:
      break;
  }
  return '$path: wanted $wanted, reached $reached';
}
