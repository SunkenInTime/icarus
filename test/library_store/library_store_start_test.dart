import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/library_store_start.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/strategy/strategy_models.dart';

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

List<StrategyData> _library() => [
      generatedStrategy(Optionals.set)
          .copyWith(id: 'z-last', name: 'Same name'),
      generatedStrategy(Optionals.unset)
          .copyWith(id: 'a-first', name: 'Same name'),
      generatedStrategy(Optionals.set)
          .copyWith(id: 'm-middle', name: 'Middle'),
      generatedStrategy(Optionals.unset)
          .copyWith(id: 'empty', name: 'No pages', pages: const []),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-start-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    await openScratchHive(directory, strategies: _library());
  });
  tearDown(() async {
    LocalLibrary.follower = null;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
      'through start-up, each mode the switch still has gets its own shadow '
      'mode, and the library lists Hive with its own dates', () {
    for (final choice in [
      const StoreSwitchOff(),
      const StoreSwitchShadow(),
      const StoreSwitchMirror(),
      const StoreSwitchStore(),
    ]) {
      final start = LibraryStoreStart.of(choice);
      final container = ProviderContainer(overrides: start.overrides);
      addTearDown(container.dispose);
      expect(
        container.read(libraryStoreSwitchProvider).runtimeType,
        choice.runtimeType,
      );
      switch (choice) {
        case StoreSwitchOff() || StoreSwitchStore():
          expect(start.mode, isNull, reason: '$choice');
        case StoreSwitchShadow():
          expect(start.mode, isA<ShadowOnly>());
        case StoreSwitchMirror():
          expect(start.mode, isA<Mirroring>());
      }
      final view = container.read(localLibraryViewProvider);
      expect(
        view.strategies.value.map((s) => s.id),
        ['a-first', 'empty', 'm-middle', 'z-last'],
        reason: '$choice',
      );
      expect(
        [for (final s in view.strategies.value) s.lastEdited],
        [
          for (final s in _library()..sort((a, b) => a.id.compareTo(b.id)))
            s.lastEdited,
        ],
        reason: '$choice keeps Hive\'s own dates',
      );
    }
  });
}
