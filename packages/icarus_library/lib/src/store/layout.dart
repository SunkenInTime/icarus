import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../rows.dart';

const libraryArea = 'library';

const formatKey = 'format';

const storeFormat = 2;

const strategyAreaPrefix = 's/';

const _digestLength = 32;

String digestOf(String text) {
  final bytes = ByteData(text.length * 2);
  for (var i = 0; i < text.length; i++) {
    bytes.setUint16(i * 2, text.codeUnitAt(i), Endian.little);
  }
  return sha256
      .convert(bytes.buffer.asUint8List())
      .toString()
      .substring(0, _digestLength);
}

final _digest = RegExp(r'^[0-9a-f]{32}$');

bool _isDigest(String text) => _digest.hasMatch(text);

StrategyArea? strategyAreaNamed(String area) =>
    area.startsWith(strategyAreaPrefix) &&
        _isDigest(area.substring(strategyAreaPrefix.length))
    ? StrategyArea(area.substring(strategyAreaPrefix.length))
    : null;

String strategyArea(String strategyPublicId) =>
    '$strategyAreaPrefix${digestOf(strategyPublicId)}';

const longestName =
    'content/'.length + _digestLength + '/e/'.length + _digestLength;

sealed class StoreArea {
  const StoreArea();

  String get name;
}

final class LibraryArea extends StoreArea {
  const LibraryArea();

  @override
  String get name => libraryArea;
}

final class StrategyArea extends StoreArea {
  const StrategyArea(this.digest);

  final String digest;

  @override
  String get name => '$strategyAreaPrefix$digest';
}

sealed class StoreName {
  const StoreName();

  String get name;
}

final class FormatName extends StoreName {
  const FormatName();

  @override
  String get name => formatKey;
}

final class SummaryName extends StoreName {
  const SummaryName(this.digest);

  final String digest;

  @override
  String get name => 'summary/$digest';
}

final class FolderName extends StoreName {
  const FolderName(this.digest);

  final String digest;

  @override
  String get name => 'folder/$digest';
}

final class HeaderName extends StoreName {
  const HeaderName();

  @override
  String get name => 'strategy';
}

final class PageName extends StoreName {
  const PageName(this.digest);

  final String digest;

  @override
  String get name => 'page/$digest';
}

final class SettingsName extends StoreName {
  const SettingsName(this.digest);

  final String digest;

  @override
  String get name => 'settings/$digest';
}

final class ElementName extends StoreName {
  const ElementName(this.page, this.digest);

  final String page;
  final String digest;

  @override
  String get name => 'content/$page/e/$digest';
}

final class LineupName extends StoreName {
  const LineupName(this.page, this.digest);

  final String page;
  final String digest;

  @override
  String get name => 'content/$page/l/$digest';
}

final class CloudName extends StoreName {
  const CloudName();

  @override
  String get name => 'cloud';
}

final class NumbersName extends StoreName {
  const NumbersName();

  @override
  String get name => 'numbers';
}

final class WrittenName extends StoreName {
  const WrittenName();

  @override
  String get name => 'written';
}

final class MigrationName extends StoreName {
  const MigrationName();

  @override
  String get name => 'migration';
}

const placeDigits = 16;

final _place = RegExp(r'^[0-9]{16}$');

bool _isPlace(String text) =>
    _place.hasMatch(text) && text.compareTo('9007199254740991') <= 0;

String _numbered(int number) => number.toString().padLeft(placeDigits, '0');

const pendingPrefix = 'pending/';

final class PendingName extends StoreName {
  const PendingName(this.place);

  final int place;

  @override
  String get name => '$pendingPrefix${_numbered(place)}';
}

const attemptPrefix = 'attempt/';

final class AttemptName extends StoreName {
  const AttemptName(this.number);

  final int number;

  @override
  String get name => '$attemptPrefix${_numbered(number)}';
}

const landedPrefix = 'landed/';

final class LandedName extends StoreName {
  const LandedName(this.attempt, this.position);

  final int attempt;
  final int position;

  @override
  String get name =>
      '$landedPrefix${_numbered(attempt)}/${_numbered(position)}';
}

const readPrefix = 'read/';

final class HeaderReadName extends StoreName {
  const HeaderReadName();

  @override
  String get name => '${readPrefix}header';
}

final class PageReadName extends StoreName {
  const PageReadName(this.digest);

  final String digest;

  @override
  String get name => '${readPrefix}page/$digest';
}

final class UnknownKindName extends StoreName {
  const UnknownKindName(this.page, this.name);

  final String page;

  @override
  final String name;
}

final class ForeignName extends StoreName {
  const ForeignName(this.area, this.name);

  final String area;

  @override
  final String name;

  @override
  bool operator ==(Object other) =>
      other is ForeignName && other.area == area && other.name == name;

  @override
  int get hashCode => Object.hash(area, name);

  @override
  String toString() => 'ForeignName($area, $name)';
}

String pageContentPrefix(String pageDigest) => 'content/$pageDigest/';

StoreName readName(StoreArea area, String name) =>
    switch ((area, name.split('/'))) {
      (LibraryArea(), [formatKey]) => const FormatName(),
      (LibraryArea(), ['summary', final digest]) when _isDigest(digest) =>
        SummaryName(digest),
      (LibraryArea(), ['folder', final digest]) when _isDigest(digest) =>
        FolderName(digest),
      (LibraryArea(), ['numbers']) => const NumbersName(),
      (LibraryArea(), ['migration']) => const MigrationName(),
      (StrategyArea(), ['strategy']) => const HeaderName(),
      (StrategyArea(), ['cloud']) => const CloudName(),
      (StrategyArea(), ['written']) => const WrittenName(),
      (StrategyArea(), ['pending', final place]) when _isPlace(place) =>
        PendingName(int.parse(place)),
      (StrategyArea(), ['attempt', final number]) when _isPlace(number) =>
        AttemptName(int.parse(number)),
      (StrategyArea(), ['landed', final attempt, final position])
          when _isPlace(attempt) && _isPlace(position) =>
        LandedName(int.parse(attempt), int.parse(position)),
      (StrategyArea(), ['read', 'header']) => const HeaderReadName(),
      (StrategyArea(), ['read', 'page', final digest]) when _isDigest(digest) =>
        PageReadName(digest),
      (StrategyArea(), ['page', final digest]) when _isDigest(digest) =>
        PageName(digest),
      (StrategyArea(), ['settings', final digest]) when _isDigest(digest) =>
        SettingsName(digest),
      (StrategyArea(), ['content', final page, 'e', final digest])
          when _isDigest(page) && _isDigest(digest) =>
        ElementName(page, digest),
      (StrategyArea(), ['content', final page, 'l', final digest])
          when _isDigest(page) && _isDigest(digest) =>
        LineupName(page, digest),
      (StrategyArea(), ['content', final page, _, _]) when _isDigest(page) =>
        UnknownKindName(page, name),
      _ => ForeignName(area.name, name),
    };

StoreName nameOf(Row row) => switch (row) {
  StrategyRow() => const HeaderName(),
  FolderRow(:final publicId) => FolderName(digestOf(publicId)),
  PageRow(:final publicId) => PageName(digestOf(publicId)),
  PageSettingsRow(:final pagePublicId) => SettingsName(digestOf(pagePublicId)),
  ElementRow(:final pagePublicId, :final publicId) => ElementName(
    digestOf(pagePublicId),
    digestOf(publicId),
  ),
  LineupGroupRow(:final pagePublicId, :final publicId) => LineupName(
    digestOf(pagePublicId),
    digestOf(publicId),
  ),
};

bool namesId(String digest, String id) => digestOf(id) == digest;

bool isCloudName(StoreName name) => switch (name) {
  CloudName() ||
  PendingName() ||
  AttemptName() ||
  LandedName() ||
  HeaderReadName() ||
  PageReadName() => true,
  ForeignName(:final name) => isCloudKey(name),
  _ => false,
};

bool isCloudKey(String key) =>
    key == const CloudName().name ||
    key.startsWith(pendingPrefix) ||
    key.startsWith(attemptPrefix) ||
    key.startsWith(landedPrefix) ||
    key.startsWith(readPrefix);
