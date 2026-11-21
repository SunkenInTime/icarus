import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../rows.dart';

const libraryArea = 'library';

const lastSaveKey = 'last-save';

const _strategyAreaPrefix = 's/';

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

String strategyArea(String strategyPublicId) =>
    '$_strategyAreaPrefix${digestOf(strategyPublicId)}';

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
  String get name => '$_strategyAreaPrefix$digest';
}

final class ForeignArea extends StoreArea {
  const ForeignArea(this.name);

  @override
  final String name;
}

StoreArea readArea(String area) => switch (area) {
  libraryArea => const LibraryArea(),
  _
      when area.startsWith(_strategyAreaPrefix) &&
          _isDigest(area.substring(_strategyAreaPrefix.length)) =>
    StrategyArea(area.substring(_strategyAreaPrefix.length)),
  _ => ForeignArea(area),
};

sealed class StoreName {
  const StoreName();

  String get name;
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

final class UnknownKindName extends StoreName {
  const UnknownKindName(this.page, this.name);

  final String page;

  @override
  final String name;
}

final class LastSaveName extends StoreName {
  const LastSaveName();

  @override
  String get name => lastSaveKey;
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
      (LibraryArea(), ['summary', final digest]) when _isDigest(digest) =>
        SummaryName(digest),
      (LibraryArea(), ['folder', final digest]) when _isDigest(digest) =>
        FolderName(digest),
      (StrategyArea(), ['strategy']) => const HeaderName(),
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
      (LibraryArea(), [lastSaveKey]) => const LastSaveName(),
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
