import 'dart:convert';

import 'derived_id.dart';
import 'field_rules.dart';
import 'json.dart';
import 'ops.dart';
import 'payloads.dart';
import 'rows.dart';
import 'strategy_rows.dart';

sealed class StrategyDiff {
  const StrategyDiff();
}

final class DiffOps extends StrategyDiff {
  DiffOps(List<StrategyOp> ops) : ops = List.unmodifiable(ops);

  final List<StrategyOp> ops;
}

final class DiffRefused extends StrategyDiff {
  const DiffRefused(this.refusal);

  final DiffRefusal refusal;
}

sealed class DiffRefusal {
  const DiffRefusal();
}

final class RowNotReadable extends DiffRefusal {
  const RowNotReadable(this.key);

  final RowKey key;
}

final class RowInTrash extends DiffRefusal {
  const RowInTrash(this.key);

  final RowKey key;
}

final class FieldNotClearable extends DiffRefusal {
  const FieldNotClearable(this.key, this.field);

  final RowKey key;
  final String field;
}

final class KindChanged extends DiffRefusal {
  const KindChanged(this.key);

  final RowKey key;
}

final class FolderChanged extends DiffRefusal {
  const FolderChanged();
}

final class LastPageRemoved extends DiffRefusal {
  const LastPageRemoved();
}

StrategyDiff diffStrategy(
  StrategyRowSet stored,
  StrategyRowSet target, {
  required String editId,
}) {
  final plan = _Plan(stored, target);
  return switch (plan.refusals().take(1).toList()) {
    [final refusal] => DiffRefused(refusal),
    _ => DiffOps(_Ops(plan, editId).build()),
  };
}

int _byPlace((int, String) a, (int, String) b) =>
    switch (a.$1.compareTo(b.$1)) {
      0 => a.$2.compareTo(b.$2),
      final order => order,
    };

List<LivePage> _livePagesInOrder(StrategyRowSet rows) =>
    rows.pages.whereType<LivePage>().toList()..sort(
      (a, b) => _byPlace((a.sortIndex, a.publicId), (b.sortIndex, b.publicId)),
    );

bool _isUnreadable(Row row) =>
    row is UnreadablePage ||
    row is UnreadablePageSettings ||
    row is UnreadableElement ||
    row is UnreadableLineupGroup;

String _idOf(Row row) => row.key.id;

sealed class _Payload {
  const _Payload();
}

final class _Written extends _Payload {
  const _Written(this.payload);

  final ElementPayload payload;
}

final class _NotClearable extends _Payload {
  const _NotClearable(this.field);

  final String field;
}

_Payload _clearing(ElementPayload stored, ElementPayload wanted) {
  final data = wanted.data.toMap();
  if (stored.data[pictureIdField] is String &&
      !data.containsKey(pictureIdField)) {
    return const _NotClearable(pictureIdField);
  }
  for (final later in laterElementFields) {
    if (!later.kinds.contains(wanted.kind) ||
        !stored.data.containsKey(later.field) ||
        data.containsKey(later.field)) {
      continue;
    }
    switch (later.empty) {
      case ClearedBy(:final value):
        data[later.field] = value;
      case NeverCleared():
        return _NotClearable(later.field);
    }
  }
  return _Written(
    data.length == wanted.data.length ? wanted : wanted.withData(data),
  );
}

final class _Plan {
  _Plan(this.stored, this.target)
    : storedPages = _livePagesInOrder(stored),
      targetPages = _livePagesInOrder(target);

  final StrategyRowSet stored;
  final StrategyRowSet target;
  final List<LivePage> storedPages;
  final List<LivePage> targetPages;

  late final Map<String, _Payload> payloads = {
    for (final element in target.elements.whereType<LiveElement>())
      if (stored.element(element.publicId) case final before?)
        if (before case ReadableElementRow(
          :final payload,
        ) when before is DeletedElement || payload.kind == element.payload.kind)
          element.publicId: _clearing(payload, element.payload),
  };

  late final Set<String> targetPageIds = {
    for (final page in targetPages) page.publicId,
  };

  late final List<LivePage> addedPages = [
    for (final page in targetPages)
      if (stored.page(page.publicId) == null) page,
  ];

  late final List<LivePage> removedPages = [
    for (final page in storedPages)
      if (!targetPageIds.contains(page.publicId)) page,
  ];

  bool get changesPageList =>
      addedPages.isNotEmpty ||
      removedPages.isNotEmpty ||
      !_sameOrder(
        [for (final page in storedPages) page.publicId],
        [
          for (final page in targetPages)
            if (stored.page(page.publicId) is LivePage) page.publicId,
        ],
      );

  static bool _sameOrder(List<String> a, List<String> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) i].every((i) => a[i] == b[i]);

  bool onTrashedPage(Row row) => switch (row) {
    ElementRow(:final pagePublicId) ||
    LineupGroupRow(:final pagePublicId) => switch (stored.page(pagePublicId)) {
      LivePage() || UnreadablePage(trashed: false) => false,
      _ => true,
    },
    _ => false,
  };

  Iterable<DiffRefusal> refusals() sync* {
    if (stored.strategy.folderPublicId != target.strategy.folderPublicId) {
      yield const FolderChanged();
    }
    if (targetPages.isEmpty && storedPages.isNotEmpty) {
      yield const LastPageRemoved();
    }
    yield* _carried(stored.pages, target.page, target.pages);
    yield* _carried(stored.settings, target.settingsOf, target.settings);
    yield* _carried(stored.elements, target.element, target.elements);
    yield* _carried(
      stored.lineupGroups,
      target.lineupGroup,
      target.lineupGroups,
    );
    if (changesPageList) {
      for (final page in stored.pages) {
        if (page case UnreadablePage(trashed: false)) {
          yield RowNotReadable(page.key);
        }
      }
    }
    yield* _pageRefusals();
    yield* _elementRefusals();
    yield* _lineupRefusals();
  }

  Iterable<DiffRefusal> _carried<R extends Row>(
    Iterable<R> storedRows,
    R? Function(String id) targetRow,
    Iterable<R> targetRows,
  ) sync* {
    for (final row in storedRows.where(_isUnreadable)) {
      final wanted = targetRow(_idOf(row));
      if (wanted != null && wanted != row) yield RowNotReadable(row.key);
    }
    final storedById = {for (final row in storedRows) _idOf(row): row};
    for (final row in targetRows.where(_isUnreadable)) {
      if (storedById[_idOf(row)] != row) yield RowNotReadable(row.key);
    }
  }

  Iterable<DiffRefusal> _pageRefusals() sync* {
    for (final page in targetPages) {
      switch (stored.page(page.publicId)) {
        case TrashedPage(:final key):
          yield RowInTrash(key);
        case LivePage(isAutoNamed: _?) when page.isAutoNamed == null:
          yield FieldNotClearable(page.key, 'isAutoNamed');
        case _:
          break;
      }
      if ((stored.settingsOf(page.publicId), target.settingsOf(page.publicId))
          case (
            ReadablePageSettings(settings: _?),
            ReadablePageSettings(settings: null, :final key),
          ) when stored.page(page.publicId) is LivePage) {
        yield FieldNotClearable(key, 'settings');
      }
    }
  }

  Iterable<DiffRefusal> _elementRefusals() sync* {
    for (final element in target.elements.whereType<LiveElement>()) {
      switch (stored.element(element.publicId)) {
        case null || UnreadableElement():
          break;
        case final ReadableElementRow before when onTrashedPage(before):
          yield RowInTrash(before.key);
        case LiveElement(:final payload)
            when payload.kind != element.payload.kind:
          yield KindChanged(element.key);
        case ReadableElementRow():
          if (payloads[element.publicId] case _NotClearable(:final field)) {
            yield FieldNotClearable(element.key, field);
          }
      }
    }
  }

  Iterable<DiffRefusal> _lineupRefusals() sync* {
    for (final group in target.lineupGroups.whereType<LiveLineupGroup>()) {
      final before = stored.lineupGroup(group.publicId);
      if (before case final LiveLineupGroup live
          when onTrashedPage(live) && !_sameGroup(live, group)) {
        yield RowInTrash(live.key);
      } else if (before case DeletedLineupGroup() when onTrashedPage(before)) {
        yield RowInTrash(before.key);
      }
    }
  }
}

final class _Ops {
  _Ops(this.plan, this.editId)
    : _strategyRevision = plan.stored.strategy.revision;

  final _Plan plan;
  final String editId;
  final _ops = <StrategyOp>[];
  int _strategyRevision;
  late final List<_Page> _pages = [
    for (final page in plan.storedPages) _Page.stored(page),
  ];

  StrategyRowSet get stored => plan.stored;

  StrategyRowSet get target => plan.target;

  String get _opId => derivedId(jsonEncode([editId, _ops.length]));

  List<StrategyOp> build() {
    _patchStrategy();
    plan.addedPages.forEach(_addPage);
    _elements();
    _lineupGroups();
    plan.removedPages.forEach(_deletePage);
    if (plan.changesPageList) _reorder();
    for (final page in plan.targetPages) {
      _patchPage(page);
      _patchSettings(page);
    }
    return _ops;
  }

  void _raiseStrategy(StrategyOp op) {
    _ops.add(op);
    _strategyRevision++;
  }

  void _patchStrategy() {
    final before = stored.strategy;
    final after = target.strategy;
    final op = StrategyPatchOp(
      opId: _opId,
      expectedStrategyRevision: _strategyRevision,
      name: before.name == after.name ? null : after.name,
      mapData: before.mapData == after.mapData ? null : after.mapData,
      themeProfile: _valueEdit(before.themeProfileId, after.themeProfileId),
      themeOverridePalette: _valueEdit(
        before.themeOverridePalette,
        after.themeOverridePalette,
      ),
    );
    if (op.name != null ||
        op.mapData != null ||
        op.themeProfile is! KeepValue ||
        op.themeOverridePalette is! KeepValue) {
      _raiseStrategy(op);
    }
  }

  static ValueEdit<T> _valueEdit<T extends Object>(T? before, T? after) =>
      switch (after) {
        _ when before == after => KeepValue<T>(),
        null => ClearValue<T>(),
        final value => SetValue<T>(value),
      };

  void _place(List<_Page> order) {
    for (final (index, page) in order.indexed) {
      page.place(index);
    }
    _pages
      ..clear()
      ..addAll(order);
  }

  void _addPage(LivePage page) {
    final sortIndex = _pages.length;
    _raiseStrategy(
      PageAddOp(
        opId: _opId,
        pagePublicId: page.publicId,
        name: page.name,
        isAutoNamed: page.isAutoNamed,
        isAttack: page.isAttack,
        settings: switch (target.settingsOf(page.publicId)) {
          ReadablePageSettings(:final settings) => settings,
          UnreadablePageSettings() || null => null,
        },
        sortIndex: sortIndex,
        expectedStrategyRevision: _strategyRevision,
      ),
    );
    _place([..._pages]);
    _pages.add(_Page.added(page, sortIndex));
  }

  void _deletePage(LivePage page) {
    _raiseStrategy(
      PageDeleteOp(
        opId: _opId,
        pagePublicId: page.publicId,
        expectedStrategyRevision: _strategyRevision,
      ),
    );
    _place([
      for (final kept in _pages)
        if (kept.publicId != page.publicId) kept,
    ]);
  }

  void _reorder() {
    final byId = {for (final page in _pages) page.publicId: page};
    for (final (index, wanted) in plan.targetPages.indexed) {
      final page = byId[wanted.publicId]!;
      final current = _pages.indexOf(page);
      if (current == index) continue;
      _raiseStrategy(
        PageReorderOp(
          opId: _opId,
          pagePublicId: page.publicId,
          sortIndex: index,
          expectedStrategyRevision: _strategyRevision,
        ),
      );
      _place(
        [..._pages]
          ..removeAt(current)
          ..insert(index, page),
      );
    }
  }

  void _patchPage(LivePage wanted) {
    final page = _pages.firstWhere((page) => page.publicId == wanted.publicId);
    final name = page.name == wanted.name ? null : wanted.name;
    final isAutoNamed = page.isAutoNamed == wanted.isAutoNamed
        ? null
        : wanted.isAutoNamed;
    final isAttack = page.isAttack == wanted.isAttack ? null : wanted.isAttack;
    if (name == null && isAutoNamed == null && isAttack == null) return;
    _ops.add(
      PagePatchOp(
        opId: _opId,
        pagePublicId: wanted.publicId,
        expectedPageRevision: page.revision,
        name: name,
        isAutoNamed: isAutoNamed,
        isAttack: isAttack,
      ),
    );
  }

  void _patchSettings(LivePage page) {
    if (stored.page(page.publicId) is! LivePage) return;
    if ((stored.settingsOf(page.publicId), target.settingsOf(page.publicId))
        case (
          ReadablePageSettings(:final settings, :final revision),
          ReadablePageSettings(settings: final wanted?),
        ) when settings != wanted) {
      _ops.add(
        PageSettingsPatchOp(
          opId: _opId,
          pagePublicId: page.publicId,
          settings: wanted,
          expectedPageSettingsRevision: revision,
        ),
      );
    }
  }

  void _elements() {
    final wantedIds = <String>{};
    for (final element in target.elements.whereType<LiveElement>()) {
      wantedIds.add(element.publicId);
      final payload = switch (plan.payloads[element.publicId]) {
        _Written(:final payload) => payload,
        _NotClearable() || null => element.payload,
      };
      switch (stored.element(element.publicId)) {
        case null:
          _ops.add(
            ElementAddOp(
              opId: _opId,
              elementPublicId: element.publicId,
              pagePublicId: element.pagePublicId,
              payload: payload,
              sortIndex: element.sortIndex,
            ),
          );
        case DeletedElement(:final revision):
          _ops.add(
            ElementAddOp(
              opId: _opId,
              elementPublicId: element.publicId,
              pagePublicId: element.pagePublicId,
              payload: payload,
              sortIndex: element.sortIndex,
              expectedElementRevision: revision,
            ),
          );
        case final LiveElement before:
          final moved = before.pagePublicId != element.pagePublicId;
          if (_samePayload(payload, before.payload) &&
              !moved &&
              before.sortIndex == element.sortIndex) {
            continue;
          }
          _ops.add(
            ElementPatchOp(
              opId: _opId,
              elementPublicId: element.publicId,
              pagePublicId: moved ? element.pagePublicId : null,
              payload: payload,
              sortIndex: element.sortIndex,
              expectedElementRevision: before.revision,
            ),
          );
        case UnreadableElement():
          break;
      }
    }
    for (final element in stored.elements.whereType<LiveElement>()) {
      if (wantedIds.contains(element.publicId) || plan.onTrashedPage(element)) {
        continue;
      }
      _ops.add(
        ElementDeleteOp(
          opId: _opId,
          elementPublicId: element.publicId,
          pagePublicId: element.pagePublicId,
          expectedElementRevision: element.revision,
        ),
      );
    }
  }

  void _lineupGroups() {
    final wanted = {
      for (final group in target.lineupGroups.whereType<LiveLineupGroup>())
        group.publicId: group,
    };
    final deletedAt = <String, int>{};
    for (final group in stored.lineupGroups) {
      switch (group) {
        case DeletedLineupGroup(:final publicId, :final revision):
          deletedAt[publicId] = revision;
        case LiveLineupGroup() when _sameGroup(group, wanted[group.publicId]):
          wanted.remove(group.publicId);
        case LiveLineupGroup() when plan.onTrashedPage(group):
          break;
        case LiveLineupGroup(:final publicId, :final revision):
          _ops.add(
            LineupGroupDeleteOp(
              opId: _opId,
              lineupPublicId: publicId,
              pagePublicId: group.pagePublicId,
              expectedLineupRevision: revision,
            ),
          );
          deletedAt[publicId] = revision + 1;
        case UnreadableLineupGroup():
          break;
      }
    }
    for (final group in wanted.values) {
      _ops.add(
        LineupGroupAddOp(
          opId: _opId,
          lineupPublicId: group.publicId,
          pagePublicId: group.pagePublicId,
          payload: group.payload,
          sortIndex: group.sortIndex,
          expectedLineupRevision: deletedAt[group.publicId],
        ),
      );
    }
  }
}

bool _samePayload(ElementPayload a, ElementPayload b) =>
    a.kind == b.kind &&
    a.payloadVersion == b.payloadVersion &&
    sameJsonTree(a.data, b.data) &&
    sameJsonTree(a.unknownFields, b.unknownFields);

bool _sameGroup(LiveLineupGroup stored, LiveLineupGroup? wanted) =>
    wanted != null &&
    wanted.pagePublicId == stored.pagePublicId &&
    wanted.sortIndex == stored.sortIndex &&
    wanted.payload.payloadVersion == stored.payload.payloadVersion &&
    sameJsonTree(wanted.payload.data, stored.payload.data) &&
    sameJsonTree(wanted.payload.unknownFields, stored.payload.unknownFields);

final class _Page {
  _Page.stored(LivePage page)
    : publicId = page.publicId,
      name = page.name,
      isAutoNamed = page.isAutoNamed,
      isAttack = page.isAttack,
      sortIndex = page.sortIndex,
      revision = page.revision;

  _Page.added(LivePage page, this.sortIndex)
    : publicId = page.publicId,
      name = page.name,
      isAutoNamed = page.isAutoNamed,
      isAttack = page.isAttack,
      revision = 1;

  final String publicId;
  String name;
  final bool? isAutoNamed;
  final bool isAttack;
  int sortIndex;
  int revision;

  void place(int index) {
    final placedName = isAutoNamed == true ? 'Page ${index + 1}' : name;
    if (sortIndex == index && name == placedName) return;
    sortIndex = index;
    name = placedName;
    revision++;
  }
}
