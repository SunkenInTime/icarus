import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/const/hive_boxes.dart';

void main() {
  test('development outbox is cleared exactly once for record version 2',
      () async {
    final directory = await Directory.systemTemp.createTemp('icarus-outbox-');
    addTearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });
    Hive.init(directory.path);
    final box = await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
    await box.put('legacy-work', {'outboxVersion': 1});

    await prepareDurableStrategyOutbox();

    expect(box.keys, [durableOutboxVersionKey]);
    expect(box.get(durableOutboxVersionKey), durableOutboxRecordVersion);

    await box.put('v2-work', {'outboxVersion': durableOutboxRecordVersion});
    await prepareDurableStrategyOutbox();
    expect(box.containsKey('v2-work'), isTrue);
  });
}
