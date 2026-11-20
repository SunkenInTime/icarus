import 'dart:convert';

import '../rows.dart';

const libraryArea = 'library';

const journalArea = 'journal';

const journalKey = 'edit';

const recoveredPrefix = 'recovered/';

String recoveredKey(String receipt) => '$recoveredPrefix${segment(receipt)}';

const summaryPrefix = 'summary/';

const folderPrefix = 'folder/';

const headerKey = 'strategy';

const pagePrefix = 'page/';

const settingsPrefix = 'settings/';

const contentPrefix = 'content/';

const _element = 'element';

const _lineup = 'lineup';

String strategyArea(String strategyPublicId) =>
    'strategy/${segment(strategyPublicId)}';

String summaryKey(String strategyPublicId) =>
    '$summaryPrefix${segment(strategyPublicId)}';

String folderKey(String folderPublicId) =>
    '$folderPrefix${segment(folderPublicId)}';

String pageKey(String pagePublicId) => '$pagePrefix${segment(pagePublicId)}';

String settingsKey(String pagePublicId) =>
    '$settingsPrefix${segment(pagePublicId)}';

String pageContentPrefix(String pagePublicId) =>
    '$contentPrefix${segment(pagePublicId)}/';

String elementKey(String pagePublicId, String elementPublicId) =>
    '${pageContentPrefix(pagePublicId)}$_element/${segment(elementPublicId)}';

String lineupGroupKey(String pagePublicId, String lineupPublicId) =>
    '${pageContentPrefix(pagePublicId)}$_lineup/${segment(lineupPublicId)}';

String segment(String id) => Uri.encodeComponent(id);

String? idOf(String segment) {
  final bytes = <int>[];
  for (var at = 0; at < segment.length; at++) {
    final unit = segment.codeUnitAt(at);
    if (unit != 0x25) {
      if (unit > 0x7f) return null;
      bytes.add(unit);
      continue;
    }
    if (at + 2 >= segment.length) return null;
    final byte = int.tryParse(segment.substring(at + 1, at + 3), radix: 16);
    if (byte == null) return null;
    bytes.add(byte);
    at += 2;
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

String rowKey(Row row) => switch (row) {
  StrategyRow() => headerKey,
  FolderRow(:final publicId) => folderKey(publicId),
  PageRow(:final publicId) => pageKey(publicId),
  PageSettingsRow(:final pagePublicId) => settingsKey(pagePublicId),
  ElementRow(:final pagePublicId, :final publicId) => elementKey(
    pagePublicId,
    publicId,
  ),
  LineupGroupRow(:final pagePublicId, :final publicId) => lineupGroupKey(
    pagePublicId,
    publicId,
  ),
};

String rowArea(String strategyPublicId, Row row) => switch (row) {
  FolderRow() => libraryArea,
  _ => strategyArea(strategyPublicId),
};

sealed class ContentKey {
  const ContentKey(this.pageSegment, this.idSegment);

  static ContentKey? parse(String key) {
    if (!key.startsWith(contentPrefix)) return null;
    final parts = key.substring(contentPrefix.length).split('/');
    if (parts.length != 3) return null;
    return switch (parts[1]) {
      _element => ElementContentKey(parts[0], parts[2]),
      _lineup => LineupContentKey(parts[0], parts[2]),
      _ => OtherContentKey(parts[0], parts[2]),
    };
  }

  final String pageSegment;
  final String idSegment;
}

final class ElementContentKey extends ContentKey {
  const ElementContentKey(super.pageSegment, super.idSegment);
}

final class LineupContentKey extends ContentKey {
  const LineupContentKey(super.pageSegment, super.idSegment);
}

final class OtherContentKey extends ContentKey {
  const OtherContentKey(super.pageSegment, super.idSegment);
}
