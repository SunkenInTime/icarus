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
  }) : data = frozenJsonObject(data);

  static Decoded<ElementPayload> decode(Object? json) =>
      JsonFields.read(json, 'element payload', (fields) {
        final kind = ElementKind.named(fields.json['kind']);
        if (kind == null) fields.reject('unknown kind ${fields.json['kind']}');
        final payloadVersion = fields.whole('payloadVersion');
        final data = fields.object('data');
        return () => ElementPayload(
          kind: kind!,
          payloadVersion: payloadVersion,
          data: data,
        );
      });

  final ElementKind kind;
  final int payloadVersion;
  final Map<String, Object?> data;

  bool get isReadable => payloadVersion <= newestElementPayloadVersion;

  Map<String, Object?> toJson() => {
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
  }) : data = frozenJsonObject(data);

  static Decoded<LineupGroupPayload> decode(Object? json) =>
      JsonFields.read(json, 'lineup group payload', (fields) {
        if (fields.json['kind'] != lineupGroupPayloadKind) {
          fields.reject('kind ${fields.json['kind']} is not a lineup group');
        }
        final payloadVersion = fields.whole('payloadVersion');
        final data = fields.object('data');
        return () =>
            LineupGroupPayload(payloadVersion: payloadVersion, data: data);
      });

  final int payloadVersion;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
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
  });

  static Decoded<PageSettings> decode(Object? json) =>
      JsonFields.read(json, 'page settings', (fields) {
        final agentSize = fields.number('agentSize');
        final abilitySize = fields.number('abilitySize');
        final neutral = fields.boolean('useNeutralTeamColors');
        return () => PageSettings(
          agentSize: agentSize,
          abilitySize: abilitySize,
          useNeutralTeamColors: neutral,
        );
      });

  final double agentSize;
  final double abilitySize;
  final bool useNeutralTeamColors;

  Map<String, Object?> toJson() => {
    'agentSize': agentSize,
    'abilitySize': abilitySize,
    'useNeutralTeamColors': useNeutralTeamColors,
  };

  @override
  bool operator ==(Object other) =>
      other is PageSettings &&
      other.agentSize == agentSize &&
      other.abilitySize == abilitySize &&
      other.useNeutralTeamColors == useNeutralTeamColors;

  @override
  int get hashCode => Object.hash(agentSize, abilitySize, useNeutralTeamColors);
}

final class ThemePalette {
  const ThemePalette({
    required this.base,
    required this.detail,
    required this.highlight,
  });

  static Decoded<ThemePalette> decode(Object? json) =>
      JsonFields.read(json, 'theme palette', (fields) {
        final base = fields.string('base');
        final detail = fields.string('detail');
        final highlight = fields.string('highlight');
        return () =>
            ThemePalette(base: base, detail: detail, highlight: highlight);
      });

  final String base;
  final String detail;
  final String highlight;

  Map<String, Object?> toJson() => {
    'base': base,
    'detail': detail,
    'highlight': highlight,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemePalette &&
      other.base == base &&
      other.detail == detail &&
      other.highlight == highlight;

  @override
  int get hashCode => Object.hash(base, detail, highlight);
}
