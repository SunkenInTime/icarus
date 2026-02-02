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
final RegExp _fieldRegex = RegExp(
  r'(\w+)\s*:\s*(?:"((?:[^"\\]|\\.)*)"|(-?\d+))',
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
    final stringValue = match.group(2);
    final intValue = match.group(3);
    if (stringValue != null) {
      fields[key] = _unescape(stringValue);
    } else if (intValue != null) {
      fields[key] = int.tryParse(intValue);
    }
  }
  return fields;
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
