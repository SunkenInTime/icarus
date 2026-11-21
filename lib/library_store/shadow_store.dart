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
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
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

final class UiStats {
  const UiStats({
    required this.longestMainBlock,
    required this.frames,
    required this.worstFrameGap,
    required this.frameGapsOver50ms,
    required this.worstBuild,
    required this.worstRaster,
  });

  final Duration longestMainBlock;
  final int frames;
  final Duration worstFrameGap;
  final int frameGapsOver50ms;
  final Duration worstBuild;
  final Duration worstRaster;

  @override
  String toString() =>
      'longest main isolate block ${longestMainBlock.inMilliseconds} ms; '
      'frames $frames, worst gap ${worstFrameGap.inMilliseconds} ms, '
      'gaps over 50 ms $frameGapsOver50ms, worst build '
      '${worstBuild.inMilliseconds} ms, worst raster '
      '${worstRaster.inMilliseconds} ms';
}

final class _LibraryBoxWrites {
  _LibraryBoxWrites() {
    _subscriptions = [
      for (final events in [
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).watch(),
        Hive.box<Folder>(HiveBoxNames.foldersBox).watch(),
      ])
        events.listen((_) => count++),
    ];
  }

  late final List<StreamSubscription<BoxEvent>> _subscriptions;
  var count = 0;

  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}

final class _UiWatch {
  var _watching = true;
  var _started = false;
  var _longestMainBlock = Duration.zero;
  var _frames = 0;
  var _frameGapsOver50ms = 0;
  var _worstFrameGap = Duration.zero;
  var _worstBuild = Duration.zero;
  var _worstRaster = Duration.zero;
  late final Future<void> _done = Future.wait([_watchFrames(), _watchMain()]);

  void _noteTimings(List<ui.FrameTiming> timings) {
    for (final timing in timings) {
      if (timing.buildDuration > _worstBuild)
        _worstBuild = timing.buildDuration;
      if (timing.rasterDuration > _worstRaster) {
        _worstRaster = timing.rasterDuration;
      }
    }
  }

  Future<void> _watchFrames() async {
    final scheduler = SchedulerBinding.instance;
    scheduler.addTimingsCallback(_noteTimings);
    var last = Stopwatch()..start();
    while (_watching) {
      scheduler.scheduleFrame();
      await scheduler.endOfFrame;
      final gap = last.elapsed;
      last = Stopwatch()..start();
      _frames++;
      if (gap > _worstFrameGap) _worstFrameGap = gap;
      if (gap.inMilliseconds > 50) _frameGapsOver50ms++;
    }
    scheduler.removeTimingsCallback(_noteTimings);
  }

  Future<void> _watchMain() async {
    var last = Stopwatch()..start();
    while (_watching) {
      await Future<void>.delayed(Duration.zero);
      if (last.elapsed > _longestMainBlock) _longestMainBlock = last.elapsed;
      last = Stopwatch()..start();
    }
  }

  void start() {
    _started = true;
    unawaited(_done);
  }

  Future<UiStats> stop() async {
    _watching = false;
    if (_started) await _done;
    return UiStats(
      longestMainBlock: _longestMainBlock,
      frames: _frames,
      worstFrameGap: _worstFrameGap,
      frameGapsOver50ms: _frameGapsOver50ms,
      worstBuild: _worstBuild,
      worstRaster: _worstRaster,
    );
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

  void begin({
    required Future<LibraryStoreOpened> opening,
    required Future<void> firstFrame,
    required String hiveDirectory,
  }) =>
      running = _run(
        opening: opening,
        firstFrame: firstFrame,
        hiveDirectory: hiveDirectory,
      );

  Future<void> _run({
    required Future<LibraryStoreOpened> opening,
    required Future<void> firstFrame,
    required String hiveDirectory,
  }) async {
    final opened = await opening;
    final LibraryStore store;
    switch (opened) {
      case LibraryStoreReady(store: final ready):
        store = ready;
      case LibraryStoreHeldElsewhere() ||
            LibraryStoreRefused() ||
            LibraryStoreTooSmall():
        state = ShadowNotOpened(opened);
        return;
    }
    await firstFrame;
    final before = await HiveFiles.of(Directory(hiveDirectory));
    final hive = _hiveLibrary();
    final writes = _LibraryBoxWrites();
    final copyWatch = _UiWatch()..start();
    final checkWatch = _UiWatch();
    try {
      final copyClock = Stopwatch()..start();
      state = ShadowCopying(0, hive.strategies.length);
      final copy = await copyHiveIntoStore(
        hive,
        store,
        breathe: _breathe,
        progress: (done, total) => state = ShadowCopying(done, total),
      );
      final copyTook = copyClock.elapsed;
      final uiDuringCopy = await copyWatch.stop();
      state = const ShadowChecking();
      checkWatch.start();
      final checkClock = Stopwatch()..start();
      final check = await checkStoreAgainstHive(hive, store, breathe: _breathe);
      final checkTook = checkClock.elapsed;
      final uiDuringCheck = await checkWatch.stop();
      final after = await HiveFiles.of(Directory(hiveDirectory));
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
            for (final name in after.changedSince(before))
              if (_libraryBoxFiles().contains(name)) name,
          ],
          otherHiveFilesChanged: [
            for (final name in after.changedSince(before))
              if (!_libraryBoxFiles().contains(name)) name,
          ],
          libraryBoxWrites: writes.count,
        ),
      );
    } finally {
      await copyWatch.stop();
      await checkWatch.stop();
      await writes.stop();
    }
  }

  Future<StoreCheck> checkAgain(LibraryStore store) =>
      checkStoreAgainstHive(_hiveLibrary(), store, breathe: _breathe);
}

void closeLibraryStoreOnExit(ProviderContainer container) {
  AppLifecycleListener(
    onExitRequested: () async {
      await container.read(libraryStoreProvider.notifier).close();
      return ui.AppExitResponse.exit;
    },
  );
}
