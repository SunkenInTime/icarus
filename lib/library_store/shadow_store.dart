import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/hive_files.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/ui_watch.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

final libraryStoreProvider =
    NotifierProvider<LibraryStoreNotifier, LibraryStoreState>(
  LibraryStoreNotifier.new,
);

class LibraryStoreNotifier extends Notifier<LibraryStoreState> {
  Future<void>? _closing;

  @override
  LibraryStoreState build() => const LibraryStoreOff();

  Future<LibraryStoreOpened> open(File file) async {
    state = LibraryStoreOpening(file);
    final opened = await openLibraryStore(file);
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

StoreMirror storeMirror() =>
    StoreMirror(readHive: _hiveLibrary, breathe: _betweenAnimations);

Future<void> _betweenAnimations() => Future.any([
      SchedulerBinding.instance.scheduleTask<void>(() {}, Priority.idle),
      Future<void>.delayed(const Duration(milliseconds: 500)),
    ]);

final shadowProvider = NotifierProvider<ShadowNotifier, ShadowState>(
  ShadowNotifier.new,
);

Future<void> _breathe() => Future<void>.delayed(Duration.zero);

Set<String> _libraryBoxFiles() => {
      '${Hive.box<StrategyData>(HiveBoxNames.strategiesBox).name}.hive',
      '${Hive.box<Folder>(HiveBoxNames.foldersBox).name}.hive',
    };

HiveLibrary _hiveLibrary() => HiveLibrary(
      strategies: Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values,
      folders: Hive.box<Folder>(HiveBoxNames.foldersBox).values,
    );

class ShadowNotifier extends Notifier<ShadowState> {
  Future<void>? running;

  @override
  ShadowState build() => const ShadowIdle();

  ShadowMode mode = const ShadowOnly();

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
            _hiveLibrary,
            store,
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
      if (mode case Mirroring(:final mirror)) await mirror.drained();
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
              if (_libraryBoxFiles().contains(name)) name,
          ],
          otherHiveFilesChanged: [
            for (final name in changed)
              if (!_libraryBoxFiles().contains(name)) name,
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

  Future<StoreCheck> checkAgain(LibraryStoreReady ready) async {
    if (mode case Mirroring(:final mirror)) await mirror.drained();
    return _check(ready.store, ready.foreignNames);
  }

  Future<StoreCheck> _check(
    LibraryStore store,
    List<ForeignName> foreignNames,
  ) =>
      checkStoreAgainstHive(
        _hiveLibrary(),
        store,
        foreignNames: foreignNames,
        breathe: _breathe,
        strategiesRefused: switch (mode) {
          ShadowOnly() => const {},
          Mirroring(:final mirror) => mirror.refusedStrategies,
        },
        foldersRefused: switch (mode) {
          ShadowOnly() => const {},
          Mirroring(:final mirror) => mirror.refusedFolders,
        },
      );
}

Future<void> storeCatchesUpBeforeExit(ProviderContainer container) async {
  if (!shadowReachable) return;
  if (container.read(shadowProvider.notifier).mode
      case Mirroring(:final mirror)) {
    await mirror.drained().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
  }
}

void closeLibraryStoreOnExit(ProviderContainer container) {
  AppLifecycleListener(
    onExitRequested: () async {
      await storeCatchesUpBeforeExit(container);
      await container.read(libraryStoreProvider.notifier).close();
      return ui.AppExitResponse.exit;
    },
  );
}
