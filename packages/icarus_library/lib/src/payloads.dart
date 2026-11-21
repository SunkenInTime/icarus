import 'json.dart';
import 'wire.dart';

enum ElementKind {
  agent,
  ability,
  drawing,
  text,
  image,
  utility;

  static ElementKind? named(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

const newestElementPayloadVersion = 3;

const lineupGroupPayloadKind = 'lineups';

const lineupGroupPayloadVersion = 1;

final class ElementPayload {
  ElementPayload({
    required this.kind,
    required this.payloadVersion,
    required Map<String, Object?> data,
    Map<String, Object?> unknownFields = const {},
  }) : data = jsonObject(data),
       unknownFields = jsonObject(unknownFields);

  const ElementPayload._read({
    required this.kind,
    required this.payloadVersion,
    required this.data,
    required this.unknownFields,
  });

  static Decoded<ElementPayload> decode(Object? json) =>
      JsonFields.read(json, 'element payload', (fields) {
        final kind = ElementKind.named(fields.json['kind']);
        if (kind == null) fields.reject('unknown kind ${fields.json['kind']}');
        final payloadVersion = fields.whole('payloadVersion');
        final data = fields.object('data');
        final unknown = fields.rest(const {'kind', 'payloadVersion', 'data'});
        return () => ElementPayload._read(
          kind: kind!,
          payloadVersion: payloadVersion,
          data: data,
          unknownFields: unknown,
        );
      });

  final ElementKind kind;
  final int payloadVersion;
  final JsonObject data;
  final JsonObject unknownFields;

  bool get isReadable => payloadVersion <= newestElementPayloadVersion;

  ElementPayload withData(Map<String, Object?> data) => ElementPayload._read(
    kind: kind,
    payloadVersion: payloadVersion,
    data: jsonObject(data),
    unknownFields: unknownFields,
  );

  Map<String, Object?> toJson() => {
    ...viewsOf(unknownFields),
    'kind': kind.name,
    'payloadVersion': payloadVersion,
    'data': data,
  };

  Map<String, Object?> toPlainJson() => {
    ...unknownFields.toJson(),
    'kind': kind.name,
    'payloadVersion': payloadVersion,
    'data': data.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ElementPayload && sameJson(toJson(), other.toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}

final class LineupGroupPayload {
  LineupGroupPayload({
    required this.payloadVersion,
    required Map<String, Object?> data,
    Map<String, Object?> unknownFields = const {},
  }) : data = jsonObject(data),
       unknownFields = jsonObject(unknownFields);

  const LineupGroupPayload._read({
    required this.payloadVersion,
    required this.data,
    required this.unknownFields,
  });

  static Decoded<LineupGroupPayload> decode(Object? json) =>
      JsonFields.read(json, 'lineup group payload', (fields) {
        if (fields.json['kind'] != lineupGroupPayloadKind) {
          fields.reject('kind ${fields.json['kind']} is not a lineup group');
        }
        final payloadVersion = fields.whole('payloadVersion');
        if (payloadVersion != lineupGroupPayloadVersion) {
          fields.reject(
            'payload version $payloadVersion is not one this build reads',
          );
        }
        final data = fields.object('data');
        final unknown = fields.rest(const {'kind', 'payloadVersion', 'data'});
        return () => LineupGroupPayload._read(
          payloadVersion: payloadVersion,
          data: data,
          unknownFields: unknown,
        );
      });

  final int payloadVersion;
  final JsonObject data;
  final JsonObject unknownFields;

  LineupGroupPayload withData(Map<String, Object?> data) =>
      LineupGroupPayload._read(
        payloadVersion: payloadVersion,
        data: jsonObject(data),
        unknownFields: unknownFields,
      );

  Map<String, Object?> toJson() => {
    ...viewsOf(unknownFields),
    'kind': lineupGroupPayloadKind,
    'payloadVersion': payloadVersion,
    'data': data,
  };

  Map<String, Object?> toPlainJson() => {
    ...unknownFields.toJson(),
    'kind': lineupGroupPayloadKind,
    'payloadVersion': payloadVersion,
    'data': data.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is LineupGroupPayload && sameJson(toJson(), other.toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}

final class PageSettings {
  const PageSettings({
    required this.agentSize,
    required this.abilitySize,
    required this.useNeutralTeamColors,
  }) : unknownFields = JsonObject.empty;

  PageSettings.keeping({
    required this.agentSize,
    required this.abilitySize,
    required this.useNeutralTeamColors,
    required Map<String, Object?> unknownFields,
  }) : unknownFields = jsonObject(unknownFields);

  static Decoded<PageSettings> decode(Object? json) =>
      JsonFields.read(json, 'page settings', (fields) {
        final agentSize = fields.number('agentSize');
        final abilitySize = fields.number('abilitySize');
        final neutral = fields.boolean('useNeutralTeamColors');
        final unknown = fields.rest(const {
          'agentSize',
          'abilitySize',
          'useNeutralTeamColors',
        });
        return () => PageSettings.keeping(
          agentSize: agentSize,
          abilitySize: abilitySize,
          useNeutralTeamColors: neutral,
          unknownFields: unknown.raw,
        );
      });

  final double agentSize;
  final double abilitySize;
  final bool useNeutralTeamColors;
  final JsonObject unknownFields;

  Map<String, Object?> toJson() => {
    ...viewsOf(unknownFields),
    'agentSize': agentSize,
    'abilitySize': abilitySize,
    'useNeutralTeamColors': useNeutralTeamColors,
  };

  @override
  bool operator ==(Object other) =>
      other is PageSettings && sameJson(toJson(), other.toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}

final class ThemePalette {
  const ThemePalette({
    required this.base,
    required this.detail,
    required this.highlight,
  }) : unknownFields = JsonObject.empty;

  ThemePalette.keeping({
    required this.base,
    required this.detail,
    required this.highlight,
    required Map<String, Object?> unknownFields,
  }) : unknownFields = jsonObject(unknownFields);

  static Decoded<ThemePalette> decode(Object? json) =>
      JsonFields.read(json, 'theme palette', (fields) {
        final base = fields.string('base');
        final detail = fields.string('detail');
        final highlight = fields.string('highlight');
        final unknown = fields.rest(const {'base', 'detail', 'highlight'});
        return () => ThemePalette.keeping(
          base: base,
          detail: detail,
          highlight: highlight,
          unknownFields: unknown.raw,
        );
      });

  final String base;
  final String detail;
  final String highlight;
  final JsonObject unknownFields;

  Map<String, Object?> toJson() => {
    ...viewsOf(unknownFields),
    'base': base,
    'detail': detail,
    'highlight': highlight,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemePalette && sameJson(toJson(), other.toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}

ElementPayload elementPayloadAdopting(
  ElementPayload payload,
  Map<String, Object?> trusted,
) => ElementPayload._read(
  kind: payload.kind,
  payloadVersion: payload.payloadVersion,
  data: adoptJsonObject(trusted),
  unknownFields: payload.unknownFields,
);

LineupGroupPayload lineupPayloadAdopting(
  LineupGroupPayload payload,
  Map<String, Object?> trusted,
) => LineupGroupPayload._read(
  payloadVersion: payload.payloadVersion,
  data: adoptJsonObject(trusted),
  unknownFields: payload.unknownFields,
);
