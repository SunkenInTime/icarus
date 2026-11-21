import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/config/cloud_startup.dart';
import 'package:icarus/const/hive_boxes.dart';

const durableCloudMediaOutboxRecordVersion = 2;
const durableCloudMediaOutboxVersionKey = '__media_outbox_record_version__';

Future<void> prepareDurableCloudMediaOutbox() async {
  final box = Hive.box<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
  final version = box.get(durableCloudMediaOutboxVersionKey);
  if (version == durableCloudMediaOutboxRecordVersion) {
    return;
  }
  if (version != null && version != 1) {
    throw StateError(
      'The media outbox has an unsupported record version. '
      'Refusing to discard pending media work.',
    );
  }
  // Prerelease v1 records had no owning account. Keep them byte-for-byte
  // for recovery, and let load() report them as unreadable saved work.
  // Never assign them to whichever account happens to sign in next.
  await box.put(
    durableCloudMediaOutboxVersionKey,
    durableCloudMediaOutboxRecordVersion,
  );
}

class DurableCloudMediaOutboxLoadIssue {
  const DurableCloudMediaOutboxLoadIssue({
    required this.storageKey,
    required this.error,
  });

  final String storageKey;
  final String error;
}

class DurableCloudMediaOutboxLoadResult {
  const DurableCloudMediaOutboxLoadResult({
    required this.jobs,
    required this.issues,
  });

  final List<CloudMediaUploadJob> jobs;
  final List<DurableCloudMediaOutboxLoadIssue> issues;
}

abstract class DurableCloudMediaOutboxStore {
  DurableCloudMediaOutboxLoadResult load();
  Future<void> put(CloudMediaUploadJob job);
  Future<void> putAll(Iterable<CloudMediaUploadJob> jobs);
  Future<void> remove(CloudMediaUploadJob job);
}

String durableCloudMediaOutboxStorageKey(CloudMediaUploadJob job) {
  return durableCloudMediaOutboxStorageKeyFor(
    accountId: job.accountId,
    jobId: job.jobId,
  );
}

String durableCloudMediaOutboxStorageKeyFor({
  required String accountId,
  required String jobId,
}) {
  return '${Uri.encodeComponent(accountId)}|${Uri.encodeComponent(jobId)}';
}

class HiveDurableCloudMediaOutboxStore implements DurableCloudMediaOutboxStore {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.cloudMediaOutboxBox);

  @override
  DurableCloudMediaOutboxLoadResult load() {
    final jobs = <CloudMediaUploadJob>[];
    final issues = <DurableCloudMediaOutboxLoadIssue>[];
    for (final key in _box.keys) {
      final storageKey = key.toString();
      if (storageKey == durableCloudMediaOutboxVersionKey) {
        continue;
      }
      try {
        final raw = _box.get(key);
        final decoded = raw is String ? jsonDecode(raw) : raw;
        final json = decoded is Map<String, dynamic>
            ? decoded
            : Map<String, dynamic>.from(decoded as Map);
        final job = _jobFromJson(json);
        if (durableCloudMediaOutboxStorageKey(job) != storageKey) {
          throw const FormatException(
            'Media outbox storage key does not match job',
          );
        }
        jobs.add(job);
      } catch (error) {
        issues.add(
          DurableCloudMediaOutboxLoadIssue(
            storageKey: storageKey,
            error: error.toString(),
          ),
        );
      }
    }
    return DurableCloudMediaOutboxLoadResult(jobs: jobs, issues: issues);
  }

  @override
  Future<void> put(CloudMediaUploadJob job) {
    final jsonSafe = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(_jobToJson(job))) as Map,
    );
    return _box.put(durableCloudMediaOutboxStorageKey(job), jsonSafe);
  }

  @override
  Future<void> putAll(Iterable<CloudMediaUploadJob> jobs) {
    final values = <String, Map<String, dynamic>>{
      for (final job in jobs)
        durableCloudMediaOutboxStorageKey(job): Map<String, dynamic>.from(
          jsonDecode(jsonEncode(_jobToJson(job))) as Map,
        ),
    };
    return _box.putAll(values);
  }

  @override
  Future<void> remove(CloudMediaUploadJob job) =>
      _box.delete(durableCloudMediaOutboxStorageKey(job));
}

class MemoryDurableCloudMediaOutboxStore
    implements DurableCloudMediaOutboxStore {
  MemoryDurableCloudMediaOutboxStore([Map<String, Object?>? initialValues])
      : values = Map<String, Object?>.from(initialValues ?? const {});

  final Map<String, Object?> values;

  @override
  DurableCloudMediaOutboxLoadResult load() {
    final jobs = <CloudMediaUploadJob>[];
    final issues = <DurableCloudMediaOutboxLoadIssue>[];
    for (final entry in values.entries) {
      try {
        final value = entry.value;
        final json = value is Map<String, dynamic>
            ? value
            : Map<String, dynamic>.from(value as Map);
        final job = _jobFromJson(json);
        if (durableCloudMediaOutboxStorageKey(job) != entry.key) {
          throw const FormatException(
            'Media outbox storage key does not match job',
          );
        }
        jobs.add(job);
      } catch (error) {
        issues.add(
          DurableCloudMediaOutboxLoadIssue(
            storageKey: entry.key,
            error: error.toString(),
          ),
        );
      }
    }
    return DurableCloudMediaOutboxLoadResult(jobs: jobs, issues: issues);
  }

  @override
  Future<void> put(CloudMediaUploadJob job) async {
    values[durableCloudMediaOutboxStorageKey(job)] = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(_jobToJson(job))) as Map,
    );
  }

  @override
  Future<void> putAll(Iterable<CloudMediaUploadJob> jobs) async {
    final encoded = <String, Map<String, dynamic>>{
      for (final job in jobs)
        durableCloudMediaOutboxStorageKey(job): Map<String, dynamic>.from(
          jsonDecode(jsonEncode(_jobToJson(job))) as Map,
        ),
    };
    values.addAll(encoded);
  }

  @override
  Future<void> remove(CloudMediaUploadJob job) async {
    values.remove(durableCloudMediaOutboxStorageKey(job));
  }
}

/// The media outbox in a run where cloud sync did not start. It reads
/// nothing and writes nothing, so the box file stays exactly as the last run
/// left it. Its one load issue keeps pending image bytes from being pruned:
/// only a clean load proves no job needs them.
class UnavailableDurableCloudMediaOutboxStore
    implements DurableCloudMediaOutboxStore {
  const UnavailableDurableCloudMediaOutboxStore(this.reason);

  final String reason;

  @override
  DurableCloudMediaOutboxLoadResult load() => DurableCloudMediaOutboxLoadResult(
        jobs: const [],
        issues: [
          DurableCloudMediaOutboxLoadIssue(
            storageKey: HiveBoxNames.cloudMediaOutboxBox,
            error: reason,
          ),
        ],
      );

  @override
  Future<void> put(CloudMediaUploadJob job) =>
      Future.error(CloudUnavailableException(reason));

  @override
  Future<void> putAll(Iterable<CloudMediaUploadJob> jobs) =>
      Future.error(CloudUnavailableException(reason));

  @override
  Future<void> remove(CloudMediaUploadJob job) =>
      Future.error(CloudUnavailableException(reason));
}

final durableCloudMediaOutboxStoreProvider =
    Provider<DurableCloudMediaOutboxStore>(
  (ref) {
    final unavailableReason = ref.watch(cloudStartupProvider).unavailableReason;
    return unavailableReason == null
        ? HiveDurableCloudMediaOutboxStore()
        : UnavailableDurableCloudMediaOutboxStore(unavailableReason);
  },
);

Map<String, dynamic> _jobToJson(CloudMediaUploadJob job) {
  final accountId = job.accountId;
  if (accountId.isEmpty) {
    throw StateError('New media outbox records require an owning account.');
  }
  final (state, media, attempts, why) = switch (job.phase) {
    MediaWaitingToUpload() => (CloudMediaJobState.pendingUpload, null, 0, null),
    MediaUploaded(:final media) => (
        CloudMediaJobState.pendingAttach,
        media,
        0,
        null
      ),
    MediaUploadFailed(:final media, :final attempts, :final why) => (
        CloudMediaJobState.failed,
        media,
        attempts,
        why,
      ),
  };
  return <String, dynamic>{
    'outboxVersion': durableCloudMediaOutboxRecordVersion,
    'jobId': job.jobId,
    'accountId': accountId,
    'strategyPublicId': job.strategyPublicId,
    'assetPublicId': job.assetPublicId,
    'fileExtension': job.fileExtension,
    'mimeType': job.mimeType,
    if (job.width != null) 'width': job.width,
    if (job.height != null) 'height': job.height,
    ...switch (media) {
      null => const <String, dynamic>{},
      R2UploadedMedia() => <String, dynamic>{
          'provider': 'r2',
          'uploadId': media.uploadId,
          'objectKey': media.objectKey,
          if (media.etag != null) 'etag': media.etag,
          if (media.byteSize != null) 'byteSize': media.byteSize,
        },
      ConvexStoredMedia() => <String, dynamic>{'storageId': media.storageId},
    },
    'state': state.name,
    'referenceDurable': job.referenceDurable,
    'attempts': attempts,
    if (why != null) 'lastError': why,
    'updatedAt': job.updatedAt.toUtc().toIso8601String(),
  };
}

CloudMediaUploadJob _jobFromJson(Map<String, dynamic> json) {
  final version = (json['outboxVersion'] as num?)?.toInt();
  if (version != durableCloudMediaOutboxRecordVersion) {
    throw FormatException('Unsupported media outbox record version: $version');
  }
  final state = CloudMediaJobState.values.byName(
    _nonEmptyString(json['state'], field: 'state'),
  );
  final media = _uploadedMediaFromJson(json);
  return CloudMediaUploadJob(
    jobId: _nonEmptyString(json['jobId'], field: 'jobId'),
    accountId: _nonEmptyString(json['accountId'], field: 'accountId'),
    strategyPublicId: _nonEmptyString(
      json['strategyPublicId'],
      field: 'strategyPublicId',
    ),
    assetPublicId: _nonEmptyString(
      json['assetPublicId'],
      field: 'assetPublicId',
    ),
    fileExtension: json['fileExtension'] as String? ?? '',
    mimeType: _nonEmptyString(json['mimeType'], field: 'mimeType'),
    width: (json['width'] as num?)?.toInt(),
    height: (json['height'] as num?)?.toInt(),
    phase: switch ((state, media)) {
      (CloudMediaJobState.failed, _) => MediaUploadFailed(
          why: json['lastError'] as String? ?? '',
          attempts: (json['attempts'] as num?)?.toInt() ?? 0,
          media: media,
        ),
      (_, final UploadedMedia media) => MediaUploaded(media),
      (_, null) => const MediaWaitingToUpload(),
    },
    referenceDurable: json['referenceDurable'] as bool? ?? true,
    updatedAt: _requiredDate(json['updatedAt'], field: 'updatedAt'),
  );
}

UploadedMedia? _uploadedMediaFromJson(Map<String, dynamic> json) {
  if (json['provider'] == 'r2') {
    return switch ((json['uploadId'], json['objectKey'])) {
      (final String uploadId, final String objectKey) => R2UploadedMedia(
          uploadId: uploadId,
          objectKey: objectKey,
          etag: json['etag'] as String?,
          byteSize: (json['byteSize'] as num?)?.toInt(),
        ),
      _ => null,
    };
  }
  return switch (json['storageId']) {
    final String storageId => ConvexStoredMedia(storageId),
    _ => null,
  };
}

String _nonEmptyString(Object? value, {required String field}) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw FormatException('Media outbox $field must be a non-empty string');
}

DateTime _requiredDate(Object? value, {required String field}) {
  final parsed = _optionalDate(value);
  if (parsed != null) {
    return parsed;
  }
  throw FormatException('Media outbox $field must be an ISO-8601 date');
}

DateTime? _optionalDate(Object? value) {
  if (value is! String) {
    return null;
  }
  return DateTime.tryParse(value)?.toLocal();
}
