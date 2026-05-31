import 'package:hive_ce/hive.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';

enum CloudMediaJobState { pendingUpload, pendingAttach, failed }

String normalizeImageExtension(String extension) {
  if (extension.isEmpty) {
    return extension;
  }
  return extension.startsWith('.')
      ? extension.toLowerCase()
      : '.${extension.toLowerCase()}';
}

String mimeTypeForImageExtension(String extension) {
  switch (normalizeImageExtension(extension)) {
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.bmp':
      return 'image/bmp';
    default:
      return 'application/octet-stream';
  }
}

class CloudMediaUploadJob extends HiveObject {
  CloudMediaUploadJob({
    required this.jobId,
    required this.strategyPublicId,
    required this.assetPublicId,
    required this.fileExtension,
    required this.mimeType,
    required this.state,
    required this.attempts,
    required this.updatedAt,
    this.width,
    this.height,
    this.byteSize,
    this.provider,
    this.uploadId,
    this.objectKey,
    this.storageId,
    this.etag,
    this.uploadUrlExpiresAt,
    this.lastError,
  });

  final String jobId;
  final String strategyPublicId;
  final String assetPublicId;
  final String fileExtension;
  final String mimeType;
  final int? width;
  final int? height;
  final int? byteSize;
  final String? provider;
  final String? uploadId;
  final String? objectKey;
  final String? storageId;
  final String? etag;
  final DateTime? uploadUrlExpiresAt;
  final CloudMediaJobState state;
  final int attempts;
  final String? lastError;
  final DateTime updatedAt;

  bool get isFailed => state == CloudMediaJobState.failed;

  bool get hasUploadedRemoteObject {
    if (provider == 'r2') {
      return uploadId != null && objectKey != null;
    }
    return storageId != null;
  }

  CloudMediaUploadJob copyWith({
    String? jobId,
    String? strategyPublicId,
    String? assetPublicId,
    String? fileExtension,
    String? mimeType,
    int? width,
    int? height,
    Object? byteSize = _noChange,
    Object? provider = _noChange,
    Object? uploadId = _noChange,
    Object? objectKey = _noChange,
    Object? storageId = _noChange,
    Object? etag = _noChange,
    Object? uploadUrlExpiresAt = _noChange,
    CloudMediaJobState? state,
    int? attempts,
    Object? lastError = _noChange,
    DateTime? updatedAt,
  }) {
    return CloudMediaUploadJob(
      jobId: jobId ?? this.jobId,
      strategyPublicId: strategyPublicId ?? this.strategyPublicId,
      assetPublicId: assetPublicId ?? this.assetPublicId,
      fileExtension: fileExtension ?? this.fileExtension,
      mimeType: mimeType ?? this.mimeType,
      width: width ?? this.width,
      height: height ?? this.height,
      byteSize:
          identical(byteSize, _noChange) ? this.byteSize : byteSize as int?,
      provider:
          identical(provider, _noChange) ? this.provider : provider as String?,
      uploadId:
          identical(uploadId, _noChange) ? this.uploadId : uploadId as String?,
      objectKey: identical(objectKey, _noChange)
          ? this.objectKey
          : objectKey as String?,
      storageId: identical(storageId, _noChange)
          ? this.storageId
          : storageId as String?,
      etag: identical(etag, _noChange) ? this.etag : etag as String?,
      uploadUrlExpiresAt: identical(uploadUrlExpiresAt, _noChange)
          ? this.uploadUrlExpiresAt
          : uploadUrlExpiresAt as DateTime?,
      state: state ?? this.state,
      attempts: attempts ?? this.attempts,
      lastError: identical(lastError, _noChange)
          ? this.lastError
          : lastError as String?,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class CloudImageUploadIntent {
  const CloudImageUploadIntent({
    required this.provider,
    required this.uploadId,
    required this.objectKey,
    required this.uploadUrl,
    required this.requiredHeaders,
    required this.expiresAt,
    required this.maxBytes,
  });

  final String provider;
  final String uploadId;
  final String objectKey;
  final String uploadUrl;
  final Map<String, String> requiredHeaders;
  final DateTime expiresAt;
  final int maxBytes;

  factory CloudImageUploadIntent.fromJson(Map<String, dynamic> json) {
    final headers = json['requiredHeaders'];
    return CloudImageUploadIntent(
      provider: json['provider'] as String? ?? 'r2',
      uploadId: json['uploadId'] as String,
      objectKey: json['objectKey'] as String,
      uploadUrl: json['uploadUrl'] as String,
      requiredHeaders: headers is Map
          ? headers.map((key, value) => MapEntry('$key', '$value'))
          : const <String, String>{},
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['expiresAt'] as num).toInt(),
      ),
      maxBytes: (json['maxBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

Map<String, dynamic> cloudImagePayloadFromPlacedImage(PlacedImage image) {
  return Map<String, dynamic>.from(image.toJson());
}

Map<String, dynamic> cloudLineupPayload(LineUp lineup) {
  return {
    ...lineup.toJson(),
    'images': [
      for (final image in lineup.images) image.toJson(),
    ],
  };
}

Set<String> collectStrategyImageAssetIds(StrategyDataLike strategy) {
  final assetIds = <String>{};
  for (final page in strategy.pages) {
    for (final image in page.imageData) {
      assetIds.add(image.id);
    }
    for (final lineup in page.lineUps) {
      for (final image in lineup.images) {
        assetIds.add(image.id);
      }
    }
  }
  return assetIds;
}

abstract class StrategyDataLike {
  Iterable<StrategyPageLike> get pages;
}

abstract class StrategyPageLike {
  Iterable<PlacedImage> get imageData;
  Iterable<LineUp> get lineUps;
}

const _noChange = Object();
