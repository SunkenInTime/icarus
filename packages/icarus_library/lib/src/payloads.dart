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
  }) : data = frozenJsonObject(data),
       unknownFields = frozenJsonObject(unknownFields);

  static Decoded<ElementPayload> decode(Object? json) =>
      JsonFields.read(json, 'element payload', (fields) {
        final kind = ElementKind.named(fields.json['kind']);
        if (kind == null) fields.reject('unknown kind ${fields.json['kind']}');
        final payloadVersion = fields.whole('payloadVersion');
        final data = fields.object('data');
        final unknown = fields.rest(const {'kind', 'payloadVersion', 'data'});
        return () => ElementPayload(
          kind: kind!,
          payloadVersion: payloadVersion,
          data: data,
          unknownFields: unknown,
        );
      });

  final ElementKind kind;
  final int payloadVersion;
  final Map<String, Object?> data;
  final Map<String, Object?> unknownFields;

  bool get isReadable => payloadVersion <= newestElementPayloadVersion;

  ElementPayload withData(Map<String, Object?> data) => ElementPayload(
    kind: kind,
    payloadVersion: payloadVersion,
    data: data,
    unknownFields: unknownFields,
  );

  Map<String, Object?> toJson() => {
    ...unknownFields,
    'kind': kind.name,
    'payloadVersion': payloadVersion,
    'data': data,
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
  }) : data = frozenJsonObject(data),
       unknownFields = frozenJsonObject(unknownFields);

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
        return () => LineupGroupPayload(
          payloadVersion: payloadVersion,
          data: data,
          unknownFields: unknown,
        );
      });

  final int payloadVersion;
  final Map<String, Object?> data;
  final Map<String, Object?> unknownFields;

  LineupGroupPayload withData(Map<String, Object?> data) => LineupGroupPayload(
    payloadVersion: payloadVersion,
    data: data,
    unknownFields: unknownFields,
  );

  Map<String, Object?> toJson() => {
    ...unknownFields,
    'kind': lineupGroupPayloadKind,
    'payloadVersion': payloadVersion,
    'data': data,
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
    this.unknownFields = const {},
  });

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
        return () => PageSettings(
          agentSize: agentSize,
          abilitySize: abilitySize,
          useNeutralTeamColors: neutral,
          unknownFields: unknown,
        );
      });

  final double agentSize;
  final double abilitySize;
  final bool useNeutralTeamColors;
  final Map<String, Object?> unknownFields;

  Map<String, Object?> toJson() => {
    ...unknownFields,
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
    this.unknownFields = const {},
  });

  static Decoded<ThemePalette> decode(Object? json) =>
      JsonFields.read(json, 'theme palette', (fields) {
        final base = fields.string('base');
        final detail = fields.string('detail');
        final highlight = fields.string('highlight');
        final unknown = fields.rest(const {'base', 'detail', 'highlight'});
        return () => ThemePalette(
          base: base,
          detail: detail,
          highlight: highlight,
          unknownFields: unknown,
        );
      });

  final String base;
  final String detail;
  final String highlight;
  final Map<String, Object?> unknownFields;

  Map<String, Object?> toJson() => {
    ...unknownFields,
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
