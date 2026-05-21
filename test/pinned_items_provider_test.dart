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

  test('pinnedIdsByRecency returns most-recently-pinned first', () async {
    final notifier = container.read(pinnedItemsProvider.notifier);

    await notifier.togglePin('first');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await notifier.togglePin('second');

    expect(notifier.pinnedIdsByRecency(), ['second', 'first']);
  });

  test('removePin is a no-op when the id is not pinned', () async {
    final notifier = container.read(pinnedItemsProvider.notifier);

    await notifier.removePin('missing'); // should not throw
    expect(notifier.isPinned('missing'), false);
  });
}
