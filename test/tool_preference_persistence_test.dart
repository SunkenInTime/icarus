import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-tool-prefs-');
    Hive.init(tempDir.path);
    registerIcarusAdapters(Hive);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('library sort and drawing defaults survive a provider restart',
      () async {
    var container = ProviderContainer();

    container
        .read(strategyFilterProvider.notifier)
        .setSortBy(SortBy.alphabetical);
    container
        .read(strategyFilterProvider.notifier)
        .setSortOrder(SortOrder.descending);
    container.read(penProvider.notifier).updateValue(
          color: const Color(0xFF44AA77),
          thickness: 8,
        );

    await Future<void>.delayed(Duration.zero);
    await Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox).flush();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(strategyFilterProvider).sortBy, SortBy.alphabetical);
    expect(
        container.read(strategyFilterProvider).sortOrder, SortOrder.descending);
    expect(container.read(penProvider).color, const Color(0xFF44AA77));
    expect(container.read(penProvider).thickness, 8);
  });
}
