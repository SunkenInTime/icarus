import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';

void main() {
  test('version 1 outbox records migrate without deleting saved work',
      () async {
    for (final legacyMarker in <int?>[null, 1]) {
      final directory = await Directory.systemTemp.createTemp(
        'icarus-outbox-v1-',
      );
      try {
        Hive.init(directory.path);
        final box = await Hive.openBox<dynamic>(
          HiveBoxNames.strategyOutboxBox,
        );
        final record = _record();
        final legacyJson = record.toJson()..['outboxVersion'] = 1;
        const invalidKey = 'unreadable-work';
        final invalidJson = <String, Object?>{
          'outboxVersion': 1,
          'opId': 'broken',
        };
        if (legacyMarker != null) {
          await box.put(durableOutboxVersionKey, legacyMarker);
        }
        await box.put(record.storageKey, legacyJson);
        await box.put(invalidKey, invalidJson);

        await prepareDurableStrategyOutbox();

        expect(
          box.get(durableOutboxVersionKey),
          durableOutboxRecordVersion,
        );
        expect(
          (box.get(record.storageKey) as Map)['outboxVersion'],
          durableOutboxRecordVersion,
        );
        expect(jsonEncode(box.get(invalidKey)), jsonEncode(invalidJson));
        final loaded = HiveDurableStrategyOutboxStore().load();
        expect(loaded.records.single.pending.op.opId, 'pending-cloud-edit');
        expect(loaded.issues.single.storageKey, invalidKey);

        await prepareDurableStrategyOutbox();
        expect(
          HiveDurableStrategyOutboxStore()
              .load()
              .records
              .single
              .pending
              .op
              .opId,
          'pending-cloud-edit',
        );
      } finally {
        await Hive.close();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    }
  });
}

DurableOutboxRecord _record() {
  const op = ElementPatchOp(
    opId: 'pending-cloud-edit',
    elementPublicId: 'element-one',
    pagePublicId: 'page-one',
    payload: {'value': 'keep-me'},
    expectedElementRevision: 1,
  );
  return DurableOutboxRecord(
    accountId: 'account-a',
    strategyPublicId: 'strategy-a',
    entityKey: const EntitySyncKey.element('page-one', 'element-one'),
    pending: const PendingOp(op: op, clientId: 'client-a'),
    status: DurableOutboxStatus.queued,
    createdAt: DateTime.utc(2026, 9, 4),
    updatedAt: DateTime.utc(2026, 9, 4),
  );
}
