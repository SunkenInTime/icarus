import 'package:hive_ce/hive.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';

enum CloudMediaOwnerType { element, lineup }

enum CloudMediaJobState { pendingUpload, pendingAttach, failed }

String normalizeImageExtension(String extension) {
  if (extension.isEmpty) {
    return extension;
  }
  return extension.startsWith('.') ? extension.toLowerCase() : '.${extension.toLowerCase()}';
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
    required this.pagePublicId,
    required this.ownerType,
    required this.ownerPublicId,
    required this.assetPublicId,
    required this.fileExtension,
    required this.mimeType,
    required this.state,
    required this.attempts,
    required this.updatedAt,
    this.width,
    this.height,
    this.storageId,
    this.lastError,
  });

  final String jobId;
  final String strategyPublicId;
  final String pagePublicId;
  final CloudMediaOwnerType ownerType;
  final String ownerPublicId;
  final String assetPublicId;
  final String fileExtension;
  final String mimeType;
  final int? width;
  final int? height;
  final String? storageId;
  final CloudMediaJobState state;
  final int attempts;
  final String? lastError;
  final DateTime updatedAt;

  bool get isFailed => state == CloudMediaJobState.failed;

  CloudMediaUploadJob copyWith({
    String? jobId,
    String? strategyPublicId,
    String? pagePublicId,
    CloudMediaOwnerType? ownerType,
    String? ownerPublicId,
    String? assetPublicId,
    String? fileExtension,
    String? mimeType,
    int? width,
    int? height,
    Object? storageId = _noChange,
    CloudMediaJobState? state,
    int? attempts,
    Object? lastError = _noChange,
    DateTime? updatedAt,
  }) {
    return CloudMediaUploadJob(
      jobId: jobId ?? this.jobId,
      strategyPublicId: strategyPublicId ?? this.strategyPublicId,
      pagePublicId: pagePublicId ?? this.pagePublicId,
      ownerType: ownerType ?? this.ownerType,
      ownerPublicId: ownerPublicId ?? this.ownerPublicId,
      assetPublicId: assetPublicId ?? this.assetPublicId,
      fileExtension: fileExtension ?? this.fileExtension,
      mimeType: mimeType ?? this.mimeType,
      width: width ?? this.width,
      height: height ?? this.height,
      storageId:
          identical(storageId, _noChange) ? this.storageId : storageId as String?,
      state: state ?? this.state,
      attempts: attempts ?? this.attempts,
      lastError:
          identical(lastError, _noChange) ? this.lastError : lastError as String?,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

Map<String, dynamic> cloudImagePayloadFromPlacedImage(PlacedImage image) {
  final payload = Map<String, dynamic>.from(image.toJson());
  payload['link'] = '';
  return payload;
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
