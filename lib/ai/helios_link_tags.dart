import 'package:flutter/foundation.dart';

@immutable
class HeliosLinkTag {
  const HeliosLinkTag({
    required this.label,
    required this.pageId,
    this.roundIndex,
    this.orderInRound,
  });

  final String label;
  final String pageId;
  final int? roundIndex;
  final int? orderInRound;

  String get dedupeKey =>
      '$pageId|$label|${roundIndex ?? ''}|${orderInRound ?? ''}';
}

@immutable
class HeliosParsedResponse {
  const HeliosParsedResponse({required this.text, required this.links});

  final String text;
  final List<HeliosLinkTag> links;
}

final RegExp _linkTagRegex = RegExp(r'@link\{([^}]*)\}');

// Supports values in a few forms:
// - key:"string"
// - key:'string'
// - key:123
// - key:bare-token
final RegExp _fieldRegex = RegExp(
  "(\\w+)\\s*:\\s*(?:\"((?:[^\"\\\\]|\\\\.)*)\"|'((?:[^'\\\\]|\\\\.)*)'|(-?\\d+)|([A-Za-z0-9_.\\-]+))",
);

HeliosParsedResponse parseHeliosLinkTags(String text) {
  final links = <HeliosLinkTag>[];
  final seen = <String>{};

  for (final match in _linkTagRegex.allMatches(text)) {
    final payload = match.group(1);
    if (payload == null) continue;

    final fields = parseHeliosLinkFields(payload);
    final label = fields['label'] as String?;
    final pageId = fields['pageId'] as String?;

    if (label == null || pageId == null) continue;
    final trimmedLabel = label.trim();
    final trimmedPageId = pageId.trim();
    if (trimmedLabel.isEmpty || trimmedPageId.isEmpty) continue;

    final tag = HeliosLinkTag(
      label: trimmedLabel,
      pageId: trimmedPageId,
      roundIndex: fields['roundIndex'] as int?,
      orderInRound: fields['orderInRound'] as int?,
    );

    if (!seen.add(tag.dedupeKey)) continue;
    links.add(tag);
  }

  final cleaned = _compactWhitespace(text.replaceAll(_linkTagRegex, ''));
  return HeliosParsedResponse(text: cleaned, links: links);
}

Map<String, Object?> parseHeliosLinkFields(String payload) {
  final fields = <String, Object?>{};
  for (final match in _fieldRegex.allMatches(payload)) {
    final key = match.group(1);
    if (key == null) continue;
    final stringValueDouble = match.group(2);
    final stringValueSingle = match.group(3);
    final intValue = match.group(4);
    final bareValue = match.group(5);

    if (stringValueDouble != null) {
      fields[key] = _unescape(stringValueDouble);
      continue;
    }
    if (stringValueSingle != null) {
      fields[key] = _unescape(stringValueSingle);
      continue;
    }
    if (intValue != null) {
      fields[key] = int.tryParse(intValue);
      continue;
    }
    if (bareValue != null) {
      fields[key] = bareValue;
    }
  }

  // Back-compat: sometimes the model emits an unkeyed label like:
  // @link{0:33 Sova > Sova, pageId:"..."}
  if (fields['label'] == null) {
    final label = _tryParseLeadingLabel(payload);
    if (label != null) fields['label'] = label;
  }

  return fields;
}

String? _tryParseLeadingLabel(String payload) {
  final trimmed = payload.trim();
  if (trimmed.isEmpty) return null;
  // If the payload starts with a normal key, there's no unkeyed label.
  if (RegExp(r'^(label|pageId|roundIndex|orderInRound)\s*:')
      .hasMatch(trimmed)) {
    return null;
  }
  final commaIndex = trimmed.indexOf(',');
  if (commaIndex <= 0) return null;

  final candidate = trimmed.substring(0, commaIndex).trim();
  if (candidate.isEmpty) return null;
  return _stripWrappingQuotes(candidate);
}

String _stripWrappingQuotes(String value) {
  final v = value.trim();
  if (v.length >= 2) {
    final first = v[0];
    final last = v[v.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return v.substring(1, v.length - 1);
    }
  }
  return v;
}

String _unescape(String value) {
  return value.replaceAll(r'\"', '"').replaceAll(r'\\', '\\');
}

String _compactWhitespace(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return trimmed;
  return trimmed
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r' +\n'), '\n')
      .replaceAll(RegExp(r'\n +'), '\n');
}
