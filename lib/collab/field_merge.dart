import 'package:icarus/collab/canonical_json.dart';

/// What a patch merged by field changed (see docs/collaborative-editing.md):
/// the server writes only [fields] of the op's payload onto the row as it is
/// now, so a teammate's change to another field stays.
///
/// [base] holds each field's value as the client last saw it, keyed by
/// field; a field absent then has no entry. It is sent only with work that
/// did not stay connected from when it was made until it was sent, so the
/// server can refuse an edit that collides with a teammate's change made
/// meanwhile (see [withoutBase]).
final class FieldMerge {
  const FieldMerge({required this.fields, this.base});

  final List<String> fields;
  final Map<String, Object?>? base;

  /// This merge as sent by a client that stayed connected: last writer wins.
  FieldMerge withoutBase() => FieldMerge(fields: fields);

  /// This merge with [field]'s base set to [value] ([present] false: the
  /// field was absent), for every field in [values].
  FieldMerge withBaseValues(
    Map<String, ({bool present, Object? value})> values,
  ) {
    final base = this.base;
    if (base == null) return this;
    final next = <String, Object?>{};
    for (final field in fields) {
      final entry = values[field];
      if (entry != null) {
        if (entry.present) next[field] = entry.value;
      } else if (base.containsKey(field)) {
        next[field] = base[field];
      }
    }
    return FieldMerge(fields: fields, base: next);
  }

  Map<String, dynamic> toJson() => {
        'fields': fields,
        if (base case final base?)
          'base': [
            for (final field in fields)
              {
                'field': field,
                if (base.containsKey(field)) 'value': base[field],
              },
          ],
      };

  static FieldMerge? fromJson(Object? json) {
    if (json is! Map) return null;
    final fields = [
      for (final field in json['fields'] as List? ?? const []) field as String,
    ];
    final base = json['base'];
    return FieldMerge(
      fields: fields,
      base: base is List
          ? {
              for (final entry in base.cast<Map>())
                if (entry.containsKey('value'))
                  entry['field'] as String: entry['value'],
            }
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FieldMerge && cloudJsonEquivalent(toJson(), other.toJson());

  @override
  int get hashCode => canonicalCloudJsonEncode(toJson()).hashCode;
}

/// The merge field naming a row's place (its sortIndex) rather than its
/// payload. A merged patch always carries its place; the server moves the
/// row there only when its merge names this field.
const placeMergeField = '@sortIndex';

/// Keys of an element's data that say what it is. A merge never writes
/// them; an edit that changes one is sent as a whole item instead (the
/// server falls back the same way).
const _elementIdentityKeys = {'id', 'elementType', 'kind', 'type', 'data'};

/// Keys of an element's data that only make sense together, for a payload
/// of [kind] holding [data]: when any of a group changes, the merge names
/// all of them, so a teammate's half of the group never mixes with this
/// edit's.
List<Set<String>> _fieldGroups(Object? kind, Map<String, Object?> data) =>
    switch (kind) {
      // A view cone's handle sets its rotation and length together.
      'agent' || 'ability' => const [
          {'rotation', 'length'},
        ],
      'drawing' => const [
          {
            'listOfPoints',
            'lineStart',
            'lineEnd',
            'start',
            'end',
            'boundingBox',
          },
        ],
      // Resizing from the defending side moves the box as it scales it.
      'text' => const [
          {'position', 'size', 'fontSize', 'sizeVersion'},
        ],
      'image' => const [
          {'position', 'scale', 'sizeVersion'},
        ],
      // A custom rectangle resizes about its rotation, moving as it does.
      'utility' when data['type'] == 'customRectangle' => const [
          {'position', 'rotation', 'customWidth', 'customLength'},
        ],
      'utility' => const [
          {'rotation', 'length'},
        ],
      _ => const [],
    };

Map<String, Object?>? _dataOf(Object? payload) {
  if (payload is! Map) return null;
  final data = payload['data'];
  return data is Map ? Map<String, Object?>.from(data) : null;
}

/// Whether two maps agree on [key]. A key one lacks and the other holds as
/// null agree: models write their unset optional fields as null, so an older
/// payload that lacks one reads back with it, though nobody set it.
bool _sameKey(
  Map<String, Object?> left,
  Map<String, Object?> right,
  String key,
) =>
    cloudJsonEquivalent(left[key], right[key]);

/// The fields of an element's data that [desired] changes from [base]
/// (both cloud payloads), with every field it moves together, or null when
/// the edit cannot be merged by field: a different kind or payload version,
/// or a change of what the element is. Empty when only its place changed.
/// Both are compared as [normalize] leaves them (live sync fills in the
/// defaults of fields older payloads lack, so those never count as
/// changed).
List<String>? elementMergeFields(
  Object? base,
  Object? desired, {
  Object? Function(Object? payload) normalize = _asIs,
}) {
  base = normalize(base);
  desired = normalize(desired);
  if (base is! Map || desired is! Map) return null;
  if (base['kind'] != desired['kind'] ||
      base['payloadVersion'] != desired['payloadVersion']) {
    return null;
  }
  final baseData = _dataOf(base);
  final desiredData = _dataOf(desired);
  if (baseData == null || desiredData == null) return null;
  for (final key in _elementIdentityKeys) {
    if (!_sameKey(baseData, desiredData, key)) return null;
  }
  final changed = <String>{
    for (final key in {...baseData.keys, ...desiredData.keys})
      if (!_sameKey(baseData, desiredData, key)) key,
  };
  for (final group in _fieldGroups(desired['kind'], desiredData)) {
    if (changed.any(group.contains)) {
      changed.addAll(group.where(
        (key) => baseData.containsKey(key) || desiredData.containsKey(key),
      ));
    }
  }
  return changed.toList()..sort();
}

Object? _asIs(Object? payload) => payload;

const _lineupCollections = ['origins', 'landings', 'links'];

Map<String, Map<String, Object?>> _lineupItems(
  Map<String, Object?> data,
  String collection,
) {
  final items = data[collection];
  return {
    if (items is List)
      for (final item in items)
        if (item is Map && item['id'] is String)
          item['id'] as String: Map<String, Object?>.from(item),
  };
}

/// The items of a lineup group that [desired] changes from [base] (both
/// cloud payloads): `origins/<id>`, `landings/<id>`, `links/<id>` for each
/// one added, removed or changed. Null when the groups can't be merged by
/// item (another payload version or group). Compared as [normalize] leaves
/// them, as for [elementMergeFields].
List<String>? lineupMergeFields(
  Object? base,
  Object? desired, {
  Object? Function(Object? payload) normalize = _asIs,
}) {
  base = normalize(base);
  desired = normalize(desired);
  if (base is! Map || desired is! Map) return null;
  if (base['kind'] != desired['kind'] ||
      base['payloadVersion'] != desired['payloadVersion']) {
    return null;
  }
  final baseData = _dataOf(base);
  final desiredData = _dataOf(desired);
  if (baseData == null ||
      desiredData == null ||
      !cloudJsonEquivalent(baseData['id'], desiredData['id'])) {
    return null;
  }
  return [
    for (final collection in _lineupCollections)
      for (final id in {
        ..._lineupItems(baseData, collection).keys,
        ..._lineupItems(desiredData, collection).keys,
      }.toList()
        ..sort())
        if (!_sameItem(
          _lineupItems(baseData, collection)[id],
          _lineupItems(desiredData, collection)[id],
        ))
          '$collection/$id',
  ];
}

bool _sameItem(Object? left, Object? right) =>
    (left == null) == (right == null) && cloudJsonEquivalent(left, right);

/// Each of [fields]' value in [payload] (an element's, or a lineup group's
/// when [lineup]): what a merge's base records. A field [payload] lacks has
/// no entry.
Map<String, Object?> mergeBaseValues(
  Object? payload,
  List<String> fields, {
  required bool lineup,
}) {
  final values = <String, Object?>{};
  for (final field in fields) {
    final value = mergeFieldValue(payload, field, lineup: lineup);
    if (value.present) values[field] = value.value;
  }
  return values;
}

/// [field]'s value in [payload]: a key of an element's data, or an item of
/// a lineup group's.
({bool present, Object? value}) mergeFieldValue(
  Object? payload,
  String field, {
  required bool lineup,
}) {
  final data = _dataOf(payload);
  if (data == null) return (present: false, value: null);
  if (!lineup) {
    return (present: data.containsKey(field), value: data[field]);
  }
  final slash = field.indexOf('/');
  if (slash <= 0) return (present: false, value: null);
  final item =
      _lineupItems(data, field.substring(0, slash))[field.substring(slash + 1)];
  return (present: item != null, value: item);
}
