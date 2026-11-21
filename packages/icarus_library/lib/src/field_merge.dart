import 'dart:math' as math;

import 'field_rules.dart';
import 'json.dart';
import 'ops.dart';
import 'payloads.dart';
import 'rows.dart';

const maxMergeFields = 512;

const _unsafeKeys = {'__proto__', 'constructor', 'prototype'};

const lineupCollections = ['origins', 'landings', 'links'];

sealed class WholeReason {
  const WholeReason();
}

final class KindDiffers extends WholeReason {
  const KindDiffers();
}

final class PayloadVersionDiffers extends WholeReason {
  const PayloadVersionDiffers();
}

final class IdentityDiffers extends WholeReason {
  const IdentityDiffers(this.key);

  final String key;
}

final class NamesIdentityKey extends WholeReason {
  const NamesIdentityKey(this.key);

  final String key;
}

final class NamesUnsafeKey extends WholeReason {
  const NamesUnsafeKey(this.key);

  final String key;
}

final class NamesNoLineupItem extends WholeReason {
  const NamesNoLineupItem(this.field);

  final String field;
}

sealed class MergeOutcome<T> {
  const MergeOutcome();
}

final class Merged<T> extends MergeOutcome<T> {
  const Merged(this.value);

  final T value;
}

final class WriteWhole<T> extends MergeOutcome<T> {
  const WriteWhole(this.reason);

  final WholeReason reason;
}

final class MergeConflict<T> extends MergeOutcome<T> {
  const MergeConflict(this.field);

  final String field;
}

sealed class EditShape {
  const EditShape();
}

final class FieldEdit extends EditShape {
  FieldEdit(List<String> fields) : fields = List.unmodifiable(fields);

  final List<String> fields;
}

final class WholeEdit extends EditShape {
  const WholeEdit(this.reason);

  final WholeReason reason;
}

enum Connection { live, offline }

sealed class Drawn {
  const Drawn(this.revision);

  final int revision;
}

final class DrawnAt extends Drawn {
  const DrawnAt(super.revision);
}

final class BehindWholeWrite extends Drawn {
  const BehindWholeWrite(super.revision);
}

typedef _Read = ({bool present, Object? value});

List<String> payloadFields(FieldMerge merge) => [
  for (final field in merge.fields)
    if (field != placeField) field,
];

bool mergeShapeIsValid(FieldMerge merge) =>
    merge.fields.length <= maxMergeFields &&
    merge.fields.toSet().length == merge.fields.length;

bool _same(_Read left, _Read right) {
  if (!left.present || !right.present) return left.present == right.present;
  return sameJson(left.value, right.value);
}

_Read _key(Map<String, Object?> data, String key) =>
    (present: data.containsKey(key), value: data[key]);

bool _sameOrUnset(
  Map<String, Object?> left,
  Map<String, Object?> right,
  String key,
) => sameJson(left[key], right[key]);

Map<String, Object?> _normalized(Map<String, Object?> data) =>
    withFieldDefaults(data)! as Map<String, Object?>;

EditShape elementEdit(ElementPayload base, ElementPayload desired) {
  if (base.kind != desired.kind) return const WholeEdit(KindDiffers());
  if (base.payloadVersion != desired.payloadVersion) {
    return const WholeEdit(PayloadVersionDiffers());
  }
  final before = _normalized(base.data.raw);
  final after = _normalized(desired.data.raw);
  for (final key in elementIdentityKeys) {
    if (!_sameOrUnset(before, after, key)) {
      return WholeEdit(IdentityDiffers(key));
    }
  }
  return FieldEdit(
    groupedFields(desired.kind, before, after, {
      for (final key in {...before.keys, ...after.keys})
        if (!_sameOrUnset(before, after, key)) key,
    }),
  );
}

List<String> groupedFields(
  ElementKind kind,
  Map<String, Object?> before,
  Map<String, Object?> after,
  Set<String> changed,
) {
  final named = {...changed};
  for (final group in fieldGroups) {
    if (group.appliesTo(kind, after) && changed.any(group.fields.contains)) {
      named.addAll(
        group.fields.where(
          (key) => before.containsKey(key) || after.containsKey(key),
        ),
      );
    }
  }
  return named.toList()..sort();
}

Map<String, Map<String, Object?>> _itemsById(
  Map<String, Object?> data,
  String collection,
) => {
  for (final item in lineupItems(data, collection))
    if (item['id'] case final String id) id: item,
};

EditShape lineupEdit(LineupGroupPayload base, LineupGroupPayload desired) {
  if (base.payloadVersion != desired.payloadVersion) {
    return const WholeEdit(PayloadVersionDiffers());
  }
  final before = _normalized(base.data.raw);
  final after = _normalized(desired.data.raw);
  if (!sameJson(before['id'], after['id'])) {
    return const WholeEdit(IdentityDiffers('id'));
  }
  final fields = <String>[];
  for (final collection in lineupCollections) {
    final beforeItems = _itemsById(before, collection);
    final afterItems = _itemsById(after, collection);
    for (final id in {
      ...beforeItems.keys,
      ...afterItems.keys,
    }.toList()..sort()) {
      final left = beforeItems[id];
      final right = afterItems[id];
      if ((left == null) != (right == null) || !sameJson(left, right)) {
        fields.add('$collection/$id');
      }
    }
  }
  return FieldEdit(fields);
}

_Read Function(String field) _elementReader(Map<String, Object?> data) =>
    (field) => _key(data, field);

_Read Function(String field) _lineupBaseReader(Map<String, Object?> data) {
  final byCollection = {
    for (final collection in lineupCollections)
      collection: _itemsById(data, collection),
  };
  return (field) {
    final target = lineupField(field);
    final item = target == null
        ? null
        : byCollection[target.collection]![target.id];
    return (present: item != null, value: item);
  };
}

FieldMerge _editMerge(
  List<String> fields,
  _Read Function(String field) baseValue, {
  required int baseSortIndex,
  required int sortIndex,
  required Connection connection,
}) {
  final moved = sortIndex != baseSortIndex;
  return FieldMerge(
    fields: [...fields, if (moved) placeField],
    base: switch (connection) {
      Connection.live => null,
      Connection.offline => {
        for (final field in fields)
          if (baseValue(field) case (present: true, :final value)) field: value,
        if (moved) placeField: baseSortIndex,
      },
    },
  );
}

ElementPatchOp elementEditOp({
  required String opId,
  required LiveElement base,
  required Drawn drawn,
  required ElementPayload payload,
  required int sortIndex,
  required Connection connection,
}) {
  ElementPatchOp patch(FieldMerge? merge, int expected) => ElementPatchOp(
    opId: opId,
    elementPublicId: base.publicId,
    pagePublicId: base.pagePublicId,
    expectedElementRevision: expected,
    payload: payload,
    sortIndex: sortIndex,
    merge: merge,
  );
  return switch ((drawn, elementEdit(base.payload, payload))) {
    (BehindWholeWrite(), _) || (DrawnAt(), WholeEdit()) => patch(
      null,
      math.min(base.revision, drawn.revision),
    ),
    (DrawnAt(), FieldEdit(:final fields)) => patch(
      _editMerge(
        fields,
        _elementReader(base.payload.data.raw),
        baseSortIndex: base.sortIndex,
        sortIndex: sortIndex,
        connection: connection,
      ),
      base.revision,
    ),
  };
}

LineupGroupPatchOp lineupEditOp({
  required String opId,
  required LiveLineupGroup base,
  required Drawn drawn,
  required LineupGroupPayload payload,
  required int sortIndex,
  required Connection connection,
}) {
  LineupGroupPatchOp patch(FieldMerge? merge, int expected) =>
      LineupGroupPatchOp(
        opId: opId,
        lineupPublicId: base.publicId,
        pagePublicId: base.pagePublicId,
        expectedLineupRevision: expected,
        payload: payload,
        sortIndex: sortIndex,
        merge: merge,
      );
  return switch ((drawn, lineupEdit(base.payload, payload))) {
    (BehindWholeWrite(), _) || (DrawnAt(), WholeEdit()) => patch(
      null,
      math.min(base.revision, drawn.revision),
    ),
    (DrawnAt(), FieldEdit(:final fields)) => patch(
      _editMerge(
        fields,
        _lineupBaseReader(base.payload.data.raw),
        baseSortIndex: base.sortIndex,
        sortIndex: sortIndex,
        connection: connection,
      ),
      base.revision,
    ),
  };
}

MergeOutcome<ElementPayload> mergeElementPayload(
  ElementPayload current,
  ElementPayload desired,
  FieldMerge merge,
) {
  if (current.kind != desired.kind) return const WriteWhole(KindDiffers());
  if (current.payloadVersion != desired.payloadVersion) {
    return const WriteWhole(PayloadVersionDiffers());
  }
  final fields = payloadFields(merge);
  for (final key in elementIdentityKeys) {
    if (fields.contains(key)) return WriteWhole(NamesIdentityKey(key));
    if (!_same(_key(current.data.raw, key), _key(desired.data.raw, key))) {
      return WriteWhole(IdentityDiffers(key));
    }
  }
  for (final field in fields) {
    if (_unsafeKeys.contains(field)) return WriteWhole(NamesUnsafeKey(field));
  }
  if (_conflictingField(
        merge,
        _elementReader(current.data.raw),
        _elementReader(desired.data.raw),
      )
      case final field?) {
    return MergeConflict(field);
  }
  return Merged(
    _elementWith(current, fields, _elementReader(desired.data.raw)),
  );
}

ElementPayload _elementWith(
  ElementPayload payload,
  List<String> fields,
  _Read Function(String field) valueOf,
) {
  final data = {...payload.data.raw};
  for (final field in fields) {
    switch (valueOf(field)) {
      case (present: true, :final value):
        data[field] = value;
      case (present: false, value: _):
        data.remove(field);
    }
  }
  return elementPayloadAdopting(payload, data);
}

_Read _mergeBase(FieldMerge merge, String field) {
  final base = merge.base!.raw;
  return (present: base.containsKey(field), value: base[field]);
}

ElementPayload elementPayloadAtMergeBase(
  ElementPayload payload,
  FieldMerge merge,
) => merge.base == null
    ? payload
    : _elementWith(
        payload,
        payloadFields(merge),
        (field) => _mergeBase(merge, field),
      );

typedef LineupItemField = ({String collection, String id});

LineupItemField? lineupField(String field) {
  final slash = field.indexOf('/');
  if (slash <= 0) return null;
  final collection = field.substring(0, slash);
  final id = field.substring(slash + 1);
  if (id.isEmpty || !lineupCollections.contains(collection)) return null;
  return (collection: collection, id: id);
}

List<Map<String, Object?>> lineupItems(
  Map<String, Object?> data,
  String collection,
) {
  final items = data[collection];
  return items is List<Object?>
      ? [
          for (final item in items)
            if (item is Map<String, Object?>) item,
        ]
      : [];
}

Map<String, Object?>? _itemById(
  Map<String, Object?> data,
  String collection,
  String id,
) {
  for (final item in lineupItems(data, collection)) {
    if (item['id'] == id) return item;
  }
  return null;
}

_Read Function(String field) _lineupReader(Map<String, Object?> data) =>
    (field) {
      final target = lineupField(field);
      final item = target == null
          ? null
          : _itemById(data, target.collection, target.id);
      return (present: item != null, value: item);
    };

sealed class _LineupNames {
  const _LineupNames();
}

final class _Items extends _LineupNames {
  const _Items(this.items);

  final List<LineupItemField> items;
}

final class _NotAnItem extends _LineupNames {
  const _NotAnItem(this.field);

  final String field;
}

_LineupNames _lineupNames(FieldMerge merge) {
  final items = <LineupItemField>[];
  for (final field in payloadFields(merge)) {
    final item = lineupField(field);
    if (item == null) return _NotAnItem(field);
    items.add(item);
  }
  return _Items(items);
}

MergeOutcome<LineupGroupPayload> mergeLineupPayload(
  LineupGroupPayload current,
  LineupGroupPayload desired,
  FieldMerge merge,
) {
  if (current.payloadVersion != desired.payloadVersion) {
    return const WriteWhole(PayloadVersionDiffers());
  }
  if (!sameJson(current.data.raw['id'], desired.data.raw['id'])) {
    return const WriteWhole(IdentityDiffers('id'));
  }
  final List<LineupItemField> items;
  switch (_lineupNames(merge)) {
    case _NotAnItem(:final field):
      return WriteWhole(NamesNoLineupItem(field));
    case _Items(items: final named):
      items = named;
  }
  if (_conflictingField(
        merge,
        _lineupReader(current.data.raw),
        _lineupReader(desired.data.raw),
      )
      case final field?) {
    return MergeConflict(field);
  }
  return Merged(_lineupWith(current, items, _lineupReader(desired.data.raw)));
}

MergeOutcome<LineupGroupPayload> lineupPayloadAtMergeBase(
  LineupGroupPayload payload,
  FieldMerge merge,
) {
  if (merge.base == null) return Merged(payload);
  return switch (_lineupNames(merge)) {
    _NotAnItem(:final field) => WriteWhole(NamesNoLineupItem(field)),
    _Items(:final items) => Merged(
      _lineupWith(payload, items, (field) => _mergeBase(merge, field)),
    ),
  };
}

LineupGroupPayload _lineupWith(
  LineupGroupPayload payload,
  List<LineupItemField> items,
  _Read Function(String field) valueOf,
) {
  final lists = {
    for (final collection in lineupCollections)
      collection: [...lineupItems(payload.data.raw, collection)],
  };
  for (final (:collection, :id) in items) {
    final list = lists[collection]!;
    final index = list.indexWhere((item) => item['id'] == id);
    switch (valueOf('$collection/$id')) {
      case (present: true, value: final Map<String, Object?> wanted):
        if (index >= 0) {
          list[index] = wanted;
        } else {
          list.add(wanted);
        }
      case _:
        if (index >= 0) list.removeAt(index);
    }
  }
  final links = lists['links']!;
  final usedOrigins = {for (final link in links) link['originId']};
  final usedLandings = {for (final link in links) link['landingId']};
  return lineupPayloadAdopting(payload, {
    ...payload.data.raw,
    'origins': [
      for (final origin in lists['origins']!)
        if (usedOrigins.contains(origin['id'])) origin,
    ],
    'landings': [
      for (final landing in lists['landings']!)
        if (usedLandings.contains(landing['id'])) landing,
    ],
    'links': links,
  });
}

String? _conflictingField(
  FieldMerge merge,
  _Read Function(String field) current,
  _Read Function(String field) desired,
) {
  if (merge.base == null) return null;
  for (final field in payloadFields(merge)) {
    final now = current(field);
    if (!_same(now, _mergeBase(merge, field)) && !_same(now, desired(field))) {
      return field;
    }
  }
  return null;
}

bool placeChanged(FieldMerge? merge, int currentSortIndex, int? sortIndex) {
  final base = merge?.base?.raw;
  if (merge == null || base == null || !merge.fields.contains(placeField)) {
    return false;
  }
  return base[placeField] != currentSortIndex && sortIndex != currentSortIndex;
}

ElementPayload keepStoredFields(ElementPayload stored, ElementPayload next) {
  final data = {...next.data.raw};
  final pictureId = stored.data.raw[pictureIdField];
  if (pictureId is String && !next.data.raw.containsKey(pictureIdField)) {
    data[pictureIdField] = pictureId;
  }
  for (final entry in laterElementFields) {
    if (entry.kinds.contains(next.kind) &&
        stored.data.raw.containsKey(entry.field) &&
        !data.containsKey(entry.field)) {
      data[entry.field] = stored.data.raw[entry.field];
    }
  }
  if (data.length == next.data.raw.length) return next;
  return elementPayloadAdopting(next, data);
}
