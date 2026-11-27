import 'package:collection/collection.dart';

enum CloudRole {
  owner,
  editor,
  viewer;

  bool get edits => this != viewer;
}

sealed class StrategyRole {
  const StrategyRole();

  static StrategyRole ofWire(Object? wire) =>
      switch (CloudRole.values.asNameMap()[wire]) {
        final role? => RoleKnown(role),
        null => const RoleUnknown(),
      };
}

final class RoleKnown extends StrategyRole {
  const RoleKnown(this.role);

  final CloudRole role;

  @override
  bool operator ==(Object other) => other is RoleKnown && other.role == role;

  @override
  int get hashCode => role.hashCode;

  @override
  String toString() => 'RoleKnown(${role.name})';
}

final class RoleUnknown extends StrategyRole {
  const RoleUnknown();

  @override
  bool operator ==(Object other) => other is RoleUnknown;

  @override
  int get hashCode => (RoleUnknown).hashCode;

  @override
  String toString() => 'RoleUnknown';
}

final class PictureAsset {
  const PictureAsset({
    required this.provider,
    required this.uploadStatus,
    required this.fileExtension,
    this.mimeType,
    this.width,
    this.height,
    this.byteSize,
    this.uploadedAt,
    this.url,
    this.legacyStoragePath,
  });

  final String provider;
  final String uploadStatus;
  final String fileExtension;
  final String? mimeType;
  final int? width;
  final int? height;
  final int? byteSize;
  final DateTime? uploadedAt;
  final String? url;
  final String? legacyStoragePath;

  List<Object?> get _fields => [
    provider,
    uploadStatus,
    fileExtension,
    mimeType,
    width,
    height,
    byteSize,
    uploadedAt,
    url,
    legacyStoragePath,
  ];

  @override
  bool operator ==(Object other) =>
      other is PictureAsset &&
      const ListEquality<Object?>().equals(other._fields, _fields);

  @override
  int get hashCode => Object.hashAll(_fields);
}

bool samePictures(Map<String, PictureAsset> a, Map<String, PictureAsset> b) =>
    const MapEquality<String, PictureAsset>().equals(a, b);
