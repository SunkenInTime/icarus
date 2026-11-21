import 'package:collection/collection.dart';

import 'json.dart';
import 'payloads.dart';
import 'wire.dart';

const placeField = '@sortIndex';

final class FieldMerge {
  FieldMerge({required List<String> fields, Map<String, Object?>? base})
    : fields = List.unmodifiable(fields),
      base = base == null ? null : jsonObject(base);

  static Decoded<FieldMerge> decode(
    Object? json,
  ) => JsonFields.read(json, 'merge', (fields) {
    final names = fields.json['fields'];
    final base = fields.json['base'];
    if (names is! List<Object?> || names.any((name) => name is! String)) {
      fields.reject('expected "fields" to be strings');
    }
    if (base != null &&
        (base is! List<Object?> ||
            base.any(
              (entry) =>
                  entry is! Map<String, Object?> || entry['field'] is! String,
            ))) {
      fields.reject('expected "base" to be a list of fields');
    } else if (base is List<Object?> && names is List<Object?>) {
      final based = [
        for (final entry in base.cast<Map<String, Object?>>()) entry['field'],
      ];
      if (based.toSet().length != based.length ||
          based.length != names.length ||
          !const SetEquality<Object?>().equals(based.toSet(), names.toSet())) {
        fields.reject('expected "base" to name each field once');
      }
    }
    return () => FieldMerge(
      fields: (names! as List<Object?>).cast<String>(),
      base: base is List<Object?>
          ? {
              for (final entry in base.cast<Map<String, Object?>>())
                if (entry.containsKey('value'))
                  entry['field']! as String: entry['value'],
            }
          : null,
    );
  });

  final List<String> fields;
  final JsonObject? base;

  Map<String, Object?> toJson() =>
      plainJson(toJsonView())! as Map<String, Object?>;

  Map<String, Object?> toJsonView() => {
    'fields': fields,
    if (base case final base?)
      'base': [
        for (final field in fields)
          {'field': field, if (base.containsKey(field)) 'value': base[field]},
      ],
  };

  @override
  bool operator ==(Object other) =>
      other is FieldMerge && sameJson(toJsonView(), other.toJsonView());

  @override
  int get hashCode => canonicalJson(toJsonView()).hashCode;
}

enum OpType {
  strategyPatch('strategy.patch'),
  pageAdd('page.add'),
  pagePatch('page.patch'),
  pageDelete('page.delete'),
  pageReorder('page.reorder'),
  pageSettingsPatch('pageContent.patch'),
  elementAdd('element.add'),
  elementPatch('element.patch'),
  elementDelete('element.delete'),
  elementReorder('element.reorder'),
  lineupGroupAdd('lineup.add'),
  lineupGroupPatch('lineup.patch'),
  lineupGroupDelete('lineup.delete'),
  lineupGroupReorder('lineup.reorder');

  const OpType(this.wireName);

  final String wireName;

  static OpType? named(Object? wireName) {
    for (final type in values) {
      if (type.wireName == wireName) return type;
    }
    return null;
  }
}

sealed class StrategyOp {
  const StrategyOp({required this.opId});

  static Decoded<StrategyOp> decode(Object? json) =>
      JsonFields.read(json, 'op', (op) {
        final opId = op.string('opId');
        final type = OpType.named(op.json['type']);
        if (type == null) op.reject('unknown op type ${op.json['type']}');
        final build = switch (type) {
          null => null,
          OpType.strategyPatch => _strategyPatch(opId, op),
          OpType.pageAdd => _pageAdd(opId, op),
          OpType.pagePatch => _pagePatch(opId, op),
          OpType.pageDelete => _pageDelete(opId, op),
          OpType.pageReorder => _pageReorder(opId, op),
          OpType.pageSettingsPatch => _pageSettingsPatch(opId, op),
          OpType.elementAdd => _elementAdd(opId, op),
          OpType.elementPatch => _elementPatch(opId, op),
          OpType.elementDelete => _elementDelete(opId, op),
          OpType.elementReorder => _elementReorder(opId, op),
          OpType.lineupGroupAdd => _lineupGroupAdd(opId, op),
          OpType.lineupGroupPatch => _lineupGroupPatch(opId, op),
          OpType.lineupGroupDelete => _lineupGroupDelete(opId, op),
          OpType.lineupGroupReorder => _lineupGroupReorder(opId, op),
        };
        return () => build!();
      });

  final String opId;

  OpType get type;

  Map<String, Object?> toJson() =>
      plainJson(toJsonView())! as Map<String, Object?>;

  Map<String, Object?> toJsonView() => {
    'opId': opId,
    'type': type.wireName,
    ..._fieldsJson(),
  };

  Map<String, Object?> _fieldsJson();

  @override
  bool operator ==(Object other) =>
      other is StrategyOp && sameJson(toJsonView(), other.toJsonView());

  @override
  int get hashCode => canonicalJson(toJsonView()).hashCode;
}

typedef _Build = StrategyOp Function();

ValueEdit<T> _valueEdit<T>(
  JsonFields payload,
  String key,
  String clearKey,
  T? Function() value,
) {
  final clear = payload.optionalBoolean(clearKey) ?? false;
  final setTo = payload.has(key) ? value() : null;
  if (clear && payload.has(key)) payload.reject('both sets and clears "$key"');
  return switch ((clear, setTo)) {
    (true, _) => ClearValue<T>(),
    (false, final T setTo?) => SetValue<T>(setTo),
    (false, null) => KeepValue<T>(),
  };
}

typedef _StrategyPayload = (
  String?,
  String?,
  ValueEdit<String>,
  ValueEdit<ThemePalette>,
);

Decoded<_StrategyPayload> _strategyPayload(Object? json) =>
    JsonFields.read(json, 'strategy patch payload', (payload) {
      final name = payload.optionalString('name');
      final mapData = payload.optionalString('mapData');
      final themeProfile = _valueEdit(
        payload,
        'themeProfileId',
        'clearThemeProfileId',
        () => payload.string('themeProfileId'),
      );
      final palette = _valueEdit(
        payload,
        'themeOverridePalette',
        'clearThemeOverridePalette',
        () => payload.decoded('themeOverridePalette', ThemePalette.decode),
      );
      return () => (name, mapData, themeProfile, palette);
    });

_Build _strategyPatch(String opId, JsonFields op) {
  final payload = op.decoded('payload', _strategyPayload);
  final expected = op.whole('expectedStrategyRevision');
  return () {
    final (name, mapData, themeProfile, palette) = payload!;
    return StrategyPatchOp(
      opId: opId,
      expectedStrategyRevision: expected,
      name: name,
      mapData: mapData,
      themeProfile: themeProfile,
      themeOverridePalette: palette,
    );
  };
}

typedef _PageFields = (String?, bool?, bool?, PageSettings?);

Decoded<_PageFields> _pageFields(Object? json, {required bool settings}) =>
    JsonFields.read(json, 'page payload', (payload) {
      if (!settings && payload.has('settings')) {
        payload.reject('a page patch cannot carry settings');
      }
      final name = payload.optionalString('name');
      final isAutoNamed = payload.optionalBoolean('isAutoNamed');
      final isAttack = payload.optionalBoolean('isAttack');
      final pageSettings = payload.optionalDecoded(
        'settings',
        PageSettings.decode,
      );
      return () => (name, isAutoNamed, isAttack, pageSettings);
    });

_Build _pageAdd(String opId, JsonFields op) {
  final payload = op.decoded(
    'payload',
    (json) => _pageFields(json, settings: true),
  );
  final pagePublicId = op.string('pagePublicId');
  final sortIndex = op.whole('sortIndex');
  final expected = op.whole('expectedStrategyRevision');
  final copyFrom = op.optionalString('copyContentFromPagePublicId');
  return () {
    final (name, isAutoNamed, isAttack, settings) = payload!;
    return PageAddOp(
      opId: opId,
      pagePublicId: pagePublicId,
      name: name,
      isAutoNamed: isAutoNamed,
      isAttack: isAttack,
      settings: settings,
      sortIndex: sortIndex,
      expectedStrategyRevision: expected,
      copyContentFromPagePublicId: copyFrom,
    );
  };
}

_Build _pagePatch(String opId, JsonFields op) {
  final payload = op.decoded(
    'payload',
    (json) => _pageFields(json, settings: false),
  );
  final pagePublicId = op.string('pagePublicId');
  final expected = op.whole('expectedPageRevision');
  return () {
    final (name, isAutoNamed, isAttack, _) = payload!;
    return PagePatchOp(
      opId: opId,
      pagePublicId: pagePublicId,
      name: name,
      isAutoNamed: isAutoNamed,
      isAttack: isAttack,
      expectedPageRevision: expected,
    );
  };
}

_Build _pageDelete(String opId, JsonFields op) {
  final pagePublicId = op.string('pagePublicId');
  final expected = op.whole('expectedStrategyRevision');
  return () => PageDeleteOp(
    opId: opId,
    pagePublicId: pagePublicId,
    expectedStrategyRevision: expected,
  );
}

_Build _pageReorder(String opId, JsonFields op) {
  final pagePublicId = op.string('pagePublicId');
  final sortIndex = op.whole('sortIndex');
  final expected = op.whole('expectedStrategyRevision');
  return () => PageReorderOp(
    opId: opId,
    pagePublicId: pagePublicId,
    sortIndex: sortIndex,
    expectedStrategyRevision: expected,
  );
}

_Build _pageSettingsPatch(String opId, JsonFields op) {
  final pagePublicId = op.string('pagePublicId');
  final settings = op.decoded('settings', PageSettings.decode);
  final expected = op.whole('expectedPageContentRevision');
  return () => PageSettingsPatchOp(
    opId: opId,
    pagePublicId: pagePublicId,
    settings: settings!,
    expectedPageSettingsRevision: expected,
  );
}

_Build _elementAdd(String opId, JsonFields op) {
  final elementPublicId = op.string('elementPublicId');
  final pagePublicId = op.string('pagePublicId');
  final payload = op.decoded('payload', ElementPayload.decode);
  final sortIndex = op.whole('sortIndex');
  final expected = op.optionalWhole('expectedElementRevision');
  return () => ElementAddOp(
    opId: opId,
    elementPublicId: elementPublicId,
    pagePublicId: pagePublicId,
    payload: payload!,
    sortIndex: sortIndex,
    expectedElementRevision: expected,
  );
}

_Build _elementPatch(String opId, JsonFields op) {
  final elementPublicId = op.string('elementPublicId');
  final pagePublicId = op.optionalString('pagePublicId');
  final payload = op.optionalDecoded('payload', ElementPayload.decode);
  final sortIndex = op.optionalWhole('sortIndex');
  final expected = op.whole('expectedElementRevision');
  final merge = op.optionalDecoded('merge', FieldMerge.decode);
  return () => ElementPatchOp(
    opId: opId,
    elementPublicId: elementPublicId,
    pagePublicId: pagePublicId,
    payload: payload,
    sortIndex: sortIndex,
    expectedElementRevision: expected,
    merge: merge,
  );
}

_Build _elementDelete(String opId, JsonFields op) {
  final elementPublicId = op.string('elementPublicId');
  final pagePublicId = op.string('pagePublicId');
  final expected = op.whole('expectedElementRevision');
  final lastWriterWins = op.optionalBoolean('lastWriterWins') ?? false;
  return () => ElementDeleteOp(
    opId: opId,
    elementPublicId: elementPublicId,
    pagePublicId: pagePublicId,
    expectedElementRevision: expected,
    lastWriterWins: lastWriterWins,
  );
}

_Build _elementReorder(String opId, JsonFields op) {
  final elementPublicId = op.string('elementPublicId');
  final pagePublicId = op.string('pagePublicId');
  final sortIndex = op.whole('sortIndex');
  final expected = op.whole('expectedElementRevision');
  return () => ElementReorderOp(
    opId: opId,
    elementPublicId: elementPublicId,
    pagePublicId: pagePublicId,
    sortIndex: sortIndex,
    expectedElementRevision: expected,
  );
}

_Build _lineupGroupAdd(String opId, JsonFields op) {
  final lineupPublicId = op.string('lineupPublicId');
  final pagePublicId = op.string('pagePublicId');
  final payload = op.decoded('payload', LineupGroupPayload.decode);
  final sortIndex = op.whole('sortIndex');
  final expected = op.optionalWhole('expectedLineupRevision');
  return () => LineupGroupAddOp(
    opId: opId,
    lineupPublicId: lineupPublicId,
    pagePublicId: pagePublicId,
    payload: payload!,
    sortIndex: sortIndex,
    expectedLineupRevision: expected,
  );
}

_Build _lineupGroupPatch(String opId, JsonFields op) {
  final lineupPublicId = op.string('lineupPublicId');
  final pagePublicId = op.optionalString('pagePublicId');
  final payload = op.optionalDecoded('payload', LineupGroupPayload.decode);
  final sortIndex = op.optionalWhole('sortIndex');
  final expected = op.whole('expectedLineupRevision');
  final merge = op.optionalDecoded('merge', FieldMerge.decode);
  return () => LineupGroupPatchOp(
    opId: opId,
    lineupPublicId: lineupPublicId,
    pagePublicId: pagePublicId,
    payload: payload,
    sortIndex: sortIndex,
    expectedLineupRevision: expected,
    merge: merge,
  );
}

_Build _lineupGroupDelete(String opId, JsonFields op) {
  final lineupPublicId = op.string('lineupPublicId');
  final pagePublicId = op.string('pagePublicId');
  final expected = op.whole('expectedLineupRevision');
  final lastWriterWins = op.optionalBoolean('lastWriterWins') ?? false;
  return () => LineupGroupDeleteOp(
    opId: opId,
    lineupPublicId: lineupPublicId,
    pagePublicId: pagePublicId,
    expectedLineupRevision: expected,
    lastWriterWins: lastWriterWins,
  );
}

_Build _lineupGroupReorder(String opId, JsonFields op) {
  final lineupPublicId = op.string('lineupPublicId');
  final pagePublicId = op.string('pagePublicId');
  final sortIndex = op.whole('sortIndex');
  final expected = op.whole('expectedLineupRevision');
  return () => LineupGroupReorderOp(
    opId: opId,
    lineupPublicId: lineupPublicId,
    pagePublicId: pagePublicId,
    sortIndex: sortIndex,
    expectedLineupRevision: expected,
  );
}

sealed class ValueEdit<T> {
  const ValueEdit();
}

final class KeepValue<T> extends ValueEdit<T> {
  const KeepValue();

  @override
  bool operator ==(Object other) => other is KeepValue<T>;

  @override
  int get hashCode => 0;
}

final class SetValue<T> extends ValueEdit<T> {
  const SetValue(this.value);

  final T value;

  @override
  bool operator ==(Object other) =>
      other is SetValue<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

T? edited<T>(ValueEdit<T> edit, T? current) => switch (edit) {
  KeepValue() => current,
  SetValue(:final value) => value,
  ClearValue() => null,
};

final class ClearValue<T> extends ValueEdit<T> {
  const ClearValue();

  @override
  bool operator ==(Object other) => other is ClearValue<T>;

  @override
  int get hashCode => 1;
}

final class StrategyPatchOp extends StrategyOp {
  const StrategyPatchOp({
    required super.opId,
    required this.expectedStrategyRevision,
    this.name,
    this.mapData,
    this.themeProfile = const KeepValue(),
    this.themeOverridePalette = const KeepValue(),
  });

  final String? name;
  final String? mapData;
  final ValueEdit<String> themeProfile;
  final ValueEdit<ThemePalette> themeOverridePalette;
  final int expectedStrategyRevision;

  @override
  OpType get type => OpType.strategyPatch;

  @override
  Map<String, Object?> _fieldsJson() => {
    'payload': {
      if (name != null) 'name': name,
      if (mapData != null) 'mapData': mapData,
      ...switch (themeProfile) {
        KeepValue() => const <String, Object?>{},
        SetValue(:final value) => {'themeProfileId': value},
        ClearValue() => const {'clearThemeProfileId': true},
      },
      ...switch (themeOverridePalette) {
        KeepValue() => const <String, Object?>{},
        SetValue(:final value) => {'themeOverridePalette': value.toJsonView()},
        ClearValue() => const {'clearThemeOverridePalette': true},
      },
    },
    'expectedStrategyRevision': expectedStrategyRevision,
  };
}

final class PageAddOp extends StrategyOp {
  const PageAddOp({
    required super.opId,
    required this.pagePublicId,
    required this.sortIndex,
    required this.expectedStrategyRevision,
    this.name,
    this.isAutoNamed,
    this.isAttack,
    this.settings,
    this.copyContentFromPagePublicId,
  });

  final String pagePublicId;
  final String? name;
  final bool? isAutoNamed;
  final bool? isAttack;
  final PageSettings? settings;
  final int sortIndex;
  final int expectedStrategyRevision;
  final String? copyContentFromPagePublicId;

  @override
  OpType get type => OpType.pageAdd;

  @override
  Map<String, Object?> _fieldsJson() => {
    'pagePublicId': pagePublicId,
    'payload': {
      if (name != null) 'name': name,
      if (isAutoNamed != null) 'isAutoNamed': isAutoNamed,
      if (settings case final settings?) 'settings': settings.toJsonView(),
      if (isAttack != null) 'isAttack': isAttack,
    },
    'sortIndex': sortIndex,
    'expectedStrategyRevision': expectedStrategyRevision,
    if (copyContentFromPagePublicId != null)
      'copyContentFromPagePublicId': copyContentFromPagePublicId,
  };
}

final class PagePatchOp extends StrategyOp {
  const PagePatchOp({
    required super.opId,
    required this.pagePublicId,
    required this.expectedPageRevision,
    this.name,
    this.isAutoNamed,
    this.isAttack,
  });

  final String pagePublicId;
  final String? name;
  final bool? isAutoNamed;
  final bool? isAttack;
  final int expectedPageRevision;

  @override
  OpType get type => OpType.pagePatch;

  @override
  Map<String, Object?> _fieldsJson() => {
    'pagePublicId': pagePublicId,
    'payload': {
      if (name != null) 'name': name,
      if (isAutoNamed != null) 'isAutoNamed': isAutoNamed,
      if (isAttack != null) 'isAttack': isAttack,
    },
    'expectedPageRevision': expectedPageRevision,
  };
}

final class PageDeleteOp extends StrategyOp {
  const PageDeleteOp({
    required super.opId,
    required this.pagePublicId,
    required this.expectedStrategyRevision,
  });

  final String pagePublicId;
  final int expectedStrategyRevision;

  @override
  OpType get type => OpType.pageDelete;

  @override
  Map<String, Object?> _fieldsJson() => {
    'pagePublicId': pagePublicId,
    'expectedStrategyRevision': expectedStrategyRevision,
  };
}

final class PageReorderOp extends StrategyOp {
  const PageReorderOp({
    required super.opId,
    required this.pagePublicId,
    required this.sortIndex,
    required this.expectedStrategyRevision,
  });

  final String pagePublicId;
  final int sortIndex;
  final int expectedStrategyRevision;

  @override
  OpType get type => OpType.pageReorder;

  @override
  Map<String, Object?> _fieldsJson() => {
    'pagePublicId': pagePublicId,
    'sortIndex': sortIndex,
    'expectedStrategyRevision': expectedStrategyRevision,
  };
}

final class PageSettingsPatchOp extends StrategyOp {
  const PageSettingsPatchOp({
    required super.opId,
    required this.pagePublicId,
    required this.settings,
    required this.expectedPageSettingsRevision,
  });

  final String pagePublicId;
  final PageSettings settings;
  final int expectedPageSettingsRevision;

  @override
  OpType get type => OpType.pageSettingsPatch;

  @override
  Map<String, Object?> _fieldsJson() => {
    'pagePublicId': pagePublicId,
    'settings': settings.toJsonView(),
    'expectedPageContentRevision': expectedPageSettingsRevision,
  };
}

final class ElementAddOp extends StrategyOp {
  const ElementAddOp({
    required super.opId,
    required this.elementPublicId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
    this.expectedElementRevision,
  });

  final String elementPublicId;
  final String pagePublicId;
  final ElementPayload payload;
  final int sortIndex;
  final int? expectedElementRevision;

  @override
  OpType get type => OpType.elementAdd;

  @override
  Map<String, Object?> _fieldsJson() => {
    'elementPublicId': elementPublicId,
    'pagePublicId': pagePublicId,
    'payload': payload.toJsonView(),
    'sortIndex': sortIndex,
    if (expectedElementRevision != null)
      'expectedElementRevision': expectedElementRevision,
  };
}

final class ElementPatchOp extends StrategyOp {
  const ElementPatchOp({
    required super.opId,
    required this.elementPublicId,
    required this.expectedElementRevision,
    this.pagePublicId,
    this.payload,
    this.sortIndex,
    this.merge,
  });

  final String elementPublicId;
  final String? pagePublicId;
  final ElementPayload? payload;
  final int? sortIndex;
  final int expectedElementRevision;
  final FieldMerge? merge;

  @override
  OpType get type => OpType.elementPatch;

  @override
  Map<String, Object?> _fieldsJson() => {
    'elementPublicId': elementPublicId,
    if (pagePublicId != null) 'pagePublicId': pagePublicId,
    if (payload case final payload?) 'payload': payload.toJsonView(),
    if (sortIndex != null) 'sortIndex': sortIndex,
    'expectedElementRevision': expectedElementRevision,
    if (merge case final merge?) 'merge': merge.toJsonView(),
  };
}

final class ElementDeleteOp extends StrategyOp {
  const ElementDeleteOp({
    required super.opId,
    required this.elementPublicId,
    required this.pagePublicId,
    required this.expectedElementRevision,
    this.lastWriterWins = false,
  });

  final String elementPublicId;
  final String pagePublicId;
  final int expectedElementRevision;
  final bool lastWriterWins;

  @override
  OpType get type => OpType.elementDelete;

  @override
  Map<String, Object?> _fieldsJson() => {
    'elementPublicId': elementPublicId,
    'pagePublicId': pagePublicId,
    'expectedElementRevision': expectedElementRevision,
    if (lastWriterWins) 'lastWriterWins': true,
  };
}

final class ElementReorderOp extends StrategyOp {
  const ElementReorderOp({
    required super.opId,
    required this.elementPublicId,
    required this.pagePublicId,
    required this.sortIndex,
    required this.expectedElementRevision,
  });

  final String elementPublicId;
  final String pagePublicId;
  final int sortIndex;
  final int expectedElementRevision;

  @override
  OpType get type => OpType.elementReorder;

  @override
  Map<String, Object?> _fieldsJson() => {
    'elementPublicId': elementPublicId,
    'pagePublicId': pagePublicId,
    'sortIndex': sortIndex,
    'expectedElementRevision': expectedElementRevision,
  };
}

final class LineupGroupAddOp extends StrategyOp {
  const LineupGroupAddOp({
    required super.opId,
    required this.lineupPublicId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
    this.expectedLineupRevision,
  });

  final String lineupPublicId;
  final String pagePublicId;
  final LineupGroupPayload payload;
  final int sortIndex;
  final int? expectedLineupRevision;

  @override
  OpType get type => OpType.lineupGroupAdd;

  @override
  Map<String, Object?> _fieldsJson() => {
    'lineupPublicId': lineupPublicId,
    'pagePublicId': pagePublicId,
    'payload': payload.toJsonView(),
    'sortIndex': sortIndex,
    if (expectedLineupRevision != null)
      'expectedLineupRevision': expectedLineupRevision,
  };
}

final class LineupGroupPatchOp extends StrategyOp {
  const LineupGroupPatchOp({
    required super.opId,
    required this.lineupPublicId,
    required this.expectedLineupRevision,
    this.pagePublicId,
    this.payload,
    this.sortIndex,
    this.merge,
  });

  final String lineupPublicId;
  final String? pagePublicId;
  final LineupGroupPayload? payload;
  final int? sortIndex;
  final int expectedLineupRevision;
  final FieldMerge? merge;

  @override
  OpType get type => OpType.lineupGroupPatch;

  @override
  Map<String, Object?> _fieldsJson() => {
    'lineupPublicId': lineupPublicId,
    if (pagePublicId != null) 'pagePublicId': pagePublicId,
    if (payload case final payload?) 'payload': payload.toJsonView(),
    if (sortIndex != null) 'sortIndex': sortIndex,
    'expectedLineupRevision': expectedLineupRevision,
    if (merge case final merge?) 'merge': merge.toJsonView(),
  };
}

final class LineupGroupDeleteOp extends StrategyOp {
  const LineupGroupDeleteOp({
    required super.opId,
    required this.lineupPublicId,
    required this.pagePublicId,
    required this.expectedLineupRevision,
    this.lastWriterWins = false,
  });

  final String lineupPublicId;
  final String pagePublicId;
  final int expectedLineupRevision;
  final bool lastWriterWins;

  @override
  OpType get type => OpType.lineupGroupDelete;

  @override
  Map<String, Object?> _fieldsJson() => {
    'lineupPublicId': lineupPublicId,
    'pagePublicId': pagePublicId,
    'expectedLineupRevision': expectedLineupRevision,
    if (lastWriterWins) 'lastWriterWins': true,
  };
}

final class LineupGroupReorderOp extends StrategyOp {
  const LineupGroupReorderOp({
    required super.opId,
    required this.lineupPublicId,
    required this.pagePublicId,
    required this.sortIndex,
    required this.expectedLineupRevision,
  });

  final String lineupPublicId;
  final String pagePublicId;
  final int sortIndex;
  final int expectedLineupRevision;

  @override
  OpType get type => OpType.lineupGroupReorder;

  @override
  Map<String, Object?> _fieldsJson() => {
    'lineupPublicId': lineupPublicId,
    'pagePublicId': pagePublicId,
    'sortIndex': sortIndex,
    'expectedLineupRevision': expectedLineupRevision,
  };
}
