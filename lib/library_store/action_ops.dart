import 'package:icarus/const/line_provider.dart';
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
    required this.settingsRevision,
  });

  int revision;
  int sortIndex;
  int? settingsRevision;
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
        settingsRevision: switch (content.settings[page.publicId]) {
          ReadablePageSettings(:final revision) => revision,
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
      case ObjectChanged(:final pageId, :final after):
        if (await _page(pageId, 'changed') case final page?) {
          _objectChanged(page, after);
        }
      case LineupsChanged(:final pageId, :final before, :final after):
        if (await _page(pageId, 'lineups') case final page?) {
          _lineupsChanged(page, pageId, before, after);
        }
      case LineupPartChanged(:final pageId, :final partId, :final graph):
        if (await _page(pageId, 'lineup part') case final page?) {
          _lineupPartChanged(page, pageId, partId, graph);
        }
      case PageSettingsChanged(:final pageId, :final settings):
        _settingsChanged(pageId, settings);
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
          page.revision++;
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
        }
      case PageMoved(:final pageId, :final index):
        if (_livePage(pageId, 'moved') case final page?) {
          _ops.add(PageReorderOp(
            opId: _opId(),
            pagePublicId: pageId,
            sortIndex: index,
            expectedStrategyRevision: _headerRevision,
          ));
          _headerRevision++;
          page.sortIndex = index;
        }
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

  void _objectChanged(_Page page, ActionObjectState after) {
    final existing = page.elements[after.id];
    if (existing == null || !existing.live) {
      _gaps.add(ObjectNotInStore(after.kind, after.id, 'changed'));
      return;
    }
    final payload = _payloadOf(after);
    if (payload == null) return;
    final base = existing.row;
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

  List<LiveLineupGroup> _groupsOf(String pageId, LineUpGraph graph,
          {required Set<String> links}) =>
      lineupGroupRowsOf(
        strategyId: _strategyId,
        pageId: pageId,
        graph: graph,
        takenGroupIds: {},
        everyLinkId: links,
      );

  void _lineupsChanged(
    _Page page,
    String pageId,
    LineUpGraph before,
    LineUpGraph after,
  ) {
    final links = {
      for (final link in [...before.links, ...after.links]) link.id,
    };
    final groupsBefore = {
      for (final group in _groupsOf(pageId, before, links: links))
        group.publicId: group,
    };
    final groupsAfter = {
      for (final group in _groupsOf(pageId, after, links: links))
        group.publicId: group,
    };
    _shapes.add(
      groupsBefore.keys.toSet().containsAll(groupsAfter.keys) &&
              groupsAfter.keys.toSet().containsAll(groupsBefore.keys)
          ? const LineupsInsideGroups()
          : LineupGroupsChanged(
              before: groupsBefore.keys.toSet(),
              after: groupsAfter.keys.toSet(),
            ),
    );
    for (final id in groupsBefore.keys) {
      if (groupsAfter.containsKey(id)) continue;
      final existing = page.groups[id];
      if (existing == null || !existing.live) {
        _gaps.add(LineupGroupNotInStore(id, id));
        continue;
      }
      _ops.add(LineupGroupDeleteOp(
        opId: _opId(),
        lineupPublicId: id,
        pagePublicId: pageId,
        expectedLineupRevision: existing.revision,
      ));
      existing
        ..live = false
        ..revision += 1;
    }
    final changed = [
      for (final group in groupsAfter.values)
        if (groupsBefore[group.publicId]?.payload != group.payload) group,
    ];
    int phase(LiveLineupGroup group) => switch (page.groups[group.publicId]) {
          _Tracked(live: true, :final row)
              when _partIds(row).containsAll(_partIds(group)) =>
            0,
          _Tracked(live: true) => 1,
          _ => 2,
        };
    for (final group in [...changed]..sort((a, b) => phase(a) - phase(b))) {
      _putGroup(page, pageId, group);
    }
  }

  void _putGroup(_Page page, String pageId, LiveLineupGroup group) {
    final existing = page.groups[group.publicId];
    if (existing != null && existing.live) {
      if (existing.row.payload == group.payload) return;
      _ops.add(lineupEditOp(
        opId: _opId(),
        base: existing.row,
        drawn: DrawnAt(existing.revision),
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
    final sortIndex = page.nextGroupIndex();
    _ops.add(LineupGroupAddOp(
      opId: _opId(),
      lineupPublicId: group.publicId,
      pagePublicId: pageId,
      payload: group.payload,
      sortIndex: sortIndex,
      expectedLineupRevision: existing?.revision,
    ));
    final revision = existing == null ? 1 : existing.revision + 1;
    page.groups[group.publicId] = _Tracked(
      LiveLineupGroup(
        publicId: group.publicId,
        strategyPublicId: _strategyId,
        pagePublicId: pageId,
        payload: group.payload,
        sortIndex: sortIndex,
        revision: revision,
      ),
      revision: revision,
      sortIndex: sortIndex,
    );
  }

  void _lineupPartChanged(
    _Page page,
    String pageId,
    String partId,
    LineUpGraph graph,
  ) {
    final groups = _groupsOf(
      pageId,
      graph,
      links: {for (final link in graph.links) link.id},
    );
    final holding = [
      for (final group in groups)
        if (_partIds(group).contains(partId)) group,
    ];
    if (holding.isEmpty) {
      _gaps.add(LineupPartNotFound(partId));
      return;
    }
    for (final group in holding) {
      final existing = page.groups[group.publicId];
      if (existing == null || !existing.live) {
        _gaps.add(LineupGroupNotInStore(group.publicId, partId));
        continue;
      }
      _putGroup(page, pageId, group);
    }
  }

  void _settingsChanged(String pageId, StrategySettings settings) {
    final page = _livePage(pageId, 'settings');
    if (page == null) return;
    final revision = page.settingsRevision;
    if (revision == null) {
      _gaps.add(PageNotInStore(pageId, 'settings row of'));
      return;
    }
    _ops.add(PageSettingsPatchOp(
      opId: _opId(),
      pagePublicId: pageId,
      settings: pageSettingsOf(settings),
      expectedPageSettingsRevision: revision,
    ));
    page.settingsRevision = revision + 1;
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
    final added = _Page(revision: 1, sortIndex: index, settingsRevision: 1)
      ..elementsRead = copyOf == null;
    _pages[page.id] = added;
    _gone.remove(page.id);
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
    for (final group in _groupsOf(
      page.id,
      page.lineUpGraph,
      links: {for (final link in page.lineUpLinks) link.id},
    )) {
      _putGroup(added, page.id, group);
    }
  }
}
