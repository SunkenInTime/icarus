import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/const/hive_boxes.dart';

void main() {
  for (final marker in <int?>[null, 1]) {
    test('legacy media marker $marker opens without deleting saved work',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('icarus-media-v1-');
      try {
        Hive.init(directory.path);
        final box =
            await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
        if (marker != null)
          await box.put(durableCloudMediaOutboxVersionKey, marker);
        final legacy = {
          'outboxVersion': 1,
          'jobId': 'old-image',
          'assetPublicId': 'old-image',
          'uploadId': 'pending-upload'
        };
        await box.put('old-image', legacy);

        await prepareDurableCloudMediaOutbox();
        await prepareDurableCloudMediaOutbox();

        expect(box.get(durableCloudMediaOutboxVersionKey), 2);
        expect(jsonEncode(box.get('old-image')), jsonEncode(legacy));
        final loaded = HiveDurableCloudMediaOutboxStore().load();
        expect(loaded.jobs, isEmpty);
        expect(loaded.issues.single.storageKey, 'old-image');
      } finally {
        await Hive.close();
        await directory.delete(recursive: true);
      }
    });
  }

  group('records shipped builds write', () {
    Map<String, Object?> record(String id, Map<String, Object?> fields) => {
          'outboxVersion': 2,
          'jobId': id,
          'accountId': 'account-a',
          'strategyPublicId': 'strategy-a',
          'assetPublicId': id,
          'fileExtension': '.png',
          'mimeType': 'image/png',
          'width': 16,
          'height': 9,
          ...fields,
          'referenceDurable': true,
          'updatedAt': '2026-11-20T10:00:00.000Z',
        };
    final waiting =
        record('waiting', {'state': 'pendingUpload', 'attempts': 0});
    final uploaded = record('uploaded', {
      'byteSize': 2048,
      'provider': 'r2',
      'uploadId': 'upload-1',
      'objectKey': 'strategies/strategy-a/uploaded.png',
      'etag': '"etag"',
      'state': 'pendingAttach',
      'attempts': 0,
    });
    final failedToAttach = record('failed-to-attach', {
      'byteSize': 2048,
      'provider': 'r2',
      'uploadId': 'upload-2',
      'objectKey': 'strategies/strategy-a/failed-to-attach.png',
      'state': 'failed',
      'attempts': 2,
      'lastError': 'attach refused',
    });
    final failedToUpload = record('failed-to-upload', {
      'state': 'failed',
      'attempts': 1,
      'lastError': 'Local media file is missing.',
    });
    final storedInConvex = record('stored-in-convex', {
      'storageId': 'storage-1',
      'state': 'pendingAttach',
      'attempts': 0,
    });
    final shipped = [
      waiting,
      uploaded,
      failedToAttach,
      failedToUpload,
      storedInConvex,
    ];
    String key(Map<String, Object?> record) => 'account-a|${record['jobId']}';

    test('load as the phase they were in', () {
      final store = MemoryDurableCloudMediaOutboxStore({
        for (final record in shipped) key(record): record,
      });
      final loaded = store.load();
      expect(loaded.issues, isEmpty);
      final phases = {for (final job in loaded.jobs) job.jobId: job.phase};

      expect(phases['waiting'], isA<MediaWaitingToUpload>());
      expect(
        phases['uploaded'],
        isA<MediaUploaded>().having(
          (phase) => phase.media,
          'media',
          isA<R2UploadedMedia>()
              .having((media) => media.uploadId, 'uploadId', 'upload-1')
              .having((media) => media.etag, 'etag', '"etag"')
              .having((media) => media.byteSize, 'byteSize', 2048),
        ),
      );
      expect(
        phases['failed-to-attach'],
        isA<MediaUploadFailed>()
            .having((phase) => phase.attempts, 'attempts', 2)
            .having((phase) => phase.why, 'why', 'attach refused')
            .having((phase) => phase.media, 'media', isA<R2UploadedMedia>()),
      );
      expect(
        phases['failed-to-upload'],
        isA<MediaUploadFailed>()
            .having((phase) => phase.attempts, 'attempts', 1)
            .having((phase) => phase.media, 'media', isNull),
      );
      expect(
        phases['stored-in-convex'],
        isA<MediaUploaded>().having(
          (phase) => phase.media,
          'media',
          isA<ConvexStoredMedia>()
              .having((media) => media.storageId, 'storageId', 'storage-1'),
        ),
      );
    });

    test('are written back exactly as shipped builds wrote them', () async {
      final store = MemoryDurableCloudMediaOutboxStore({
        for (final record in shipped)
          key(record): {
            ...record,
            if (record['uploadId'] != null)
              'uploadUrlExpiresAt': '2026-11-20T10:15:00.000Z',
          },
      });
      final rewritten = MemoryDurableCloudMediaOutboxStore();
      await rewritten.putAll(store.load().jobs);

      for (final record in shipped) {
        expect(rewritten.values[key(record)], record, reason: key(record));
      }
    });
  });

  test('unknown future media versions are not restamped', () async {
    final directory =
        await Directory.systemTemp.createTemp('icarus-media-future-');
    try {
      Hive.init(directory.path);
      final box = await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
      await box.put(durableCloudMediaOutboxVersionKey, 999);
      await expectLater(prepareDurableCloudMediaOutbox(), throwsStateError);
      expect(box.get(durableCloudMediaOutboxVersionKey), 999);
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}
