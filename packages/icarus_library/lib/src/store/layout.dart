import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../rows.dart';

const libraryArea = 'library';

const journalArea = 'journal';

const journalKey = 'edit';

const recoveredPrefix = 'recovered/';

const summaryPrefix = 'summary/';

const folderPrefix = 'folder/';

const headerKey = 'strategy';

const pagePrefix = 'page/';

const settingsPrefix = 'settings/';

const contentPrefix = 'content/';

const _element = 'element';

const _lineup = 'lineup';

String strategyArea(String strategyPublicId) =>
    'strategy/${sha1.convert(utf8.encode(strategyPublicId))}';

sealed class IdProblem {
  const IdProblem();
}

final class EmptyId extends IdProblem {
  const EmptyId();

  @override
  String toString() => 'EmptyId()';
}

final class LoneSurrogate extends IdProblem {
  const LoneSurrogate(this.at);

  final int at;

  @override
  String toString() => 'LoneSurrogate($at)';
}

final class KeyLongerThan extends IdProblem {
  const KeyLongerThan(this.limit);

  final int limit;

  @override
  String toString() => 'KeyLongerThan($limit)';
}

sealed class IdSegment {
  const IdSegment();
}

final class Storable extends IdSegment {
  const Storable(this.segment);

  final String segment;
}

final class NotStorable extends IdSegment {
  const NotStorable(this.problem);

  final IdProblem problem;
}

bool _unreserved(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5a) ||
    (unit >= 0x61 && unit <= 0x7a) ||
    unit == 0x2d ||
    unit == 0x2e ||
    unit == 0x5f ||
    unit == 0x7e;

const _hex = '0123456789ABCDEF';

IdSegment encodeId(String id) {
  if (id.isEmpty) return const NotStorable(EmptyId());
  final out = StringBuffer();
  for (var at = 0; at < id.length; at++) {
    final unit = id.codeUnitAt(at);
    final int point;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      final low = at + 1 < id.length ? id.codeUnitAt(at + 1) : 0;
      if (low < 0xdc00 || low > 0xdfff) return NotStorable(LoneSurrogate(at));
      point = 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00);
      at++;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return NotStorable(LoneSurrogate(at));
    } else {
      point = unit;
    }
    if (point < 0x80 && _unreserved(point)) {
      out.writeCharCode(point);
      continue;
    }
    for (final byte in utf8.encode(String.fromCharCode(point))) {
      out
        ..write('%')
        ..write(_hex[byte >> 4])
        ..write(_hex[byte & 0xf]);
    }
  }
  return Storable(out.toString());
}

String segment(String id) => switch (encodeId(id)) {
  Storable(:final segment) => segment,
  NotStorable(:final problem) => throw StateError(
    'the id "$id" is not storable ($problem); admit it before keying it',
  ),
};

int? _hexValue(int unit) => switch (unit) {
  >= 0x30 && <= 0x39 => unit - 0x30,
  >= 0x41 && <= 0x46 => unit - 0x41 + 10,
  _ => null,
};

String? _strictUtf8(List<int> bytes) {
  final out = StringBuffer();
  var at = 0;
  while (at < bytes.length) {
    final first = bytes[at];
    final (int length, int minimum, int bits) = switch (first) {
      < 0x80 => (1, 0, first),
      >= 0xc2 && < 0xe0 => (2, 0x80, first & 0x1f),
      >= 0xe0 && < 0xf0 => (3, 0x800, first & 0x0f),
      >= 0xf0 && < 0xf5 => (4, 0x10000, first & 0x07),
      _ => (0, 0, 0),
    };
    if (length == 0 || at + length > bytes.length) return null;
    var point = bits;
    for (var i = 1; i < length; i++) {
      final next = bytes[at + i];
      if (next & 0xc0 != 0x80) return null;
      point = (point << 6) | (next & 0x3f);
    }
    if (point < minimum || point > 0x10ffff) return null;
    if (point >= 0xd800 && point <= 0xdfff) return null;
    out.writeCharCode(point);
    at += length;
  }
  return out.toString();
}

sealed class SegmentRead {
  const SegmentRead();
}

final class CanonicalId extends SegmentRead {
  const CanonicalId(this.id);

  final String id;
}

final class ForeignSegment extends SegmentRead {
  const ForeignSegment();
}

SegmentRead readSegment(String raw) {
  final bytes = <int>[];
  for (var at = 0; at < raw.length; at++) {
    final unit = raw.codeUnitAt(at);
    if (unit != 0x25) {
      if (!_unreserved(unit)) return const ForeignSegment();
      bytes.add(unit);
      continue;
    }
    if (at + 2 >= raw.length) return const ForeignSegment();
    final high = _hexValue(raw.codeUnitAt(at + 1));
    final low = _hexValue(raw.codeUnitAt(at + 2));
    if (high == null || low == null) return const ForeignSegment();
    bytes.add(high << 4 | low);
    at += 2;
  }
  final id = _strictUtf8(bytes);
  if (id == null) return const ForeignSegment();
  return switch (encodeId(id)) {
    Storable(:final segment) when segment == raw => CanonicalId(id),
    _ => const ForeignSegment(),
  };
}

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

String recoveredKey(String attempt) => '$recoveredPrefix$attempt';

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

List<String> rowIds(Row row) => switch (row) {
  StrategyRow(:final publicId) || FolderRow(:final publicId) => [publicId],
  PageRow(:final publicId) => [publicId],
  PageSettingsRow(:final pagePublicId) => [pagePublicId],
  ElementRow(:final pagePublicId, :final publicId) ||
  LineupGroupRow(
    :final pagePublicId,
    :final publicId,
  ) => [pagePublicId, publicId],
};

sealed class StrategyAreaKey {
  const StrategyAreaKey();
}

sealed class LibraryAreaKey {
  const LibraryAreaKey();
}

sealed class JournalAreaKey {
  const JournalAreaKey();
}

final class ForeignKey
    implements StrategyAreaKey, LibraryAreaKey, JournalAreaKey {
  const ForeignKey(this.area, this.key);

  final String area;
  final String key;

  @override
  bool operator ==(Object other) =>
      other is ForeignKey && other.area == area && other.key == key;

  @override
  int get hashCode => Object.hash(area, key);

  @override
  String toString() => 'ForeignKey($area, $key)';
}

final class HeaderAt extends StrategyAreaKey {
  const HeaderAt();
}

final class PageAt extends StrategyAreaKey {
  const PageAt(this.pagePublicId);

  final String pagePublicId;
}

final class SettingsAt extends StrategyAreaKey {
  const SettingsAt(this.pagePublicId);

  final String pagePublicId;
}

final class ElementAt extends StrategyAreaKey {
  const ElementAt(this.pagePublicId, this.publicId);

  final String pagePublicId;
  final String publicId;
}

final class LineupAt extends StrategyAreaKey {
  const LineupAt(this.pagePublicId, this.publicId);

  final String pagePublicId;
  final String publicId;
}

final class UnknownKindAt extends StrategyAreaKey {
  const UnknownKindAt(this.pagePublicId, this.key);

  final String pagePublicId;
  final String key;
}

final class SummaryAt extends LibraryAreaKey {
  const SummaryAt(this.strategyPublicId);

  final String strategyPublicId;
}

final class FolderAt extends LibraryAreaKey {
  const FolderAt(this.folderPublicId);

  final String folderPublicId;
}

final class RecordAt extends JournalAreaKey {
  const RecordAt();
}

final class RecoveredAt extends JournalAreaKey {
  const RecoveredAt(this.attempt);

  final String attempt;
}

String? _idAfter(String key, String prefix) => switch (key.startsWith(prefix)
    ? readSegment(key.substring(prefix.length))
    : const ForeignSegment()) {
  CanonicalId(:final id) => id,
  ForeignSegment() => null,
};

StrategyAreaKey readStrategyKey(String area, String key) {
  if (key == headerKey) return const HeaderAt();
  if (_idAfter(key, pagePrefix) case final id?) return PageAt(id);
  if (_idAfter(key, settingsPrefix) case final id?) return SettingsAt(id);
  if (key.startsWith(contentPrefix)) {
    final parts = key.substring(contentPrefix.length).split('/');
    if (parts.length == 3) {
      final page = readSegment(parts[0]);
      final kind = readSegment(parts[1]);
      final id = readSegment(parts[2]);
      switch ((page, kind, id)) {
        case (CanonicalId(id: final page), _, CanonicalId(:final id))
            when parts[1] == _element:
          return ElementAt(page, id);
        case (CanonicalId(id: final page), _, CanonicalId(:final id))
            when parts[1] == _lineup:
          return LineupAt(page, id);
        case (CanonicalId(id: final page), CanonicalId(), CanonicalId()):
          return UnknownKindAt(page, key);
        case _:
          break;
      }
    }
  }
  return ForeignKey(area, key);
}

LibraryAreaKey readLibraryKey(String key) {
  if (_idAfter(key, summaryPrefix) case final id?) return SummaryAt(id);
  if (_idAfter(key, folderPrefix) case final id?) return FolderAt(id);
  return ForeignKey(libraryArea, key);
}

final _attempt = RegExp(r'^[0-9a-f]{32}$');

JournalAreaKey readJournalKey(String key) {
  if (key == journalKey) return const RecordAt();
  if (key.startsWith(recoveredPrefix)) {
    final attempt = key.substring(recoveredPrefix.length);
    if (_attempt.hasMatch(attempt)) return RecoveredAt(attempt);
  }
  return ForeignKey(journalArea, key);
}
