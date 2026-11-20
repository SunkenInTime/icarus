import 'json.dart';
import 'ops.dart';
import 'payloads.dart';

const maxMergeFields = 512;

const elementIdentityKeys = ['id', 'elementType', 'kind', 'type', 'data'];

const _unsafeKeys = {'__proto__', 'constructor', 'prototype'};

const lineupCollections = ['origins', 'landings', 'links'];

sealed class MergeOutcome<T> {
  const MergeOutcome();
}

final class Merged<T> extends MergeOutcome<T> {
  const Merged(this.value);

  final T value;
}

final class WriteWhole<T> extends MergeOutcome<T> {
  const WriteWhole();
}

final class MergeConflict<T> extends MergeOutcome<T> {
  const MergeConflict();
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

MergeOutcome<ElementPayload> mergeElementPayload(
  ElementPayload current,
  ElementPayload desired,
  FieldMerge merge,
) {
  if (current.kind != desired.kind ||
      current.payloadVersion != desired.payloadVersion) {
    return const WriteWhole();
  }
  final fields = payloadFields(merge);
  for (final key in elementIdentityKeys) {
    if (fields.contains(key) ||
        !_same(_key(current.data, key), _key(desired.data, key))) {
      return const WriteWhole();
    }
  }
  if (fields.any(_unsafeKeys.contains)) return const WriteWhole();
  if (_baseChanged(
    merge,
    (field) => _key(current.data, field),
    (field) => _key(desired.data, field),
  )) {
    return const MergeConflict();
  }
  final data = {...current.data};
  for (final field in fields) {
    if (desired.data.containsKey(field)) {
      data[field] = desired.data[field];
    } else {
      data.remove(field);
    }
  }
  return Merged(
    ElementPayload(
      kind: current.kind,
      payloadVersion: current.payloadVersion,
      data: data,
    ),
  );
}

({String collection, String id})? lineupField(String field) {
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

MergeOutcome<LineupGroupPayload> mergeLineupPayload(
  LineupGroupPayload current,
  LineupGroupPayload desired,
  FieldMerge merge,
) {
  if (current.payloadVersion != desired.payloadVersion ||
      !sameJson(current.data['id'], desired.data['id'])) {
    return const WriteWhole();
  }
  final named = payloadFields(merge).map(lineupField).toList();
  if (named.any((entry) => entry == null)) return const WriteWhole();
  if (_baseChanged(
    merge,
    _lineupReader(current.data),
    _lineupReader(desired.data),
  )) {
    return const MergeConflict();
  }
  final lists = {
    for (final collection in lineupCollections)
      collection: [...lineupItems(current.data, collection)],
  };
  for (final entry in named) {
    final (:collection, :id) = entry!;
    final list = lists[collection]!;
    final index = list.indexWhere((item) => item['id'] == id);
    final wanted = _itemById(desired.data, collection, id);
    if (wanted == null) {
      if (index >= 0) list.removeAt(index);
    } else if (index >= 0) {
      list[index] = wanted;
    } else {
      list.add(wanted);
    }
  }
  final links = lists['links']!;
  final usedOrigins = {for (final link in links) link['originId']};
  final usedLandings = {for (final link in links) link['landingId']};
  return Merged(
    LineupGroupPayload(
      payloadVersion: current.payloadVersion,
      data: {
        ...current.data,
        'origins': [
          for (final origin in lists['origins']!)
            if (usedOrigins.contains(origin['id'])) origin,
        ],
        'landings': [
          for (final landing in lists['landings']!)
            if (usedLandings.contains(landing['id'])) landing,
        ],
        'links': links,
      },
    ),
  );
}

bool _baseChanged(
  FieldMerge merge,
  _Read Function(String field) current,
  _Read Function(String field) desired,
) {
  final base = merge.base;
  if (base == null) return false;
  for (final field in merge.fields) {
    if (field == placeField) continue;
    final now = current(field);
    final atBase = (present: base.containsKey(field), value: base[field]);
    if (!_same(now, atBase) && !_same(now, desired(field))) return true;
  }
  return false;
}

bool placeChanged(FieldMerge? merge, int currentSortIndex, int? sortIndex) {
  final base = merge?.base;
  if (merge == null || base == null || !merge.fields.contains(placeField)) {
    return false;
  }
  return base[placeField] != currentSortIndex && sortIndex != currentSortIndex;
}
