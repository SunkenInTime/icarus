import 'apply.dart';
import 'field_rules.dart';
import 'json.dart';
import 'ops.dart';
import 'outcome.dart';
import 'payloads.dart';
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
  final reached = seenRows(rows);
  final wanted = seenRows(target, carriedFrom: stored);
  if (sameJson(reached, wanted)) return DiffReached(rows.asRowSet());
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

Map<String, Object?> seenRows(
  StrategyRows rows, {
  StrategyRowSet? carriedFrom,
}) {
  final all = switch (rows) {
    final AppliedRows applied => (
      pages: applied.pages,
      settings: applied.settings,
      elements: applied.elements,
      groups: applied.lineupGroups,
    ),
    final StrategyRowSet set => (
      pages: set.pages,
      settings: set.settings,
      elements: set.elements,
      groups: set.lineupGroups,
    ),
    _ => throw ArgumentError.value(rows, 'rows', 'not a full row set'),
  };
  final unreadable = <String, Object?>{
    for (final row in [
      ...all.pages,
      ...all.settings,
      ...all.elements,
      ...all.groups,
      if (carriedFrom != null) ...[
        ...carriedFrom.pages,
        ...carriedFrom.settings,
        ...carriedFrom.elements,
        ...carriedFrom.lineupGroups,
      ],
    ])
      if (row is UnreadablePage ||
          row is UnreadablePageSettings ||
          row is UnreadableElement ||
          row is UnreadableLineupGroup)
        '${row.key}': row.toJson(),
  };
  final live = all.pages.whereType<LivePage>().toList()
    ..sort(
      (a, b) => switch (a.sortIndex.compareTo(b.sortIndex)) {
        0 => a.publicId.compareTo(b.publicId),
        final order => order,
      },
    );
  final shown = {
    for (final page in all.pages)
      if (page is LivePage || page is UnreadablePage) page.publicId,
  };
  final settings = {for (final row in all.settings) row.pagePublicId: row};
  final strategy = rows.strategy;
  return {
    'strategy': {
      'name': strategy.name,
      'mapData': strategy.mapData,
      'folderPublicId': strategy.folderPublicId,
      'themeProfileId': strategy.themeProfileId,
      'themeOverridePalette': strategy.themeOverridePalette?.toJson(),
    },
    'pages': [
      for (final page in live)
        {
          'publicId': page.publicId,
          'name': page.name,
          'isAutoNamed': page.isAutoNamed,
          'isAttack': page.isAttack,
          'settings': switch (settings[page.publicId]) {
            ReadablePageSettings(:final settings) => settings?.toJson(),
            UnreadablePageSettings() || null => null,
          },
        },
    ],
    'elements': {
      for (final row in all.elements)
        if (row case LiveElement(
          :final publicId,
          :final pagePublicId,
          :final payload,
          :final sortIndex,
        ) when shown.contains(pagePublicId))
          publicId: {
            'page': pagePublicId,
            'sortIndex': sortIndex,
            'payload': _withoutClearedFields(payload),
          },
    },
    'lineupGroups': {
      for (final row in all.groups)
        if (row case LiveLineupGroup(
          :final publicId,
          :final pagePublicId,
          :final payload,
          :final sortIndex,
        ) when shown.contains(pagePublicId))
          publicId: {
            'page': pagePublicId,
            'sortIndex': sortIndex,
            'payload': payload.toJson(),
          },
    },
    'unreadable': unreadable,
  };
}

Map<String, Object?> _withoutClearedFields(ElementPayload payload) {
  final json = payload.toJson();
  final data = {...json['data']! as Map<String, Object?>};
  for (final later in laterElementFields) {
    if (!later.kinds.contains(payload.kind)) continue;
    if (later.empty case ClearedBy(
      :final value,
    ) when sameJson(data[later.field], value)) {
      data.remove(later.field);
    }
  }
  return {...json, 'data': data};
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
