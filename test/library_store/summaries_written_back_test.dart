import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

import '../library_rows/generated_strategies.dart';
import 'aged_summaries.dart';
import 'gated_engine.dart';
import 'hive_scratch.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-written-back-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => directory.path);
    await openScratchHive(directory, strategies: [
      generatedStrategy(Optionals.unset).copyWith(id: 'a', name: 'A'),
      generatedStrategy(Optionals.unset).copyWith(id: 'b', name: 'B'),
    ]);
  });
  tearDown(() async {
    LocalLibrary.source = const LibraryInHive();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await directory.delete(recursive: true);
  });

  File storeFile() => libraryStoreFile(directory.path);

  Future<ProviderContainer> open({
    required Future<void> firstFrame,
    CommitGate? gate,
  }) async {
    final container = ProviderContainer(overrides: [
      if (gate case final gate?)
        libraryStoreProvider.overrideWith(
          () => LibraryStoreNotifier(
            wrapEngine: (engine) => GatedEngine(engine, gate),
          ),
        ),
    ]);
    await openLibraryOnStore(
      container,
      LibraryStoreLaunch.parse(
        const [LibraryStoreLaunch.storeFlag],
        mayShadow: true,
      ),
      hiveDirectory: directory.path,
      allowsLocalLibrary: true,
      build: '',
      bringUpToDate: () async {},
      servedAgain: () {},
      firstFrame: firstFrame,
    );
    return container;
  }

  Future<void> close(ProviderContainer container) async {
    await container.read(libraryStoreProvider.notifier).close();
    container.dispose();
    LocalLibrary.source = const LibraryInHive();
  }

  LibraryStore openedStore(ProviderContainer container) =>
      switch (container.read(libraryStoreProvider)) {
        LibraryStoreReady(:final store) => store,
        final other => fail('$other'),
      };

  Future<int> rebuiltOnOpen() async {
    final engine = SqliteEngine(storeFile().path);
    final store = await openStoreOn(engine);
    final rebuilt = store.summariesRebuiltAtOpen;
    await store.close();
    await engine.close();
    return rebuilt;
  }

  Future<void> ageTheStore() async {
    await close(await open(firstFrame: Future.value()));
    final engine = SqliteEngine(storeFile().path);
    expect(await ageSummaries(engine), 2);
    await engine.close();
  }

  Future<void> settle() async {
    for (var turn = 0; turn < 20; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
      'an aged store rebuilds its summaries once: after the first frame they '
      'are written back and the next open rebuilds none', () async {
    await ageTheStore();

    final container = await open(firstFrame: Future.value());
    expect(openedStore(container).summariesRebuiltAtOpen, 2);
    await settle();
    await close(container);

    expect(await rebuiltOnOpen(), 0);
  });

  test('nothing is written back before the first frame', () async {
    await ageTheStore();
    final firstFrame = Completer<void>();

    final container = await open(firstFrame: firstFrame.future);
    await settle();
    await close(container);

    expect(await rebuiltOnOpen(), 2);
  });

  test(
      'a rename saved before the first frame keeps its name, and the '
      'write-back after it leaves nothing to rebuild', () async {
    await ageTheStore();
    final firstFrame = Completer<void>();
    final container = await open(firstFrame: firstFrame.future);
    const library = LocalLibrary();

    final renaming = library.renameStrategy(
      library.storedStrategy('a')!,
      'Renamed',
    );
    firstFrame.complete();
    expect(await renaming, isA<LibraryWritten>());
    await settle();
    final summary = openedStore(container).summaryOf('a');
    await close(container);

    final engine = SqliteEngine(storeFile().path);
    final reopened = await openStoreOn(engine);
    expect(reopened.summariesRebuiltAtOpen, 0);
    expect(reopened.summaryOf('a'), summary);
    expect(reopened.summaryOf('a')!.name, 'Renamed');
    await reopened.close();
    await engine.close();
  });

  test(
      'a write-back the device refuses is reported, the library stays served, '
      'and the next open rebuilds again', () async {
    await ageTheStore();
    final gate = CommitGate()..failNext = true;
    final container = await open(firstFrame: Future.value(), gate: gate);
    await settle();

    expect(
      [
        for (final entry in appProviderContainer.read(inAppDebugProvider))
          if (entry.source == 'libraryStore.summariesWrittenBack')
            entry.message,
      ],
      [contains('did not write back the summaries it rebuilt at open')],
    );
    expect(LocalLibrary.source, isA<LibraryInStore>());
    expect(container.read(libraryOnStoreProvider),
        isA<LibraryServedFromStore>());
    await close(container);
    expect(await rebuiltOnOpen(), 2);
  });

  test(
      'a write-back whose answer is lost shuts the store as a lost save does: '
      'the library shows the could-not-open face, and Try again serves it '
      'with the summaries that landed', () async {
    await ageTheStore();
    final gate = CommitGate()..doubtNext = true;

    final container = await open(firstFrame: Future.value(), gate: gate);
    final stopAt = DateTime.now().add(const Duration(seconds: 5));
    while (container.read(libraryOnStoreProvider) is! LibraryNotServed &&
        DateTime.now().isBefore(stopAt)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final notServed = container.read(libraryOnStoreProvider);
    expect(notServed, isA<LibraryNotServed>());
    expect(LocalLibrary.source, isA<LibraryNotOpened>());
    await (notServed! as LibraryNotServed).tryAgain();
    expect(container.read(libraryOnStoreProvider),
        isA<LibraryServedFromStore>());
    expect(openedStore(container).summariesRebuiltAtOpen, 0);
    expect(
      [for (final s in const LocalLibrary().storedStrategies) s.id],
      ['a', 'b'],
    );
    await close(container);
  });

  test(
      'a store closed before the first frame writes nothing back, and the '
      'next open rebuilds again', () async {
    await ageTheStore();
    final firstFrame = Completer<void>();
    final container = await open(firstFrame: firstFrame.future);

    await close(container);
    firstFrame.complete();
    await settle();

    expect(await rebuiltOnOpen(), 2);
  });
}
