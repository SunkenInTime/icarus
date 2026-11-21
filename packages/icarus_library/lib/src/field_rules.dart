import 'json.dart';
import 'payloads.dart';

const elementIdentityKeys = ['id', 'elementType', 'kind', 'type', 'data'];

sealed class TypeMatch {
  const TypeMatch();

  bool matches(Map<String, Object?> data);

  String get wireName;
}

final class AnyType extends TypeMatch {
  const AnyType();

  @override
  bool matches(Map<String, Object?> data) => true;

  @override
  String get wireName => '*';
}

final class OfType extends TypeMatch {
  const OfType(this.type);

  final String type;

  @override
  bool matches(Map<String, Object?> data) => data['type'] == type;

  @override
  String get wireName => type;
}

final class NotOfType extends TypeMatch {
  const NotOfType(this.type);

  final String type;

  @override
  bool matches(Map<String, Object?> data) => data['type'] != type;

  @override
  String get wireName => '!$type';
}

final class FieldGroup {
  const FieldGroup(this.kind, this.fields, {this.type = const AnyType()});

  final ElementKind kind;
  final TypeMatch type;
  final Set<String> fields;

  bool appliesTo(ElementKind kind, Map<String, Object?> data) =>
      kind == this.kind && type.matches(data);
}

const fieldGroups = [
  FieldGroup(ElementKind.agent, {'rotation', 'length'}),
  FieldGroup(ElementKind.ability, {'rotation', 'length'}),
  FieldGroup(ElementKind.drawing, {
    'listOfPoints',
    'lineStart',
    'lineEnd',
    'start',
    'end',
    'boundingBox',
  }),
  FieldGroup(ElementKind.text, {'position', 'size', 'fontSize', 'sizeVersion'}),
  FieldGroup(ElementKind.image, {'position', 'scale', 'sizeVersion'}),
  FieldGroup(ElementKind.utility, {
    'position',
    'rotation',
    'customWidth',
    'customLength',
  }, type: OfType('customRectangle')),
  FieldGroup(ElementKind.utility, {
    'rotation',
    'length',
  }, type: NotOfType('customRectangle')),
];

sealed class EmptyValue {
  const EmptyValue();
}

final class ClearedBy extends EmptyValue {
  const ClearedBy(this.value);

  final Object value;
}

final class NeverCleared extends EmptyValue {
  const NeverCleared();
}

const _placedKinds = {
  ElementKind.agent,
  ElementKind.ability,
  ElementKind.text,
  ElementKind.image,
  ElementKind.utility,
};

final class LaterField {
  const LaterField(this.field, this.level, this.kinds, this.empty);

  final String field;
  final int level;
  final Set<ElementKind> kinds;
  final EmptyValue empty;
}

const laterElementFields = [
  LaterField('caption', 1, _placedKinds, ClearedBy('')),
  LaterField('wallPath', 2, {ElementKind.ability}, ClearedBy(<Object?>[])),
  LaterField('mapDoor', 3, {ElementKind.utility}, NeverCleared()),
  LaterField('isZone', 4, {ElementKind.utility}, NeverCleared()),
];

const pictureIdField = 'assetId';

LaterField? laterField(ElementKind kind, String field) {
  for (final entry in laterElementFields) {
    if (entry.field == field && entry.kinds.contains(kind)) return entry;
  }
  return null;
}

sealed class FieldDefault {
  const FieldDefault(this.field, this.value);

  final String field;
  final Object value;

  void fill(Map<String, Object?> object);
}

final class DefaultInside extends FieldDefault {
  const DefaultInside(this.container, super.field, super.value);

  final String container;

  @override
  void fill(Map<String, Object?> object) {
    switch (object[container]) {
      case final Map<String, Object?> inner:
        inner.putIfAbsent(field, () => value);
      case final JsonObject inner:
        object[container] = inner.toJson()..putIfAbsent(field, () => value);
    }
  }
}

final class DefaultBeside extends FieldDefault {
  const DefaultBeside(this.sibling, super.field, super.value);

  final String sibling;

  @override
  void fill(Map<String, Object?> object) {
    if (object.containsKey(sibling)) object.putIfAbsent(field, () => value);
  }
}

const fieldDefaults = <FieldDefault>[
  DefaultInside('visualState', 'showVisionCone', true),
  DefaultBeside('state', 'weapon', 'none'),
];

Object? withFieldDefaults(Object? json) => switch (json) {
  JsonObject() || JsonList() => withFieldDefaults(plainJson(json)),
  List<Object?>() => [for (final item in json) withFieldDefaults(item)],
  Map<Object?, Object?>() => _objectWithDefaults(json),
  _ => json,
};

Map<String, Object?> _objectWithDefaults(Map<Object?, Object?> json) {
  final object = <String, Object?>{
    for (final MapEntry(:key, :value) in json.entries)
      key.toString(): withFieldDefaults(value),
  };
  for (final rule in fieldDefaults) {
    rule.fill(object);
  }
  return object;
}

Map<String, Object?> fieldRulesJson() => {
  'elementIdentityKeys': elementIdentityKeys,
  'fieldGroups': [
    for (final group in fieldGroups)
      {
        'kind': group.kind.name,
        'type': group.type.wireName,
        'fields': group.fields.toList()..sort(),
      },
  ],
  'pictureIdField': pictureIdField,
  'laterElementFields': [
    for (final entry in laterElementFields)
      {
        'field': entry.field,
        'level': entry.level,
        'kinds': [
          for (final kind in ElementKind.values)
            if (entry.kinds.contains(kind)) kind.name,
        ],
        'empty': switch (entry.empty) {
          ClearedBy(:final value) => {'clearedBy': value},
          NeverCleared() => 'neverCleared',
        },
      },
  ],
  'fieldDefaults': [
    for (final rule in fieldDefaults)
      switch (rule) {
        DefaultInside(:final container) => {
          'inside': container,
          'field': rule.field,
          'value': rule.value,
        },
        DefaultBeside(:final sibling) => {
          'beside': sibling,
          'field': rule.field,
          'value': rule.value,
        },
      },
  ],
};
