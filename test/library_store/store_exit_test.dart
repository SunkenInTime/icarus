import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

final class _Silent extends LocalLibraryFollower {
  @override
  void onWriting(LibraryTouch touch) {}

  @override
  void onAnswered(LibraryTouch touch) {}

  @override
  void onFault(Object error, StackTrace stackTrace) {}
}

final class _CloseNeverAnswers extends LibraryStoreNotifier {
  var called = false;

  @override
  Future<void> close() {
    called = true;
    return Completer<void>().future;
  }
}

final class _SlowClose extends LibraryStoreNotifier {
  var finished = false;

  @override
  Future<void> close() async {
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    finished = true;
  }
}

StoreMirror _idleMirror() =>
    StoreMirror(reads: HiveReads(), betweenAnimations: () async {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => LocalLibrary.follower = null);

  test(
      'with the switch off or in shadow mode the editor has nothing to wait for',
      () {
    LocalLibrary.follower = null;
    expect(storeCatchUpBeforeClose(), isNull);
    LocalLibrary.follower = _Silent();
    expect(storeCatchUpBeforeClose(), isNull);
  });

  test(
      'in mirror mode the editor waits for the queue before it closes, two seconds at most',
      () async {
    final directory = await Directory.systemTemp.createTemp('icarus-exit-');
    addTearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });
    await openScratchHive(directory);
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    final mirror = StoreMirror(
      reads: HiveReads(),
      betweenAnimations: () => Completer<void>().future,
    );
    LocalLibrary.follower = mirror;
    final writes = LibraryBoxWrites();
    await mirror.copyThenFollow(store, writes: writes);
    await writes.stop();
    await const LocalLibrary().addStrategy(
      StrategyMigrator.migrateToCurrentVersion(
        generatedStrategy(Optionals.set).copyWith(id: 'waiting'),
      ),
    );
    var drained = false;
    unawaited(mirror.drained().then((_) => drained = true));
    final watch = Stopwatch()..start();
    await storeCatchUpBeforeClose();
    expect(watch.elapsed, greaterThan(const Duration(milliseconds: 1900)));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(drained, isFalse);
    expect(mirror.pending, 1);
  });

  test('in shadow mode the app exits only once the store has closed', () async {
    final slow = _SlowClose();
    final container = ProviderContainer(overrides: [
      libraryStoreProvider.overrideWith(() => slow),
    ]);
    addTearDown(container.dispose);
    await storeClosesBeforeExit(container);
    expect(slow.finished, isTrue);
  });

  test(
      'in mirror mode a store close that never answers lets the app exit after two seconds',
      () async {
    LocalLibrary.follower = _idleMirror();
    final stuck = _CloseNeverAnswers();
    final container = ProviderContainer(overrides: [
      libraryStoreProvider.overrideWith(() => stuck),
    ]);
    addTearDown(container.dispose);
    final watch = Stopwatch()..start();
    await storeClosesBeforeExit(container).timeout(const Duration(seconds: 5));
    expect(stuck.called, isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });
}
