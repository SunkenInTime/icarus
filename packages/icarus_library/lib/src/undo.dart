import 'apply.dart';
import 'field_merge.dart';
import 'field_rules.dart';
import 'json.dart';
import 'ops.dart';
import 'outcome.dart';
import 'payloads.dart';
import 'rows.dart';
import 'strategy_rows.dart';

sealed class Undo {
  const Undo();
}

final class RestoreStrategyFields extends Undo {
  RestoreStrategyFields({
    required this.before,
    required this.after,
    required Set<RowField> fields,
  }) : fields = Set.unmodifiable(fields);

  final ReadableStrategy before;
  final ReadableStrategy after;
  final Set<RowField> fields;
}

final class RestorePageFields extends Undo {
  RestorePageFields({
    required this.before,
    required this.after,
    required Set<RowField> fields,
  }) : fields = Set.unmodifiable(fields);

  final LivePage before;
  final LivePage after;
  final Set<RowField> fields;
}

final class RestorePagePlace extends Undo {
  const RestorePagePlace({
    required this.pagePublicId,
    required this.sortIndex,
    required this.movedTo,
  });

  final String pagePublicId;
  final int sortIndex;
  final int movedTo;
}

final class RemoveAddedPage extends Undo {
  const RemoveAddedPage(this.pagePublicId);

  final String pagePublicId;
}

final class RestoreTrashedPage extends Undo {
  const RestoreTrashedPage(this.pagePublicId);

  final String pagePublicId;
}

final class RestoreSettings extends Undo {
  const RestoreSettings({
    required this.pagePublicId,
    required this.before,
    required this.after,
  });

  final String pagePublicId;
  final PageSettings? before;
  final PageSettings after;
}

final class RemoveAddedElement extends Undo {
  const RemoveAddedElement(this.added);

  final ElementRow added;
}

final class RestoreDeletedElement extends Undo {
  const RestoreDeletedElement(this.before, {required this.deletedAt});

  final LiveElement before;
  final int deletedAt;
}

final class RestoreElementFields extends Undo {
  RestoreElementFields({
    required this.before,
    required this.after,
    required Set<RowField> fields,
    required Set<String> dataFields,
  }) : fields = Set.unmodifiable(fields),
       dataFields = Set.unmodifiable(dataFields);

  final LiveElement before;
  final ElementRow after;
  final Set<RowField> fields;
  final Set<String> dataFields;
}

final class RemoveAddedGroup extends Undo {
  const RemoveAddedGroup(this.added);

  final ReadableLineupGroupRow added;
}

final class RestoreDeletedGroup extends Undo {
  const RestoreDeletedGroup(this.before, {required this.deletedAt});

  final LiveLineupGroup before;
  final int deletedAt;
}

final class RestoreGroupFields extends Undo {
  RestoreGroupFields({
    required this.before,
    required this.after,
    required Set<RowField> fields,
    required Set<String> dataFields,
  }) : fields = Set.unmodifiable(fields),
       dataFields = Set.unmodifiable(dataFields);

  final LiveLineupGroup before;
  final ReadableLineupGroupRow after;
  final Set<RowField> fields;
  final Set<String> dataFields;

  int? indexBefore(String field) => switch (lineupField(field)) {
    (:final collection, :final id) => switch (lineupItems(
      before.payload.data.raw,
      collection,
    ).indexWhere((item) => item['id'] == id)) {
      -1 => null,
      final index => index,
    },
    null => null,
  };
}

sealed class UndoBuild {
  const UndoBuild();
}

final class UndoReady extends UndoBuild {
  const UndoReady(this.op);

  final StrategyOp op;
}

final class RestoreFromTrash extends UndoBuild {
  const RestoreFromTrash(this.pagePublicId);

  final String pagePublicId;
}

final class NothingToUndo extends UndoBuild {
  const NothingToUndo();
}

final class UndoBlocked extends UndoBuild {
  const UndoBlocked(this.block);

  final UndoBlock block;
}

sealed class UndoBlock {
  const UndoBlock(this.key);

  final RowKey key;
}

final class TargetGone extends UndoBlock {
  const TargetGone(super.key);
}

final class TargetUnreadable extends UndoBlock {
  const TargetUnreadable(super.key);
}

final class ChangedSince extends UndoBlock {
  ChangedSince(super.key, Iterable<String> fields)
    : fields = List.unmodifiable(fields);

  final List<String> fields;
}

final class CannotClear extends UndoBlock {
  const CannotClear(super.key, this.field);

  final String field;
}

UndoBuild buildUndo(
  StrategyRows rows,
  Undo undo, {
  required String opId,
  required PageSettings defaultSettings,
}) {
  final build = _Build(rows, opId);
  final built = switch (undo) {
    RestoreStrategyFields() => build.strategyFields(undo),
    RestorePageFields() => build.pageFields(undo),
    RestorePagePlace() => build.pagePlace(undo),
    RemoveAddedPage() => build.addedPage(undo),
    RestoreTrashedPage() => build.trashedPage(undo),
    RestoreSettings() => build.settings(undo, defaultSettings),
    RemoveAddedElement() => build.addedElement(undo),
    RestoreDeletedElement() => build.deletedElement(undo),
    RestoreElementFields() => build.elementFields(undo),
    RemoveAddedGroup() => build.addedGroup(undo),
    RestoreDeletedGroup() => build.deletedGroup(undo),
    RestoreGroupFields() => build.groupFields(undo),
  };
  return switch (built) {
    UndoReady(:final op) when applyOp(rows, op) is OpUnchanged =>
      const NothingToUndo(),
    _ => built,
  };
}

enum _Stand { back, edited, changed }

sealed class _Plan<F> {
  const _Plan();
}

final class _Restore<F> extends _Plan<F> {
  const _Restore(this.fields);

  final Set<F> fields;
}

final class _AllBack<F> extends _Plan<F> {
  const _AllBack();
}

final class _Changed<F> extends _Plan<F> {
  const _Changed(this.fields);

  final List<F> fields;
}

_Plan<F> _plan<F>(Map<F, _Stand> stands) {
  final changed = [
    for (final MapEntry(:key, :value) in stands.entries)
      if (value == _Stand.changed) key,
  ];
  if (changed.isNotEmpty) return _Changed(changed);
  final restore = {
    for (final MapEntry(:key, :value) in stands.entries)
      if (value == _Stand.edited) key,
  };
  return restore.isEmpty ? const _AllBack() : _Restore(restore);
}

_Stand _stand(Object? now, Object? after, Object? before) => now == before
    ? _Stand.back
    : now == after
    ? _Stand.edited
    : _Stand.changed;

final class _Absent {
  const _Absent();
}

const _absent = _Absent();

Object? _entry(Map<String, Object?> data, String key) =>
    data.containsKey(key) ? data[key] : _absent;

bool _sameEntry(Object? left, Object? right) =>
    identical(left, right) ||
    (left is! _Absent && right is! _Absent && sameJson(left, right));

_Stand _jsonStand(Object? now, Object? after, Object? before) =>
    _sameEntry(now, before)
    ? _Stand.back
    : _sameEntry(now, after)
    ? _Stand.edited
    : _Stand.changed;

ValueEdit<T> _restoring<T extends Object>(T? value) => switch (value) {
  final T value? => SetValue(value),
  null => ClearValue<T>(),
};

UndoBuild _blocked(UndoBlock block) => UndoBlocked(block);

Map<String, Object?> _withoutCleared(ElementPayload payload) => {
  for (final MapEntry(:key, :value) in payload.data.raw.entries)
    if (laterField(payload.kind, key)?.empty case ClearedBy(
      value: final cleared,
    ) when sameJson(cleared, value))
      ...const <String, Object?>{}
    else
      key: value,
};

Map<String, Object?> _filled(Map<String, Object?> data) =>
    withFieldDefaults(data)! as Map<String, Object?>;

Map<String, Object?> _byId(Map<String, Object?> data, String collection) => {
  for (final item in lineupItems(data, collection))
    if (item['id'] case final String id) id: item,
};

bool _sameGroupContent(LineupGroupPayload left, LineupGroupPayload right) {
  if (left.payloadVersion != right.payloadVersion) return false;
  final a = _filled(left.data.raw);
  final b = _filled(right.data.raw);
  for (final key in {...a.keys, ...b.keys}) {
    if (lineupCollections.contains(key)) {
      if (!sameJson(_byId(a, key), _byId(b, key))) return false;
    } else if (!_sameEntry(_entry(a, key), _entry(b, key))) {
      return false;
    }
  }
  return true;
}

List<String> _idsIn(Map<String, Object?> data, String collection) => [
  for (final item in lineupItems(data, collection))
    if (item['id'] case final String id) id,
];

List<Map<String, Object?>> _inOrderOf(
  List<Map<String, Object?>> items,
  List<String> order,
) {
  final place = {for (final (index, id) in order.indexed) id: index};
  final placed = [
    for (final item in items)
      if (place.containsKey(item['id'])) item,
  ]..sort((a, b) => place[a['id']]!.compareTo(place[b['id']]!));
  var next = 0;
  return [
    for (final item in items)
      if (place.containsKey(item['id'])) placed[next++] else item,
  ];
}

bool _sameContent(ElementPayload left, ElementPayload right) =>
    left.kind == right.kind &&
    left.payloadVersion == right.payloadVersion &&
    sameJson(left.unknownFields, right.unknownFields) &&
    sameJson(_withoutCleared(left), _withoutCleared(right));

final class _Build {
  _Build(this.rows, this.opId);

  final StrategyRows rows;
  final String opId;

  UndoBuild strategyFields(RestoreStrategyFields undo) {
    final now = rows.strategy;
    Object? read(ReadableStrategy row, RowField field) => switch (field) {
      RowField.name => row.name,
      RowField.mapData => row.mapData,
      RowField.themeProfileId => row.themeProfileId,
      RowField.themeOverridePalette => row.themeOverridePalette,
      _ => null,
    };
    final fields = undo.fields.where(
      (field) => read(undo.after, field) != read(undo.before, field),
    );
    switch (_plan({
      for (final field in fields)
        field: _stand(
          read(now, field),
          read(undo.after, field),
          read(undo.before, field),
        ),
    })) {
      case _Changed(:final fields):
        return _blocked(
          ChangedSince(now.key, [for (final field in fields) field.name]),
        );
      case _AllBack():
        return const NothingToUndo();
      case _Restore(:final fields):
        final before = undo.before;
        return UndoReady(
          StrategyPatchOp(
            opId: opId,
            expectedStrategyRevision: now.revision,
            name: fields.contains(RowField.name) ? before.name : null,
            mapData: fields.contains(RowField.mapData) ? before.mapData : null,
            themeProfile: fields.contains(RowField.themeProfileId)
                ? _restoring(before.themeProfileId)
                : const KeepValue(),
            themeOverridePalette: fields.contains(RowField.themeOverridePalette)
                ? _restoring(before.themeOverridePalette)
                : const KeepValue(),
          ),
        );
    }
  }

  UndoBuild? _pageMissing(String pagePublicId) =>
      switch (rows.page(pagePublicId)) {
        null || TrashedPage() => _blocked(TargetGone(PageKey(pagePublicId))),
        UnreadablePage() => _blocked(TargetUnreadable(PageKey(pagePublicId))),
        LivePage() => null,
      };

  UndoBuild pageFields(RestorePageFields undo) {
    final id = undo.before.publicId;
    if (_pageMissing(id) case final missing?) return missing;
    final now = rows.page(id)! as LivePage;
    Object? read(LivePage page, RowField field) => switch (field) {
      RowField.name => page.name,
      RowField.isAutoNamed => page.isAutoNamed ?? false,
      RowField.isAttack => page.isAttack,
      _ => null,
    };
    final fields = undo.fields.where(
      (field) => read(undo.after, field) != read(undo.before, field),
    );
    switch (_plan({
      for (final field in fields)
        field: _stand(
          read(now, field),
          read(undo.after, field),
          read(undo.before, field),
        ),
    })) {
      case _Changed(:final fields):
        return _blocked(
          ChangedSince(now.key, [for (final field in fields) field.name]),
        );
      case _AllBack():
        return const NothingToUndo();
      case _Restore(:final fields):
        final before = undo.before;
        return UndoReady(
          PagePatchOp(
            opId: opId,
            pagePublicId: id,
            expectedPageRevision: now.revision,
            name: fields.contains(RowField.name) ? before.name : null,
            isAutoNamed: fields.contains(RowField.isAutoNamed)
                ? before.isAutoNamed ?? false
                : null,
            isAttack: fields.contains(RowField.isAttack)
                ? before.isAttack
                : null,
          ),
        );
    }
  }

  UndoBuild pagePlace(RestorePagePlace undo) {
    final id = undo.pagePublicId;
    if (_pageMissing(id) case final missing?) return missing;
    final now = rows.page(id)! as LivePage;
    return switch (_stand(now.sortIndex, undo.movedTo, undo.sortIndex)) {
      _Stand.back => const NothingToUndo(),
      _Stand.changed => _blocked(
        ChangedSince(now.key, [RowField.sortIndex.name]),
      ),
      _Stand.edited => UndoReady(
        PageReorderOp(
          opId: opId,
          pagePublicId: id,
          sortIndex: undo.sortIndex,
          expectedStrategyRevision: rows.strategy.revision,
        ),
      ),
    };
  }

  UndoBuild addedPage(RemoveAddedPage undo) {
    final id = undo.pagePublicId;
    return switch (rows.page(id)) {
      null => _blocked(TargetGone(PageKey(id))),
      TrashedPage() => const NothingToUndo(),
      UnreadablePage() => _blocked(TargetUnreadable(PageKey(id))),
      LivePage() => UndoReady(
        PageDeleteOp(
          opId: opId,
          pagePublicId: id,
          expectedStrategyRevision: rows.strategy.revision,
        ),
      ),
    };
  }

  UndoBuild trashedPage(RestoreTrashedPage undo) {
    final id = undo.pagePublicId;
    return switch (rows.page(id)) {
      null => _blocked(TargetGone(PageKey(id))),
      TrashedPage() => RestoreFromTrash(id),
      UnreadablePage() => _blocked(TargetUnreadable(PageKey(id))),
      LivePage() => const NothingToUndo(),
    };
  }

  UndoBuild settings(RestoreSettings undo, PageSettings defaults) {
    final id = undo.pagePublicId;
    if (_pageMissing(id) case final missing?) return missing;
    final ReadablePageSettings now;
    switch (rows.settingsOf(id)) {
      case null:
        return _blocked(TargetGone(PageSettingsKey(id)));
      case UnreadablePageSettings():
        return _blocked(TargetUnreadable(PageSettingsKey(id)));
      case final ReadablePageSettings readable:
        now = readable;
    }
    final target = undo.before ?? defaults;
    return switch (_stand(now.settings, undo.after, target)) {
      _Stand.back => const NothingToUndo(),
      _Stand.changed => _blocked(
        ChangedSince(now.key, [RowField.settings.name]),
      ),
      _Stand.edited => UndoReady(
        PageSettingsPatchOp(
          opId: opId,
          pagePublicId: id,
          settings: target,
          expectedPageSettingsRevision: now.revision,
        ),
      ),
    };
  }

  UndoBuild addedElement(RemoveAddedElement undo) {
    final added = undo.added;
    final key = ElementKey(added.publicId);
    return switch (rows.element(added.publicId)) {
      null => _blocked(TargetGone(key)),
      DeletedElement() => const NothingToUndo(),
      UnreadableElement() => _blocked(TargetUnreadable(key)),
      final LiveElement now => switch (added) {
        LiveElement(:final payload, :final pagePublicId, :final sortIndex)
            when _sameContent(now.payload, payload) &&
                now.pagePublicId == pagePublicId &&
                now.sortIndex == sortIndex =>
          UndoReady(
            ElementDeleteOp(
              opId: opId,
              elementPublicId: now.publicId,
              pagePublicId: now.pagePublicId,
              expectedElementRevision: now.revision,
            ),
          ),
        _ => _blocked(ChangedSince(key, const ['payload'])),
      },
    };
  }

  UndoBuild deletedElement(RestoreDeletedElement undo) {
    final before = undo.before;
    final key = before.key;
    return switch (rows.element(before.publicId)) {
      null => _blocked(TargetGone(key)),
      LiveElement() => const NothingToUndo(),
      UnreadableElement() => _blocked(TargetUnreadable(key)),
      DeletedElement(:final revision) when revision != undo.deletedAt =>
        _blocked(ChangedSince(key, const ['deleted'])),
      final DeletedElement now => UndoReady(
        ElementAddOp(
          opId: opId,
          elementPublicId: before.publicId,
          pagePublicId: before.pagePublicId,
          payload: before.payload,
          sortIndex: before.sortIndex,
          expectedElementRevision: now.revision,
        ),
      ),
    };
  }

  UndoBuild elementFields(RestoreElementFields undo) {
    final before = undo.before;
    final key = before.key;
    final LiveElement now;
    switch (rows.element(before.publicId)) {
      case null || DeletedElement():
        return _blocked(TargetGone(key));
      case UnreadableElement():
        return _blocked(TargetUnreadable(key));
      case final LiveElement live:
        now = live;
    }
    final ReadableElementRow after;
    switch (undo.after) {
      case final ReadableElementRow readable:
        after = readable;
      case UnreadableElement():
        return _blocked(TargetUnreadable(key));
    }
    Object? read(ReadableElementRow row, RowField field) => switch (field) {
      RowField.page => row.pagePublicId,
      RowField.sortIndex => row.sortIndex,
      RowField.kind => row.payload.kind,
      RowField.payloadVersion => row.payload.payloadVersion,
      _ => null,
    };
    final rowFields = undo.fields.where(
      (field) => read(after, field) != read(before, field),
    );
    final nowData = _filled(now.payload.data.raw);
    final afterData = _filled(after.payload.data.raw);
    final beforeData = _filled(before.payload.data.raw);
    final written = groupedFields(
      before.payload.kind,
      beforeData,
      afterData,
      undo.dataFields.toSet(),
    );
    final plan = _plan<String>({
      for (final field in rowFields)
        field.name: _stand(
          read(now, field),
          read(after, field),
          read(before, field),
        ),
      for (final field in written)
        'data/$field': _jsonStand(
          _entry(nowData, field),
          _entry(afterData, field),
          _entry(beforeData, field),
        ),
    });
    final Set<String> restore;
    switch (plan) {
      case _Changed(:final fields):
        return _blocked(ChangedSince(key, fields));
      case _AllBack():
        return const NothingToUndo();
      case _Restore(:final fields):
        restore = fields;
    }
    if (restore.length == 1 && restore.contains(RowField.sortIndex.name)) {
      return UndoReady(
        ElementReorderOp(
          opId: opId,
          elementPublicId: before.publicId,
          pagePublicId: now.pagePublicId,
          sortIndex: before.sortIndex,
          expectedElementRevision: now.revision,
        ),
      );
    }
    final wholePayload =
        restore.contains(RowField.kind.name) ||
        restore.contains(RowField.payloadVersion.name);
    final data = {...now.payload.data.raw};
    for (final field in written) {
      if (!restore.contains('data/$field')) continue;
      final kept = before.payload.data.raw;
      if (kept.containsKey(field)) {
        data[field] = kept[field];
        continue;
      }
      if (field == pictureIdField) return _blocked(CannotClear(key, field));
      switch (laterField(before.payload.kind, field)?.empty) {
        case null:
          data.remove(field);
        case NeverCleared():
          return _blocked(CannotClear(key, field));
        case ClearedBy(:final value):
          data[field] = value;
      }
    }
    final envelopeBack = !sameJson(
      before.payload.unknownFields,
      now.payload.unknownFields,
    );
    final payload = elementPayloadAdopting(
      wholePayload || envelopeBack ? before.payload : now.payload,
      data,
    );
    final sortIndex = restore.contains(RowField.sortIndex.name)
        ? before.sortIndex
        : now.sortIndex;
    final pageBack = restore.contains(RowField.page.name);
    if (pageBack || wholePayload || envelopeBack) {
      return UndoReady(
        ElementPatchOp(
          opId: opId,
          elementPublicId: before.publicId,
          expectedElementRevision: now.revision,
          pagePublicId: pageBack ? before.pagePublicId : null,
          payload: payload,
          sortIndex: sortIndex,
        ),
      );
    }
    return UndoReady(
      elementEditOp(
        opId: opId,
        base: now,
        drawn: DrawnAt(now.revision),
        payload: payload,
        sortIndex: sortIndex,
        connection: Connection.offline,
      ),
    );
  }

  UndoBuild addedGroup(RemoveAddedGroup undo) {
    final added = undo.added;
    final key = added.key;
    return switch (rows.lineupGroup(added.publicId)) {
      null => _blocked(TargetGone(key)),
      DeletedLineupGroup() => const NothingToUndo(),
      UnreadableLineupGroup() => _blocked(TargetUnreadable(key)),
      final LiveLineupGroup now
          when _sameGroupContent(now.payload, added.payload) &&
              now.sortIndex == added.sortIndex =>
        UndoReady(
          LineupGroupDeleteOp(
            opId: opId,
            lineupPublicId: now.publicId,
            pagePublicId: now.pagePublicId,
            expectedLineupRevision: now.revision,
          ),
        ),
      LiveLineupGroup() => _blocked(ChangedSince(key, const ['payload'])),
    };
  }

  UndoBuild deletedGroup(RestoreDeletedGroup undo) {
    final before = undo.before;
    final key = before.key;
    return switch (rows.lineupGroup(before.publicId)) {
      null => _blocked(TargetGone(key)),
      LiveLineupGroup() => const NothingToUndo(),
      UnreadableLineupGroup() => _blocked(TargetUnreadable(key)),
      DeletedLineupGroup(:final revision) when revision != undo.deletedAt =>
        _blocked(ChangedSince(key, const ['deleted'])),
      final DeletedLineupGroup now => UndoReady(
        LineupGroupAddOp(
          opId: opId,
          lineupPublicId: before.publicId,
          pagePublicId: before.pagePublicId,
          payload: before.payload,
          sortIndex: before.sortIndex,
          expectedLineupRevision: now.revision,
        ),
      ),
    };
  }

  UndoBuild groupFields(RestoreGroupFields undo) {
    final before = undo.before;
    final key = before.key;
    final LiveLineupGroup now;
    switch (rows.lineupGroup(before.publicId)) {
      case null || DeletedLineupGroup():
        return _blocked(TargetGone(key));
      case UnreadableLineupGroup():
        return _blocked(TargetUnreadable(key));
      case final LiveLineupGroup live:
        now = live;
    }
    final after = undo.after;
    Object? read(ReadableLineupGroupRow row, RowField field) => switch (field) {
      RowField.sortIndex => row.sortIndex,
      RowField.payloadVersion => row.payload.payloadVersion,
      _ => null,
    };
    final nowData = _filled(now.payload.data.raw);
    final afterData = _filled(after.payload.data.raw);
    final beforeData = _filled(before.payload.data.raw);
    Object? entry(Map<String, Object?> data, String field) {
      if (lineupField(field) case (:final collection, :final id)) {
        return _byId(data, collection)[id] ?? _absent;
      }
      if (lineupCollections.contains(field)) {
        final kept = _idsIn(beforeData, field).toSet()
          ..retainAll(_idsIn(afterData, field));
        return [
          for (final id in _idsIn(data, field))
            if (kept.contains(id)) id,
        ];
      }
      return _entry(data, field);
    }

    final rowFields = undo.fields.where(
      (field) => read(after, field) != read(before, field),
    );
    final plan = _plan<String>({
      for (final field in rowFields)
        field.name: _stand(
          read(now, field),
          read(after, field),
          read(before, field),
        ),
      for (final field in undo.dataFields)
        'data/$field': lineupCollections.contains(field)
            ? (_sameEntry(entry(nowData, field), entry(beforeData, field))
                  ? _Stand.back
                  : _Stand.edited)
            : _jsonStand(
                entry(nowData, field),
                entry(afterData, field),
                entry(beforeData, field),
              ),
    });
    final Set<String> restore;
    switch (plan) {
      case _Changed(:final fields):
        return _blocked(ChangedSince(key, fields));
      case _AllBack():
        return const NothingToUndo();
      case _Restore(:final fields):
        restore = fields;
    }
    final sortIndex = restore.contains(RowField.sortIndex.name)
        ? before.sortIndex
        : now.sortIndex;
    final restoredData = [
      for (final field in undo.dataFields)
        if (restore.contains('data/$field')) field,
    ];
    if (restoredData.isEmpty &&
        !restore.contains(RowField.payloadVersion.name)) {
      return UndoReady(
        LineupGroupReorderOp(
          opId: opId,
          lineupPublicId: before.publicId,
          pagePublicId: now.pagePublicId,
          sortIndex: before.sortIndex,
          expectedLineupRevision: now.revision,
        ),
      );
    }
    if (restore.contains(RowField.payloadVersion.name)) {
      return UndoReady(
        LineupGroupPatchOp(
          opId: opId,
          lineupPublicId: before.publicId,
          expectedLineupRevision: now.revision,
          payload: before.payload,
          sortIndex: sortIndex == now.sortIndex ? null : sortIndex,
        ),
      );
    }
    final data = {...now.payload.data.raw};
    final lists = {
      for (final collection in lineupCollections)
        collection: [...lineupItems(data, collection)],
    };
    var whole = false;
    for (final field in restoredData) {
      if (lineupField(field) case (:final collection, :final id)) {
        final list = lists[collection]!;
        final at = list.indexWhere((item) => item['id'] == id);
        switch (_byId(before.payload.data.raw, collection)[id]) {
          case final Map<String, Object?> item when at >= 0:
            list[at] = item;
          case final Map<String, Object?> item:
            list.insert(
              (undo.indexBefore(field) ?? list.length).clamp(0, list.length),
              item,
            );
          case _:
            if (at >= 0) list.removeAt(at);
        }
        continue;
      }
      whole = true;
      if (!lineupCollections.contains(field)) {
        switch (_entry(before.payload.data.raw, field)) {
          case _Absent():
            data.remove(field);
          case final value:
            data[field] = value;
        }
      }
    }
    for (final field in restoredData) {
      if (lineupCollections.contains(field)) {
        lists[field] = _inOrderOf(
          lists[field]!,
          _idsIn(before.payload.data.raw, field),
        );
      }
    }
    final envelopeBack = !sameJson(
      before.payload.unknownFields,
      now.payload.unknownFields,
    );
    final payload = lineupPayloadAdopting(
      envelopeBack ? before.payload : now.payload,
      {...data, ...lists},
    );
    if (whole || envelopeBack) {
      return UndoReady(
        LineupGroupPatchOp(
          opId: opId,
          lineupPublicId: before.publicId,
          expectedLineupRevision: now.revision,
          payload: payload,
          sortIndex: sortIndex == now.sortIndex ? null : sortIndex,
        ),
      );
    }
    return UndoReady(
      lineupEditOp(
        opId: opId,
        base: now,
        drawn: DrawnAt(now.revision),
        payload: payload,
        sortIndex: sortIndex,
        connection: Connection.offline,
      ),
    );
  }
}
