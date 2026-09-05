import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
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
