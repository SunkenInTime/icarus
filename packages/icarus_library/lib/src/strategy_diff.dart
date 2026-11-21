import 'dart:convert';

import 'derived_id.dart';
import 'field_merge.dart';
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

final class SettingsUnreachable extends DiffRefusal {
  const SettingsUnreachable(this.key);

  final PageKey key;
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
  return switch (plan.refusals()) {
    [final refusal, ...] => DiffRefused(refusal),
    [] => DiffOps(_Ops(plan, editId).build()),
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

Map<String, Object?> _withDefaults(JsonObject data) =>
    withFieldDefaults(data)! as Map<String, Object?>;

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

List<String> _changedFields(ElementPayload stored, ElementPayload wanted) {
  if (sameJsonTree(stored.data, wanted.data)) return const [];
  final before = _withDefaults(stored.data);
  final after = _withDefaults(wanted.data);
  return groupedFields(wanted.kind, before, after, {
    for (final key in after.keys)
      if (!sameJson(before[key], after[key])) key,
  });
}

LineupGroupPayload _keepingItemFields(
  LineupGroupPayload stored,
  LineupGroupPayload wanted,
) {
  final data = wanted.data.toJson();
  for (final collection in lineupCollections) {
    final kept = {
      for (final item in lineupItems(stored.data.toJson(), collection))
        item['id']: item,
    };
    if (data[collection] case final List<Object?> items) {
      data[collection] = [
        for (final item in items)
          if (item case final Map<String, Object?> map
              when kept[map['id']] != null)
            {...kept[map['id']]!, ...map}
          else
            item,
      ];
    }
  }
  return LineupGroupPayload(
    payloadVersion: wanted.payloadVersion,
    data: data,
    unknownFields: wanted.unknownFields.toMap(),
  );
}

Set<String> _itemIds(LineupGroupPayload payload) => {
  for (final collection in lineupCollections)
    for (final item in lineupItems(payload.data.toJson(), collection))
      if (item['id'] case final String id) '$collection/$id',
};

typedef _MakeOp = StrategyOp Function(String opId);

final class _Planned {
  final _made = <(String, _MakeOp)>[];

  void add(String rowId, _MakeOp make) => _made.add((rowId, make));

  Iterable<_MakeOp> get inIdOrder =>
      (_made.toList()..sort((a, b) => a.$1.compareTo(b.$1))).map(
        (planned) => planned.$2,
      );
}

bool _sameSettings(PageSettings a, PageSettings b) =>
    a.agentSize == b.agentSize &&
    a.abilitySize == b.abilitySize &&
    a.useNeutralTeamColors == b.useNeutralTeamColors;

PageSettings _settingsKeeping(PageSettings? stored, PageSettings wanted) =>
    PageSettings.keeping(
      agentSize: wanted.agentSize,
      abilitySize: wanted.abilitySize,
      useNeutralTeamColors: wanted.useNeutralTeamColors,
      unknownFields: {
        ...?stored?.unknownFields.toMap(),
        ...wanted.unknownFields.toMap(),
      },
    );

bool _samePalette(ThemePalette? a, ThemePalette? b) => a == null || b == null
    ? a == b
    : a.base == b.base && a.detail == b.detail && a.highlight == b.highlight;

ThemePalette _paletteKeeping(ThemePalette? stored, ThemePalette wanted) =>
    ThemePalette.keeping(
      base: wanted.base,
      detail: wanted.detail,
      highlight: wanted.highlight,
      unknownFields: {
        ...?stored?.unknownFields.toMap(),
        ...wanted.unknownFields.toMap(),
      },
    );

final class _Plan {
  _Plan(this.stored, this.target)
    : storedPages = _livePagesInOrder(stored),
      targetPages = _livePagesInOrder(target);

  final StrategyRowSet stored;
  final StrategyRowSet target;
  final List<LivePage> storedPages;
  final List<LivePage> targetPages;
  final _refusals = <DiffRefusal>[];
  final elementOps = _Planned();
  final groupDeletes = _Planned();
  final groupMovesOut = _Planned();
  final groupAdds = _Planned();
  final groupEdits = _Planned();

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

  late final Set<String> _removedPageIds = {
    for (final page in removedPages) page.publicId,
  };

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

  static String? _pageOf(Row row) => switch (row) {
    ElementRow(:final pagePublicId) ||
    LineupGroupRow(:final pagePublicId) => pagePublicId,
    _ => null,
  };

  bool _inStoredTrash(Row row) => switch (stored.page(_pageOf(row) ?? '')) {
    LivePage() || UnreadablePage(trashed: false) => false,
    _ => true,
  };

  bool _inTargetTrash(Row row) => !targetPageIds.contains(_pageOf(row));

  bool staysWithItsPage(Row row) =>
      _inStoredTrash(row) || _removedPageIds.contains(_pageOf(row));

  List<DiffRefusal> refusals() {
    final found = [..._shapeRefusals()];
    _planElements();
    _planLineupGroups();
    return [...found, ..._refusals];
  }

  Iterable<DiffRefusal> _shapeRefusals() sync* {
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
        if (page case UnreadablePage(:final trashed) when trashed != true) {
          yield RowNotReadable(page.key);
        }
      }
    }
    yield* _pageRefusals();
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
      final before = stored.page(page.publicId);
      switch (before) {
        case TrashedPage(:final key):
          yield RowInTrash(key);
        case LivePage(isAutoNamed: _?) when page.isAutoNamed == null:
          yield FieldNotClearable(page.key, 'isAutoNamed');
        case _:
          break;
      }
      final reachable = switch ((
        before,
        stored.settingsOf(page.publicId),
        target.settingsOf(page.publicId),
      )) {
        (null, _, ReadablePageSettings()) => true,
        (null, _, _) => false,
        (LivePage(), null, null) => true,
        (LivePage(), ReadablePageSettings(settings: null), _) ||
        (
          LivePage(),
          ReadablePageSettings(),
          ReadablePageSettings(settings: _?),
        ) => true,
        (LivePage(), ReadablePageSettings(), _) => false,
        (LivePage(), null, _) => false,
        _ => true,
      };
      if (!reachable) yield SettingsUnreachable(page.key);
    }
  }

  void _planElements() {
    final wanted = target.elements.whereType<LiveElement>().toList();
    final wantedIds = {for (final element in wanted) element.publicId};
    for (final element in wanted) {
      final before = stored.element(element.publicId);
      if (before is UnreadableElement) continue;
      if (_inTargetTrash(element) ||
          (before != null && _inStoredTrash(before))) {
        if (!_sameElement(before, element)) {
          _refusals.add(RowInTrash(element.key));
        }
        continue;
      }
      switch (before) {
        case null:
          elementOps.add(
            element.publicId,
            (opId) => ElementAddOp(
              opId: opId,
              elementPublicId: element.publicId,
              pagePublicId: element.pagePublicId,
              payload: element.payload,
              sortIndex: element.sortIndex,
            ),
          );
        case DeletedElement(:final payload, :final revision):
          switch (_clearing(payload, element.payload)) {
            case _NotClearable(:final field):
              _refusals.add(FieldNotClearable(element.key, field));
            case _Written(payload: final written):
              elementOps.add(
                element.publicId,
                (opId) => ElementAddOp(
                  opId: opId,
                  elementPublicId: element.publicId,
                  pagePublicId: element.pagePublicId,
                  payload: written,
                  sortIndex: element.sortIndex,
                  expectedElementRevision: revision,
                ),
              );
          }
        case final LiveElement live:
          _planElementEdit(live, element);
        case UnreadableElement():
          break;
      }
    }
    for (final element in stored.elements.whereType<LiveElement>()) {
      if (wantedIds.contains(element.publicId) || staysWithItsPage(element)) {
        continue;
      }
      elementOps.add(
        element.publicId,
        (opId) => ElementDeleteOp(
          opId: opId,
          elementPublicId: element.publicId,
          pagePublicId: element.pagePublicId,
          expectedElementRevision: element.revision,
        ),
      );
    }
  }

  void _planElementEdit(LiveElement before, LiveElement wanted) {
    if (_sameElement(before, wanted)) return;
    if (before.payload.kind != wanted.payload.kind) {
      _refusals.add(KindChanged(wanted.key));
      return;
    }
    final ElementPayload desired;
    switch (_clearing(before.payload, wanted.payload)) {
      case _NotClearable(:final field):
        _refusals.add(FieldNotClearable(wanted.key, field));
        return;
      case _Written(:final payload):
        desired = payload;
    }
    final movesPage = before.pagePublicId != wanted.pagePublicId;
    final movesPlace = before.sortIndex != wanted.sortIndex;
    final samePayload = _samePayload(before.payload, desired);
    final whole =
        !samePayload &&
        switch (elementEdit(before.payload, desired)) {
          WholeEdit() => true,
          FieldEdit() => false,
        };
    final fields = whole || samePayload
        ? const <String>[]
        : _changedFields(before.payload, desired);
    if (!whole && fields.isEmpty && !movesPage && !movesPlace) return;
    final merged = switch (fields.isEmpty
        ? Merged(before.payload)
        : mergeElementPayload(
            before.payload,
            desired,
            FieldMerge(fields: fields),
          )) {
      Merged(:final value) when !whole => value,
      _ => null,
    };
    if (merged != null && !movesPage && fields.length < maxMergeFields) {
      elementOps.add(
        wanted.publicId,
        (opId) => ElementPatchOp(
          opId: opId,
          elementPublicId: wanted.publicId,
          payload: fields.isEmpty ? null : desired,
          sortIndex: wanted.sortIndex,
          expectedElementRevision: before.revision,
          merge: FieldMerge(fields: [...fields, if (movesPlace) placeField]),
        ),
      );
      return;
    }
    elementOps.add(
      wanted.publicId,
      (opId) => ElementPatchOp(
        opId: opId,
        elementPublicId: wanted.publicId,
        pagePublicId: movesPage ? wanted.pagePublicId : null,
        payload: merged ?? desired,
        sortIndex: wanted.sortIndex,
        expectedElementRevision: before.revision,
      ),
    );
  }

  void _planLineupGroups() {
    final wanted = target.lineupGroups.whereType<LiveLineupGroup>().toList();
    final wantedIds = {for (final group in wanted) group.publicId};
    final elsewhere = <String, String>{
      for (final group in wanted)
        for (final item in _itemIds(group.payload)) item: group.publicId,
    };
    for (final group in stored.lineupGroups.whereType<LiveLineupGroup>()) {
      if (wantedIds.contains(group.publicId) || staysWithItsPage(group)) {
        continue;
      }
      groupDeletes.add(group.publicId, _deleteGroup(group));
    }
    for (final group in wanted) {
      final before = stored.lineupGroup(group.publicId);
      if (before is UnreadableLineupGroup) continue;
      if (_inTargetTrash(group) || (before != null && _inStoredTrash(before))) {
        if (!(before is LiveLineupGroup && _sameGroup(before, group))) {
          _refusals.add(RowInTrash(group.key));
        }
        continue;
      }
      switch (before) {
        case null:
          groupAdds.add(group.publicId, _addGroup(group, group.payload, null));
        case DeletedLineupGroup(:final revision):
          groupAdds.add(
            group.publicId,
            _addGroup(group, group.payload, revision),
          );
        case final LiveLineupGroup live:
          _planGroupEdit(live, group, elsewhere);
        case UnreadableLineupGroup():
          break;
      }
    }
  }

  void _planGroupEdit(
    LiveLineupGroup before,
    LiveLineupGroup wanted,
    Map<String, String> elsewhere,
  ) {
    if (_sameGroup(before, wanted)) return;
    final desired = _keepingItemFields(before.payload, wanted.payload);
    final shape = lineupEdit(before.payload, desired);
    final movesPlace = before.sortIndex != wanted.sortIndex;
    final fields = switch (shape) {
      FieldEdit(:final fields) => fields,
      WholeEdit() => const <String>[],
    };
    if (shape is FieldEdit &&
        fields.isEmpty &&
        !movesPlace &&
        before.pagePublicId == wanted.pagePublicId) {
      return;
    }
    final merged = switch (shape) {
      FieldEdit() => switch (mergeLineupPayload(
        before.payload,
        desired,
        FieldMerge(fields: fields),
      )) {
        Merged(:final value) => value,
        _ => desired,
      },
      WholeEdit() => desired,
    };
    if (shape is WholeEdit ||
        before.pagePublicId != wanted.pagePublicId ||
        fields.length >= maxMergeFields) {
      groupDeletes.add(before.publicId, _deleteGroup(before));
      groupAdds.add(
        wanted.publicId,
        _addGroup(wanted, merged, before.revision + 1),
      );
      return;
    }
    final leaving = [
      for (final field in fields)
        if (elsewhere[field] case final owner? when owner != wanted.publicId)
          field,
    ];
    final staying = [
      for (final field in fields)
        if (!leaving.contains(field)) field,
    ];
    if (leaving.isNotEmpty) {
      groupMovesOut.add(
        before.publicId,
        (opId) => LineupGroupPatchOp(
          opId: opId,
          lineupPublicId: before.publicId,
          payload: desired,
          expectedLineupRevision: before.revision,
          merge: FieldMerge(fields: leaving),
        ),
      );
    }
    if (staying.isEmpty && !movesPlace) return;
    final revision = before.revision + (leaving.isEmpty ? 0 : 1);
    groupEdits.add(
      before.publicId,
      (opId) => LineupGroupPatchOp(
        opId: opId,
        lineupPublicId: before.publicId,
        payload: staying.isEmpty ? null : desired,
        sortIndex: wanted.sortIndex,
        expectedLineupRevision: revision,
        merge: FieldMerge(fields: [...staying, if (movesPlace) placeField]),
      ),
    );
  }

  static _MakeOp _deleteGroup(LiveLineupGroup group) =>
      (opId) => LineupGroupDeleteOp(
        opId: opId,
        lineupPublicId: group.publicId,
        pagePublicId: group.pagePublicId,
        expectedLineupRevision: group.revision,
      );

  static _MakeOp _addGroup(
    LiveLineupGroup group,
    LineupGroupPayload payload,
    int? revision,
  ) =>
      (opId) => LineupGroupAddOp(
        opId: opId,
        lineupPublicId: group.publicId,
        pagePublicId: group.pagePublicId,
        payload: payload,
        sortIndex: group.sortIndex,
        expectedLineupRevision: revision,
      );
}

final class _Ops {
  _Ops(this.plan, this.editId)
    : _strategyRevision = plan.stored.strategy.revision,
      _pages = [for (final page in plan.storedPages) _Page.stored(page)];

  final _Plan plan;
  final String editId;
  final _ops = <StrategyOp>[];
  int _strategyRevision;
  final List<_Page> _pages;

  StrategyRowSet get stored => plan.stored;

  StrategyRowSet get target => plan.target;

  String get _opId => derivedId(jsonEncode([editId, _ops.length]));

  void _emit(Iterable<_MakeOp> made) {
    for (final make in made) {
      _ops.add(make(_opId));
    }
  }

  List<StrategyOp> build() {
    _patchStrategy();
    plan.addedPages.forEach(_addPage);
    _emit(plan.elementOps.inIdOrder);
    _emit(plan.groupDeletes.inIdOrder);
    _emit(plan.groupMovesOut.inIdOrder);
    _emit(plan.groupAdds.inIdOrder);
    _emit(plan.groupEdits.inIdOrder);
    plan.removedPages.forEach(_deletePage);
    if (plan.changesPageList) _reorder();
    final byId = {for (final page in _pages) page.publicId: page};
    for (final page in plan.targetPages) {
      _patchPage(byId[page.publicId]!, page);
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
      themeOverridePalette: switch (after.themeOverridePalette) {
        _
            when _samePalette(
              before.themeOverridePalette,
              after.themeOverridePalette,
            ) =>
          const KeepValue(),
        null => const ClearValue(),
        final palette => SetValue(
          _paletteKeeping(before.themeOverridePalette, palette),
        ),
      },
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

  void _placeAll() {
    for (final (index, page) in _pages.indexed) {
      page.place(index);
    }
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
    _placeAll();
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
    _pages.removeWhere((kept) => kept.publicId == page.publicId);
    _placeAll();
  }

  void _reorder() {
    final position = {
      for (final (index, page) in _pages.indexed) page.publicId: index,
    };
    for (final (index, wanted) in plan.targetPages.indexed) {
      final current = position[wanted.publicId]!;
      if (current == index) continue;
      _raiseStrategy(
        PageReorderOp(
          opId: _opId,
          pagePublicId: wanted.publicId,
          sortIndex: index,
          expectedStrategyRevision: _strategyRevision,
        ),
      );
      final page = _pages.removeAt(current);
      _pages.insert(index, page);
      for (var i = index; i <= current; i++) {
        position[_pages[i].publicId] = i;
      }
      _placeAll();
    }
  }

  void _patchPage(_Page page, LivePage wanted) {
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
        ) when settings == null || !_sameSettings(settings, wanted)) {
      _ops.add(
        PageSettingsPatchOp(
          opId: _opId,
          pagePublicId: page.publicId,
          settings: _settingsKeeping(settings, wanted),
          expectedPageSettingsRevision: revision,
        ),
      );
    }
  }
}

bool _sameElement(ElementRow? stored, LiveElement wanted) =>
    stored is LiveElement &&
    stored.pagePublicId == wanted.pagePublicId &&
    stored.sortIndex == wanted.sortIndex &&
    _samePayload(stored.payload, wanted.payload);

bool _samePayload(ElementPayload a, ElementPayload b) =>
    a.kind == b.kind &&
    a.payloadVersion == b.payloadVersion &&
    sameJsonTree(a.data, b.data) &&
    sameJsonTree(a.unknownFields, b.unknownFields);

bool _sameGroup(LiveLineupGroup stored, LiveLineupGroup wanted) =>
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
