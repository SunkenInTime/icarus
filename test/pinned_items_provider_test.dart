import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/pinned_items_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-pins-');
    Hive.init(tempDir.path);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('pinning an id makes it pinned, toggling again unpins', () async {
    final notifier = container.read(pinnedItemsProvider.notifier);

    expect(notifier.isPinned('a'), false);

    await notifier.togglePin('a');
    expect(notifier.isPinned('a'), true);

    await notifier.togglePin('a');
    expect(notifier.isPinned('a'), false);
  });

  test('pinned ids stay in manual order with newest pin at the top', () async {
    final notifier = container.read(pinnedItemsProvider.notifier);

    await notifier.togglePin('first');
    await notifier.togglePin('second');

    expect(notifier.pinnedIdsByManualOrder(), ['second', 'first']);
  });

  test('removePin is a no-op when the id is not pinned', () async {
    final notifier = container.read(pinnedItemsProvider.notifier);

    await notifier.removePin('missing'); // should not throw
    expect(notifier.isPinned('missing'), false);
  });

  test('movePinUp and movePinDown update manual order', () async {
    final notifier = container.read(pinnedItemsProvider.notifier);

    await notifier.togglePin('third');
    await notifier.togglePin('second');
    await notifier.togglePin('first');

    await notifier.movePinDown('first');
    expect(notifier.pinnedIdsByManualOrder(), ['second', 'first', 'third']);

    await notifier.movePinUp('third');
    expect(notifier.pinnedIdsByManualOrder(), ['second', 'third', 'first']);
  });

  test('movePinToTop moves pinned id to the start', () async {
    final notifier = container.read(pinnedItemsProvider.notifier);

    await notifier.togglePin('third');
    await notifier.togglePin('second');
    await notifier.togglePin('first');

    await notifier.movePinToTop('third');

    expect(notifier.pinnedIdsByManualOrder(), ['third', 'first', 'second']);
  });

  test('movePin reorders an id around a target id', () async {
    final notifier = container.read(pinnedItemsProvider.notifier);

    await notifier.togglePin('third');
    await notifier.togglePin('second');
    await notifier.togglePin('first');

    await notifier.movePin(
      id: 'third',
      targetId: 'first',
      insertAfterTarget: false,
    );
    expect(notifier.pinnedIdsByManualOrder(), ['third', 'first', 'second']);

    await notifier.movePin(
      id: 'third',
      targetId: 'second',
      insertAfterTarget: true,
    );
    expect(notifier.pinnedIdsByManualOrder(), ['first', 'second', 'third']);
  });

  test('saved order removes stale box keys', () async {
    final notifier = container.read(pinnedItemsProvider.notifier);
    final box = Hive.box<int>(HiveBoxNames.pinnedItemsBox);

    await notifier.togglePin('first');
    await notifier.togglePin('second');
    await notifier.removePin('first');

    expect(box.containsKey('first'), false);
    expect(box.toMap(), {'second': 0});
  });

  test('legacy timestamp pins keep recency order until saved', () async {
    final box = Hive.box<int>(HiveBoxNames.pinnedItemsBox);
    await box.put('first', 1710000000000);
    await box.put('second', 1720000000000);
    final legacyContainer = ProviderContainer();
    addTearDown(legacyContainer.dispose);
    final notifier = legacyContainer.read(pinnedItemsProvider.notifier);

    expect(notifier.pinnedIdsByManualOrder(), ['second', 'first']);

    await notifier.movePinDown('second');
    expect(notifier.pinnedIdsByManualOrder(), ['first', 'second']);
  });
}
