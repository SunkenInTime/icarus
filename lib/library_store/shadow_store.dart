import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/hive_files.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/ui_watch.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/library_store/strategy_image.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus_library/icarus_library.dart';

final libraryStoreProvider =
    NotifierProvider<LibraryStoreNotifier, LibraryStoreState>(
  LibraryStoreNotifier.new,
);

class LibraryStoreNotifier extends Notifier<LibraryStoreState> {
  Future<void>? _closing;

  @override
  LibraryStoreState build() => const LibraryStoreOff();

  Future<LibraryStoreOpened> open(File file, {String build = ''}) async {
    state = LibraryStoreOpening(file);
    final opened = await openLibraryStore(file, build: build);
    state = opened;
    return opened;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    switch (state) {
      case LibraryStoreReady(:final store, :final closeEngine):
        final released = await store.close();
        await closeEngine();
        state = LibraryStoreClosed(released);
      case LibraryStoreOff() ||
            LibraryStoreOpening() ||
            LibraryStoreClosed() ||
            LibraryStoreHeldElsewhere() ||
            LibraryStoreRefused() ||
            LibraryStoreTooSmall():
        break;
    }
  }
}

final class ShadowRun {
  ShadowRun({
    required this.copy,
    required this.check,
    required this.copyTook,
    required this.checkTook,
    required this.uiDuringCopy,
    required this.uiDuringCheck,
    required this.hiveFiles,
    required List<String> libraryBoxesChanged,
    required List<String> otherHiveFilesChanged,
    required this.libraryBoxWrites,
  })  : libraryBoxesChanged = List.unmodifiable(libraryBoxesChanged),
        otherHiveFilesChanged = List.unmodifiable(otherHiveFilesChanged);

  final int libraryBoxWrites;

  final ShadowCopy copy;
  final StoreCheck check;
  final Duration copyTook;
  final Duration checkTook;
  final UiStats uiDuringCopy;
  final UiStats uiDuringCheck;
  final int hiveFiles;
  final List<String> libraryBoxesChanged;
  final List<String> otherHiveFilesChanged;
}

sealed class ShadowState {
  const ShadowState();
}

final class ShadowIdle extends ShadowState {
  const ShadowIdle();
}

final class ShadowCopying extends ShadowState {
  const ShadowCopying(this.done, this.total);

  final int done;
  final int total;
}

final class ShadowChecking extends ShadowState {
  const ShadowChecking();
}

final class ShadowFinished extends ShadowState {
  const ShadowFinished(this.run);

  final ShadowRun run;
}

final class ShadowNotOpened extends ShadowState {
  const ShadowNotOpened(this.opened);

  final LibraryStoreOpened opened;
}

sealed class ShadowMode {
  const ShadowMode();
}

final class ShadowOnly extends ShadowMode {
  const ShadowOnly();
}

final class Mirroring extends ShadowMode {
  const Mirroring(this.mirror);

  final StoreMirror mirror;
}

StoreMirror storeMirror() => StoreMirror(
      reads: HiveReads(),
      betweenAnimations: betweenAnimations,
    );

Future<void> betweenAnimations() async {
  final scheduler = SchedulerBinding.instance;
  await Future.any([
    scheduler.scheduleTask<void>(() {}, Priority.idle),
    Future<void>.delayed(const Duration(milliseconds: 500)),
  ]);
  if (scheduler.hasScheduledFrame) {
    await Future.any([
      scheduler.endOfFrame,
      Future<void>.delayed(const Duration(milliseconds: 500)),
    ]);
  }
}

final shadowProvider = NotifierProvider<ShadowNotifier, ShadowState>(
  ShadowNotifier.new,
);

Future<void> _breathe() => Future<void>.delayed(Duration.zero);

class ShadowNotifier extends Notifier<ShadowState> {
  Future<void>? running;

  @override
  ShadowState build() => const ShadowIdle();

  ShadowMode mode = const ShadowOnly();

  final _shadowReads = HiveReads();

  void begin({
    required Future<LibraryStoreOpened> opening,
    required Future<void> firstFrame,
    required String hiveDirectory,
    required ShadowMode mode,
  }) {
    this.mode = mode;
    running = _run(
      opening: opening,
      firstFrame: firstFrame,
      hiveDirectory: hiveDirectory,
    );
  }

  Future<void> _run({
    required Future<LibraryStoreOpened> opening,
    required Future<void> firstFrame,
    required String hiveDirectory,
  }) async {
    final opened = await opening;
    final LibraryStore store;
    final List<ForeignName> foreignNames;
    switch (opened) {
      case LibraryStoreReady(store: final ready, foreignNames: final foreign):
        store = ready;
        foreignNames = foreign;
      case LibraryStoreHeldElsewhere() ||
            LibraryStoreRefused() ||
            LibraryStoreTooSmall():
        state = ShadowNotOpened(opened);
        return;
    }
    await firstFrame;
    final before = await HiveFiles.of(Directory(hiveDirectory));
    final writes = LibraryBoxWrites();
    final copyWatch = UiWatch()..start();
    final checkWatch = UiWatch();
    try {
      final copyClock = Stopwatch()..start();
      void progress(int done, int total) => state = ShadowCopying(done, total);
      final copy = switch (mode) {
        ShadowOnly() => await copyHiveIntoStore(
            _shadowReads,
            store,
            images: StrategyImages(),
            writes: writes,
            breathe: _breathe,
            progress: progress,
          ),
        Mirroring(:final mirror) => await mirror.copyThenFollow(
            store,
            writes: writes,
            progress: progress,
          ),
      };
      final copyTook = copyClock.elapsed;
      final uiDuringCopy = copyWatch.stop();
      state = const ShadowChecking();
      checkWatch.start();
      final checkClock = Stopwatch()..start();
      final check = await _check(store, foreignNames);
      final checkTook = checkClock.elapsed;
      final uiDuringCheck = checkWatch.stop();
      final after = await HiveFiles.of(Directory(hiveDirectory));
      final changed = after.changedSince(before);
      state = ShadowFinished(
        ShadowRun(
          copy: copy,
          check: check,
          copyTook: copyTook,
          checkTook: checkTook,
          uiDuringCopy: uiDuringCopy,
          uiDuringCheck: uiDuringCheck,
          hiveFiles: after.count,
          libraryBoxesChanged: [
            for (final name in changed)
              if (libraryBoxFileNames().contains(name)) name,
          ],
          otherHiveFilesChanged: [
            for (final name in changed)
              if (!libraryBoxFileNames().contains(name)) name,
          ],
          libraryBoxWrites: writes.count,
        ),
      );
    } finally {
      copyWatch.stop();
      checkWatch.stop();
      await writes.stop();
    }
  }

  Future<StoreCheck> checkAgain(LibraryStoreReady ready) =>
      _check(ready.store, ready.foreignNames);

  Future<StoreCheck> _check(
    LibraryStore store,
    List<ForeignName> foreignNames,
  ) {
    Future<StoreCheck> run(
      HiveLibrary hive,
      Map<String, CopyRefusal> strategiesRefused,
      Map<String, CopyRefusal> foldersRefused,
    ) =>
        checkStoreAgainstHive(
          hive,
          store,
          foreignNames: foreignNames,
          breathe: _breathe,
          strategiesRefused: strategiesRefused,
          foldersRefused: foldersRefused,
        );
    return switch (mode) {
      ShadowOnly() => run(_shadowReads.library().library, const {}, const {}),
      Mirroring(:final mirror) => mirror.check(
          (hive) => run(hive, mirror.refusedStrategies, mirror.refusedFolders),
        ),
    };
  }
}

Future<void>? storeCatchUpBeforeClose() => switch (LocalLibrary.follower) {
      final StoreMirror mirror when shadowReachable => mirror.drained().timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          ),
      _ => null,
    };

Future<void> storeClosesBeforeExit(ProviderContainer container) async {
  final store = container.read(libraryStoreProvider.notifier);
  switch (storeCatchUpBeforeClose()) {
    case null:
      await store.close();
    case final catchingUp:
      await catchingUp;
      await store.close().timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
  }
}

void closeLibraryStoreOnExit(ProviderContainer container) {
  AppLifecycleListener(
    onExitRequested: () async {
      await storeClosesBeforeExit(container);
      return ui.AppExitResponse.exit;
    },
  );
}
