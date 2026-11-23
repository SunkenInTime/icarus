import 'package:icarus/const/maps.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:uuid/uuid.dart';

sealed class OpGap {
  const OpGap();
}

final class ObjectNotInStore extends OpGap {
  const ObjectNotInStore(this.kind, this.id, this.change);

  final ActionObjectKind kind;
  final String id;
  final String change;

  @override
  String toString() => '$change ${kind.name} $id: the store has no live row';
}

final class ObjectAlreadyInStore extends OpGap {
  const ObjectAlreadyInStore(this.kind, this.id);

  final ActionObjectKind kind;
  final String id;

  @override
  String toString() => 'added ${kind.name} $id: the store already has it';
}

final class ObjectNotEncoded extends OpGap {
  const ObjectNotEncoded(this.kind, this.id, this.problem);

  final ActionObjectKind kind;
  final String id;
  final String problem;

  @override
  String toString() => '${kind.name} $id could not be encoded: $problem';
}

final class LineupGroupNotInStore extends OpGap {
  const LineupGroupNotInStore(this.groupId, this.partId);

  final String groupId;
  final String partId;

  @override
  String toString() =>
      'lineup group $groupId (holding $partId): the store has no live row';
}

final class LineupPartNotFound extends OpGap {
  const LineupPartNotFound(this.partId);

  final String partId;

  @override
  String toString() => 'lineup part $partId is in no group';
}

final class PageNotInStore extends OpGap {
  const PageNotInStore(this.pageId, this.change);

  final String pageId;
  final String change;

  @override
  String toString() => '$change page $pageId: the store has no live page';
}

final class PageNotRead extends OpGap {
  const PageNotRead(this.pageId, this.reading);

  final String pageId;
  final String reading;

  @override
  String toString() => 'page $pageId could not be read: $reading';
}

sealed class LineupShape {
  const LineupShape();
}

final class LineupsInsideGroups extends LineupShape {
  const LineupsInsideGroups();
}

final class LineupGroupsChanged extends LineupShape {
  const LineupGroupsChanged({required this.before, required this.after});

  final Set<String> before;
  final Set<String> after;

  int get groupsBefore => before.length;

  int get groupsAfter => after.length;
}

final class BuiltOps {
  BuiltOps({
    required List<StrategyOp> ops,
    required List<OpGap> gaps,
    required List<LineupShape> lineupShapes,
  })  : ops = List.unmodifiable(ops),
        gaps = List.unmodifiable(gaps),
        lineupShapes = List.unmodifiable(lineupShapes);

  final List<StrategyOp> ops;
  final List<OpGap> gaps;
  final List<LineupShape> lineupShapes;
}

final class _Tracked<T> {
  _Tracked(this.row, {required this.revision, required this.sortIndex})
      : live = true;

  _Tracked.deleted(this.row, {required this.revision, required this.sortIndex})
      : live = false;

  T row;
  int revision;
  int sortIndex;
  bool live;
}

final class _Page {
  _Page({
    required this.revision,
    required this.sortIndex,
    required this.name,
    required this.isAutoNamed,
    required this.settingsRevision,
    required this.settings,
  });

  int revision;
  int sortIndex;
  String name;
  bool? isAutoNamed;
  int? settingsRevision;
  PageSettings? settings;
  final elements = <String, _Tracked<LiveElement>>{};
  final groups = <String, _Tracked<LiveLineupGroup>>{};
  var elementsRead = false;

  int nextElementIndex() => 1 + elements.values.fold(-1, _maxSort);

  int nextGroupIndex() => 1 + groups.values.fold(-1, _maxSort);
}

int _maxSort(int highest, _Tracked<Object?> row) =>
    row.sortIndex > highest ? row.sortIndex : highest;

const _uuid = Uuid();

String _opId() => _uuid.v4();

PageItem pageItemOf(ActionObjectState object) => switch (object.kind) {
      ActionObjectKind.agent => AgentItem(object.agent!),
      ActionObjectKind.ability => AbilityItem(object.ability!),
      ActionObjectKind.drawing => DrawingItem(object.drawing!),
      ActionObjectKind.text => TextItem(object.text!),
      ActionObjectKind.image => ImageItem(object.image!),
      ActionObjectKind.utility => UtilityItem(object.utility!),
      ActionObjectKind.lineUp =>
        throw UnsupportedError('a lineup is not an element'),
    };

PageSettings pageSettingsOf(StrategySettings settings) => PageSettings(
      agentSize: settings.agentSize,
      abilitySize: settings.abilitySize,
      useNeutralTeamColors: settings.useNeutralTeamColors,
    );

Map<String, Object?> changedFieldsOnto(
  Map<String, Object?> before,
  Map<String, Object?> after,
  Map<String, Object?> stored,
) {
  final written = {...stored};
  for (final key in {...before.keys, ...after.keys}) {
    if (cloudJsonEquivalent(before[key], after[key])) continue;
    if (after.containsKey(key)) {
      written[key] = after[key];
    } else {
      written.remove(key);
    }
  }
  return written;
}

Set<String> _partIds(LiveLineupGroup group) => {
      for (final part in ['origins', 'landings', 'links'])
        ...idsIn(group.payload.data, part),
    };

Iterable<String> idsIn(JsonObject data, String part) sync* {
  final list = data[part];
  if (list is! Iterable<Object?>) return;
  for (final entry in list) {
    if (entry is! JsonObject) continue;
    if (entry['id'] case final String id) yield id;
  }
}

final class OpsBuilder {
  OpsBuilder._(this._store, this._strategyId, this._headerRevision);

  static Future<OpsBuilder?> read(
    LibraryStore store,
    String strategyId,
  ) async {
    final StrategyContent content;
    switch (await store.readStrategy(strategyId)) {
      case Found(:final value):
        content = value;
      case NotFound() || NotRead() || InUnreadableStrategy():
        return null;
    }
    final header = content.strategy;
    if (header is! ReadableStrategy) return null;
    final builder = OpsBuilder._(store, strategyId, header.revision);
    for (final page in content.pages) {
      if (page is! ReadablePageRow) continue;
      builder._pages[page.publicId] = _Page(
        revision: page.revision,
        sortIndex: page.sortIndex,
        name: switch (page) {
          LivePage(:final name) => name,
          _ => '',
        },
        isAutoNamed: switch (page) {
          LivePage(:final isAutoNamed) => isAutoNamed,
          _ => null,
        },
        settingsRevision: switch (content.settings[page.publicId]) {
          ReadablePageSettings(:final revision) => revision,
          _ => null,
        },
        settings: switch (content.settings[page.publicId]) {
          ReadablePageSettings(:final settings) => settings,
          _ => null,
        },
      )..elementsRead = page is! LivePage;
      if (page is! LivePage) builder._gone.add(page.publicId);
    }
    return builder;
  }

  final LibraryStore _store;
  final String _strategyId;
  int _headerRevision;
  final _pages = <String, _Page>{};
  final _gone = <String>{};
  final _ops = <StrategyOp>[];
  final _gaps = <OpGap>[];
  final _shapes = <LineupShape>[];

  Future<_Page?> _page(String pageId, String change) async {
    final page = _pages[pageId];
    if (page == null || _gone.contains(pageId)) {
      _gaps.add(PageNotInStore(pageId, change));
      return null;
    }
    if (page.elementsRead) return page;
    switch (await _store.readPage(_strategyId, pageId)) {
      case Found(value: final content):
        for (final row in content.elements) {
          switch (row) {
            case LiveElement():
              page.elements[row.publicId] = _Tracked(
                row,
                revision: row.revision,
                sortIndex: row.sortIndex,
              );
            case DeletedElement(
                :final publicId,
                :final pagePublicId,
                :final payload,
                :final sortIndex,
                :final revision,
              ):
              page.elements[row.publicId] = _Tracked.deleted(
                LiveElement(
                  publicId: publicId,
                  pagePublicId: pagePublicId,
                  payload: payload,
                  sortIndex: sortIndex,
                  revision: revision,
                ),
                revision: revision,
                sortIndex: sortIndex,
              );
            case UnreadableElement():
              break;
          }
        }
        for (final row in content.lineupGroups) {
          switch (row) {
            case LiveLineupGroup():
              page.groups[row.publicId] = _Tracked(
                row,
                revision: row.revision,
                sortIndex: row.sortIndex,
              );
            case DeletedLineupGroup(
                :final publicId,
                :final strategyPublicId,
                :final pagePublicId,
                :final payload,
                :final sortIndex,
                :final revision,
              ):
              page.groups[row.publicId] = _Tracked.deleted(
                LiveLineupGroup(
                  publicId: publicId,
                  strategyPublicId: strategyPublicId,
                  pagePublicId: pagePublicId,
                  payload: payload,
                  sortIndex: sortIndex,
                  revision: revision,
                ),
                revision: revision,
                sortIndex: sortIndex,
              );
            case UnreadableLineupGroup():
              break;
          }
        }
        page.elementsRead = true;
        return page;
      case final other:
        _gaps.add(PageNotRead(pageId, '$other'));
        return null;
    }
  }

  Future<BuiltOps> build(List<CanvasChange> changes) async {
    for (final change in changes) {
      await _add(change);
    }
    return BuiltOps(ops: _ops, gaps: _gaps, lineupShapes: _shapes);
  }

  Future<void> _add(CanvasChange change) async {
    switch (change) {
      case ObjectAdded(:final pageId, :final object):
        if (await _page(pageId, 'added') case final page?) {
          _objectAdded(page, pageId, object);
        }
      case ObjectRemoved(:final pageId, :final object):
        if (await _page(pageId, 'removed') case final page?) {
          _objectRemoved(page, pageId, object);
        }
      case ObjectChanged(:final pageId, :final before, :final after):
        if (await _page(pageId, 'changed') case final page?) {
          _objectChanged(page, before, after);
        }
      case ObjectRaised(:final pageId, :final kind, :final id):
        if (await _page(pageId, 'raised') case final page?) {
          _objectRaised(page, kind, id);
        }
      case StrategyFieldsChanged(:final name, :final map, :final theme):
        _ops.add(StrategyPatchOp(
          opId: _opId(),
          expectedStrategyRevision: _headerRevision,
          name: name,
          mapData: map == null ? null : Maps.mapNames[map],
          themeProfile: switch (theme) {
            null => const KeepValue(),
            StrategyThemeChoice(profileId: final id?) => SetValue(id),
            StrategyThemeChoice() => const ClearValue(),
          },
          themeOverridePalette: switch (theme) {
            null => const KeepValue(),
            StrategyThemeChoice(overridePalette: final palette?) =>
              SetValue(themePaletteOf(palette)),
            StrategyThemeChoice() => const ClearValue(),
          },
        ));
        _headerRevision++;
      case LineupsChanged(:final pageId, :final removed, :final added):
        if (await _page(pageId, 'lineups') case final page?) {
          _lineupsChanged(page, pageId, removed, added);
        }
      case LineupFieldChanged(
          :final pageId,
          :final field,
          :final targetId,
          :final after,
        ):
        if (await _page(pageId, 'lineup part') case final page?) {
          _lineupPartEdited(
            page,
            pageId,
            targetId,
            (graph) => lineupsWithField(graph, field, targetId, after),
          );
        }
      case LineupWeaponChanged(:final pageId, :final originId, :final after):
        if (await _page(pageId, 'lineup weapon') case final page?) {
          _lineupPartEdited(
            page,
            pageId,
            originId,
            (graph) => lineupsWithWeapon(graph, originId, after),
          );
        }
      case PageSettingsChanged(:final pageId, :final before, :final after):
        _settingsChanged(pageId, before, after);
      case PageAdded(:final page, :final index, :final copyOf):
        _pageAdded(page, index: index, copyOf: copyOf);
      case PageRenamed(:final pageId, :final name, :final isAutoNamed):
        if (_livePage(pageId, 'renamed') case final page?) {
          _ops.add(PagePatchOp(
            opId: _opId(),
            pagePublicId: pageId,
            name: name,
            isAutoNamed: isAutoNamed,
            expectedPageRevision: page.revision,
          ));
          page
            ..revision += 1
            ..name = name
            ..isAutoNamed = isAutoNamed;
        }
      case PageSideSet(:final pageId, :final isAttack):
        if (_livePage(pageId, 'side') case final page?) {
          _ops.add(PagePatchOp(
            opId: _opId(),
            pagePublicId: pageId,
            isAttack: isAttack,
            expectedPageRevision: page.revision,
          ));
          page.revision++;
        }
      case PageRemoved(:final pageId):
        if (_livePage(pageId, 'removed') != null) {
          _ops.add(PageDeleteOp(
            opId: _opId(),
            pagePublicId: pageId,
            expectedStrategyRevision: _headerRevision,
          ));
          _headerRevision++;
          _gone.add(pageId);
          _placePages(_livePageOrder());
        }
      case PageMoved(:final pageId, :final index):
        if (_livePage(pageId, 'moved') != null) {
          _ops.add(PageReorderOp(
            opId: _opId(),
            pagePublicId: pageId,
            sortIndex: index,
            expectedStrategyRevision: _headerRevision,
          ));
          _headerRevision++;
          final order = _livePageOrder()..remove(pageId);
          order.insert(index.clamp(0, order.length), pageId);
          _placePages(order);
        }
    }
  }

  List<String> _livePageOrder() => [
        for (final MapEntry(key: id) in _pages.entries.toList()
          ..sort((a, b) => a.value.sortIndex != b.value.sortIndex
              ? a.value.sortIndex - b.value.sortIndex
              : a.key.compareTo(b.key)))
          if (!_gone.contains(id)) id,
      ];

  void _placePages(List<String> order, {String? except}) {
    for (final (index, id) in order.indexed) {
      if (id == except) continue;
      final page = _pages[id]!;
      final name = page.isAutoNamed == true ? 'Page ${index + 1}' : page.name;
      if (page.sortIndex == index && page.name == name) continue;
      page
        ..sortIndex = index
        ..name = name
        ..revision += 1;
    }
  }

  _Page? _livePage(String pageId, String change) {
    final page = _pages[pageId];
    if (page == null || _gone.contains(pageId)) {
      _gaps.add(PageNotInStore(pageId, change));
      return null;
    }
    return page;
  }

  ElementPayload? _payloadOf(ActionObjectState object) {
    switch (pageItemOf(object).payload) {
      case Read(value: final payload):
        return payload;
      case CouldNotRead(:final problem):
        _gaps.add(ObjectNotEncoded(object.kind, object.id, problem));
        return null;
    }
  }

  void _objectAdded(_Page page, String pageId, ActionObjectState object) {
    final payload = _payloadOf(object);
    if (payload == null) return;
    final existing = page.elements[object.id];
    if (existing != null && existing.live) {
      _gaps.add(ObjectAlreadyInStore(object.kind, object.id));
      return;
    }
    final sortIndex = page.nextElementIndex();
    _ops.add(ElementAddOp(
      opId: _opId(),
      elementPublicId: object.id,
      pagePublicId: pageId,
      payload: payload,
      sortIndex: sortIndex,
      expectedElementRevision: existing?.revision,
    ));
    final revision = existing == null ? 1 : existing.revision + 1;
    page.elements[object.id] = _Tracked(
      LiveElement(
        publicId: object.id,
        pagePublicId: pageId,
        payload: payload,
        sortIndex: sortIndex,
        revision: revision,
      ),
      revision: revision,
      sortIndex: sortIndex,
    );
  }

  void _objectRemoved(_Page page, String pageId, ActionObjectState object) {
    final existing = page.elements[object.id];
    if (existing == null || !existing.live) {
      _gaps.add(ObjectNotInStore(object.kind, object.id, 'removed'));
      return;
    }
    _ops.add(ElementDeleteOp(
      opId: _opId(),
      elementPublicId: object.id,
      pagePublicId: pageId,
      expectedElementRevision: existing.revision,
    ));
    existing
      ..live = false
      ..revision += 1;
  }

  void _objectRaised(_Page page, ActionObjectKind kind, String id) {
    final existing = page.elements[id];
    if (existing == null || !existing.live) {
      _gaps.add(ObjectNotInStore(kind, id, 'raised'));
      return;
    }
    final base = existing.row;
    final aboveIt = page.elements.values.any((other) =>
        other.live &&
        other.row.payload.kind == base.payload.kind &&
        other.sortIndex > existing.sortIndex);
    if (!aboveIt) return;
    final number = page.nextElementIndex();
    _ops.add(elementEditOp(
      opId: _opId(),
      base: base,
      drawn: DrawnAt(existing.revision),
      payload: base.payload,
      sortIndex: number,
      connection: Connection.live,
    ));
    existing
      ..revision += 1
      ..sortIndex = number
      ..row = LiveElement(
        publicId: base.publicId,
        pagePublicId: base.pagePublicId,
        payload: base.payload,
        sortIndex: number,
        revision: existing.revision,
      );
  }

  void _objectChanged(
    _Page page,
    ActionObjectState before,
    ActionObjectState after,
  ) {
    final existing = page.elements[after.id];
    if (existing == null || !existing.live) {
      _gaps.add(ObjectNotInStore(after.kind, after.id, 'changed'));
      return;
    }
    final from = _payloadOf(before);
    final to = _payloadOf(after);
    if (from == null || to == null) return;
    final base = existing.row;
    final payload = ElementPayload(
      kind: base.payload.kind,
      payloadVersion: from.payloadVersion == to.payloadVersion
          ? base.payload.payloadVersion
          : to.payloadVersion,
      data: changedFieldsOnto(
        from.data.toJson(),
        to.data.toJson(),
        base.payload.data.toJson(),
      ),
      unknownFields: base.payload.unknownFields.toJson(),
    );
    if (base.payload == payload) return;
    _ops.add(elementEditOp(
      opId: _opId(),
      base: base,
      drawn: DrawnAt(existing.revision),
      payload: payload,
      sortIndex: existing.sortIndex,
      connection: Connection.live,
    ));
    existing
      ..revision += 1
      ..row = LiveElement(
        publicId: base.publicId,
        pagePublicId: base.pagePublicId,
        payload: payload,
        sortIndex: existing.sortIndex,
        revision: existing.revision,
      );
  }

  List<LiveLineupGroup> _groupsOf(
    String pageId,
    LineUpGraph graph, {
    Set<String> reserved = const {},
  }) =>
      lineupGroupRowsOf(
        strategyId: _strategyId,
        pageId: pageId,
        graph: graph,
        takenGroupIds: {for (final link in graph.links) link.id, ...reserved},
        everyLinkId: {for (final link in graph.links) link.id},
      );

  void _lineupsChanged(
    _Page page,
    String pageId,
    LineUpGraph removed,
    LineUpGraph added,
  ) {
    final live = [
      for (final tracked in page.groups.values)
        if (tracked.live) tracked,
    ]..sort((a, b) => a.sortIndex != b.sortIndex
        ? a.sortIndex - b.sortIndex
        : a.row.publicId.compareTo(b.row.publicId));
    final before = live.isEmpty
        ? LineUpGraph.empty
        : lineupGraphOfGroups(pageId, [for (final t in live) t.row]);
    if (before == null) {
      _gaps.add(LineupGroupNotInStore(live.first.row.publicId, pageId));
      return;
    }
    final made = _groupsOf(
      pageId,
      lineupsWithParts(before, removed: removed, added: added),
      reserved: {for (final t in live) t.row.publicId},
    );
    final kept = <_Tracked<LiveLineupGroup>>{};
    final placed = <({
      LiveLineupGroup group,
      _Tracked<LiveLineupGroup>? keeps,
      int sortIndex,
    })>[];
    for (final (sortIndex, group) in made.indexed) {
      final links = idsIn(group.payload.data, 'links').toSet();
      final keeps = live
          .where((t) =>
              !kept.contains(t) &&
              idsIn(t.row.payload.data, 'links').any(links.contains))
          .firstOrNull;
      if (keeps != null) kept.add(keeps);
      placed.add((group: group, keeps: keeps, sortIndex: sortIndex));
    }
    final freed = [
      for (final tracked in live)
        if (!kept.contains(tracked)) tracked,
    ];
    final touching = {...lineupPartIds(removed), ...lineupPartIds(added)};
    _shapes.add(
      freed.isEmpty && placed.every((p) => p.keeps != null)
          ? const LineupsInsideGroups()
          : LineupGroupsChanged(
              before: {
                for (final t in live)
                  if (_partIds(t.row).any(touching.contains)) t.row.publicId,
              },
              after: {
                for (final p in placed)
                  if (_partIds(p.group).any(touching.contains))
                    p.keeps?.row.publicId ?? p.group.publicId,
              },
            ),
    );
    for (final tracked in freed) {
      _ops.add(LineupGroupDeleteOp(
        opId: _opId(),
        lineupPublicId: tracked.row.publicId,
        pagePublicId: pageId,
        expectedLineupRevision: tracked.revision,
      ));
      tracked
        ..live = false
        ..revision += 1;
    }
    int phase(
            ({
              LiveLineupGroup group,
              _Tracked<LiveLineupGroup>? keeps,
              int sortIndex
            }) p) =>
        switch (p.keeps) {
          null => 2,
          final keeps when _partIds(keeps.row).containsAll(_partIds(p.group)) =>
            0,
          _ => 1,
        };
    for (final p in [...placed]..sort((a, b) => phase(a) - phase(b))) {
      switch (p.keeps) {
        case final keeps?:
          _patchGroup(
            keeps,
            pageId,
            LineupGroupPayload(
              payloadVersion: lineupGroupPayloadVersion,
              data: {
                ...p.group.payload.data.toJson(),
                'id': keeps.row.publicId
              },
            ),
            sortIndex: p.sortIndex,
          );
        case null:
          _putGroup(page, pageId, p.group, sortIndex: p.sortIndex);
      }
    }
  }

  void _patchGroup(
    _Tracked<LiveLineupGroup> existing,
    String pageId,
    LineupGroupPayload payload, {
    int? sortIndex,
  }) {
    final number = sortIndex ?? existing.sortIndex;
    if (existing.row.payload == payload && existing.sortIndex == number) {
      return;
    }
    _ops.add(lineupEditOp(
      opId: _opId(),
      base: existing.row,
      drawn: BehindWholeWrite(existing.revision),
      payload: payload,
      sortIndex: number,
      connection: Connection.live,
    ));
    existing
      ..revision += 1
      ..sortIndex = number
      ..row = LiveLineupGroup(
        publicId: existing.row.publicId,
        strategyPublicId: _strategyId,
        pagePublicId: pageId,
        payload: payload,
        sortIndex: number,
        revision: existing.revision,
      );
  }

  void _putGroup(
    _Page page,
    String pageId,
    LiveLineupGroup group, {
    int? sortIndex,
  }) {
    final existing = page.groups[group.publicId];
    if (existing != null && existing.live) {
      if (existing.row.payload == group.payload) return;
      _ops.add(lineupEditOp(
        opId: _opId(),
        base: existing.row,
        drawn: BehindWholeWrite(existing.revision),
        payload: group.payload,
        sortIndex: existing.sortIndex,
        connection: Connection.live,
      ));
      existing
        ..revision += 1
        ..row = LiveLineupGroup(
          publicId: group.publicId,
          strategyPublicId: _strategyId,
          pagePublicId: pageId,
          payload: group.payload,
          sortIndex: existing.sortIndex,
          revision: existing.revision,
        );
      return;
    }
    final number = sortIndex ?? page.nextGroupIndex();
    _ops.add(LineupGroupAddOp(
      opId: _opId(),
      lineupPublicId: group.publicId,
      pagePublicId: pageId,
      payload: group.payload,
      sortIndex: number,
      expectedLineupRevision: existing?.revision,
    ));
    final revision = existing == null ? 1 : existing.revision + 1;
    page.groups[group.publicId] = _Tracked(
      LiveLineupGroup(
        publicId: group.publicId,
        strategyPublicId: _strategyId,
        pagePublicId: pageId,
        payload: group.payload,
        sortIndex: number,
        revision: revision,
      ),
      revision: revision,
      sortIndex: number,
    );
  }

  void _lineupPartEdited(
    _Page page,
    String pageId,
    String partId,
    LineUpGraph Function(LineUpGraph graph) edit,
  ) {
    final holding = page.groups.values
        .where((t) => t.live && _partIds(t.row).contains(partId))
        .firstOrNull;
    if (holding == null) {
      _gaps.add(LineupPartNotFound(partId));
      return;
    }
    final graph = lineupGraphOfGroups(pageId, [holding.row]);
    final payload = graph == null
        ? null
        : lineupGroupPayloadOf(edit(graph), holding.row.publicId);
    if (payload == null) {
      _gaps.add(LineupGroupNotInStore(holding.row.publicId, partId));
      return;
    }
    _patchGroup(holding, pageId, payload);
  }

  void _settingsChanged(
    String pageId,
    StrategySettings before,
    StrategySettings after,
  ) {
    final page = _livePage(pageId, 'settings');
    if (page == null) return;
    final revision = page.settingsRevision;
    final stored = page.settings;
    if (revision == null || stored == null) {
      _gaps.add(PageNotInStore(pageId, 'settings row of'));
      return;
    }
    final written = PageSettings(
      agentSize: before.agentSize == after.agentSize
          ? stored.agentSize
          : after.agentSize,
      abilitySize: before.abilitySize == after.abilitySize
          ? stored.abilitySize
          : after.abilitySize,
      useNeutralTeamColors:
          before.useNeutralTeamColors == after.useNeutralTeamColors
              ? stored.useNeutralTeamColors
              : after.useNeutralTeamColors,
    );
    if (written == stored) return;
    _ops.add(PageSettingsPatchOp(
      opId: _opId(),
      pagePublicId: pageId,
      settings: written,
      expectedPageSettingsRevision: revision,
    ));
    page
      ..settingsRevision = revision + 1
      ..settings = written;
  }

  void _pageAdded(StrategyPage page, {required int index, String? copyOf}) {
    _ops.add(PageAddOp(
      opId: _opId(),
      pagePublicId: page.id,
      name: page.name,
      isAutoNamed: page.isAutoNamed,
      isAttack: page.isAttack,
      settings: pageSettingsOf(page.settings),
      sortIndex: index,
      expectedStrategyRevision: _headerRevision,
      copyContentFromPagePublicId: copyOf,
    ));
    _headerRevision++;
    final order = _livePageOrder()..remove(page.id);
    final placedAt = index.clamp(0, order.length);
    order.insert(placedAt, page.id);
    final added = _Page(
      revision: 1,
      sortIndex: placedAt,
      name: page.name,
      isAutoNamed: page.isAutoNamed,
      settingsRevision: 1,
      settings: pageSettingsOf(page.settings),
    )..elementsRead = copyOf == null;
    _pages[page.id] = added;
    _gone.remove(page.id);
    _placePages(order, except: page.id);
    if (copyOf != null) return;
    for (final item in pageItemsOf(page)) {
      switch (item.payload) {
        case Read(value: final payload):
          final index = added.nextElementIndex();
          _ops.add(ElementAddOp(
            opId: _opId(),
            elementPublicId: item.id,
            pagePublicId: page.id,
            payload: payload,
            sortIndex: index,
          ));
          added.elements[item.id] = _Tracked(
            LiveElement(
              publicId: item.id,
              pagePublicId: page.id,
              payload: payload,
              sortIndex: index,
              revision: 1,
            ),
            revision: 1,
            sortIndex: index,
          );
        case CouldNotRead(:final problem):
          _gaps.add(ObjectNotEncoded(
            ActionObjectKind.values.byName(item.kind.name),
            item.id,
            problem,
          ));
      }
    }
    for (final group in _groupsOf(page.id, page.lineUpGraph)) {
      _putGroup(added, page.id, group);
    }
  }
}
