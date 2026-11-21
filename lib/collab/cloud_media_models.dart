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

sealed class CloudMediaJobPhase {
  const CloudMediaJobPhase();
}

final class MediaWaitingToUpload extends CloudMediaJobPhase {
  const MediaWaitingToUpload();
}

final class MediaUploaded extends CloudMediaJobPhase {
  const MediaUploaded(this.media);
  final UploadedMedia media;
}

final class MediaUploadFailed extends CloudMediaJobPhase {
  const MediaUploadFailed({
    required this.why,
    required this.attempts,
    this.media,
  });

  final String why;
  final int attempts;
  final UploadedMedia? media;
}

sealed class UploadedMedia {
  const UploadedMedia();
}

final class R2UploadedMedia extends UploadedMedia {
  const R2UploadedMedia({
    required this.uploadId,
    required this.objectKey,
    this.etag,
    this.byteSize,
  });

  final String uploadId;
  final String objectKey;
  final String? etag;
  final int? byteSize;
}

final class ConvexStoredMedia extends UploadedMedia {
  const ConvexStoredMedia(this.storageId);
  final String storageId;
}

class CloudMediaUploadJob {
  CloudMediaUploadJob({
    required this.jobId,
    required this.accountId,
    required this.strategyPublicId,
    required this.assetPublicId,
    required this.fileExtension,
    required this.mimeType,
    required this.updatedAt,
    this.phase = const MediaWaitingToUpload(),
    this.referenceDurable = true,
    this.width,
    this.height,
  });

  final String jobId;
  final String accountId;
  final String strategyPublicId;
  final String assetPublicId;
  final String fileExtension;
  final String mimeType;
  final int? width;
  final int? height;
  final CloudMediaJobPhase phase;
  final bool referenceDurable;
  final DateTime updatedAt;

  bool get isFailed => phase is MediaUploadFailed;

  int get failedAttempts => switch (phase) {
        MediaUploadFailed(:final attempts) => attempts,
        _ => 0,
      };

  CloudMediaUploadJob copyWith({
    String? strategyPublicId,
    String? assetPublicId,
    String? fileExtension,
    String? mimeType,
    int? width,
    int? height,
    CloudMediaJobPhase? phase,
    bool? referenceDurable,
    DateTime? updatedAt,
  }) {
    return CloudMediaUploadJob(
      jobId: jobId,
      accountId: accountId,
      strategyPublicId: strategyPublicId ?? this.strategyPublicId,
      assetPublicId: assetPublicId ?? this.assetPublicId,
      fileExtension: fileExtension ?? this.fileExtension,
      mimeType: mimeType ?? this.mimeType,
      width: width ?? this.width,
      height: height ?? this.height,
      phase: phase ?? this.phase,
      referenceDurable: referenceDurable ?? this.referenceDurable,
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
}

Map<String, dynamic> cloudImagePayloadFromPlacedImage(PlacedImage image) {
  return Map<String, dynamic>.from(image.toJson())..remove('link');
}
