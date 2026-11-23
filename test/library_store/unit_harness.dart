import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/ops_follower.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus_library/icarus_library.dart' hide UserAction;

final class UnitHarness {
  UnitHarness._(
      this.container, this.mirror, this.journal, this.follower, this.store);

  final ProviderContainer container;
  final StoreMirror mirror;
  final ActionJournal journal;
  final OpsFollower follower;
  final LibraryStore store;

  ActionOpsTally get tally => journal.tally;

  var faultOnNextReach = false;

  Future<UnitDelta> measure(FutureOr<void> Function() perform) async {
    final before = UnitDelta._counts(tally);
    final findings = tally.findings.length;
    final notJudged = {...tally.notJudged};
    final discarded = {...tally.discarded};
    final opened = tally.unitsOpened;
    await perform();
    await settle();
    final after = UnitDelta._counts(tally);
    return UnitDelta(
      outcomes: {
        for (final outcome in UnitOutcome.values)
          if (after[outcome]! > before[outcome]!) outcome,
      },
      judged: tally.unitsJudged - before[null]!,
      findings: tally.findings.sublist(findings),
      notJudged: {
        for (final MapEntry(:key, :value) in tally.notJudged.entries)
          if (value > (notJudged[key] ?? 0)) key: value - (notJudged[key] ?? 0),
      },
      discarded: {
        for (final MapEntry(:key, :value) in tally.discarded.entries)
          if (value > (discarded[key] ?? 0)) key: value - (discarded[key] ?? 0),
      },
      opened: tally.unitsOpened - opened,
    );
  }

  Future<void> settle() async {
    for (var turn = 0; turn < 6; turn++) {
      await Future<void>.delayed(Duration.zero);
      await mirror.drained();
    }
  }

  Future<void> silently(FutureOr<void> Function() change) async {
    ActionProvider.editFollower = null;
    try {
      await change();
    } finally {
      ActionProvider.editFollower = follower;
    }
    await settle();
  }

  Future<void> dispose() async {
    follower.detach();
    ActionProvider.editFollower = null;
    LocalLibrary.follower = null;
    await store.close();
  }
}

final class UnitDelta {
  const UnitDelta({
    required this.outcomes,
    required this.judged,
    required this.findings,
    required this.notJudged,
    required this.discarded,
    required this.opened,
  });

  final Set<UnitOutcome> outcomes;
  final int judged;
  final List<UnitFinding> findings;
  final Map<String, int> notJudged;
  final Map<String, int> discarded;
  final int opened;

  List<String> get uncovered => [for (final f in findings) ...f.uncovered];

  List<String> get wrong => [for (final f in findings) ...f.wrong];

  List<String> get stale => [for (final f in findings) ...f.stale];

  static Map<UnitOutcome?, int> _counts(ActionOpsTally tally) => {
        UnitOutcome.noFinding: tally.noFinding,
        UnitOutcome.changedWithoutAction: tally.changedWithoutAction,
        UnitOutcome.beforeNotOnCanvas: tally.beforeNotOnCanvas,
        UnitOutcome.opsWrong: tally.opsWrong,
        null: tally.unitsJudged,
      };

  @override
  String toString() => 'outcomes $outcomes, judged $judged, not judged '
      '$notJudged, discarded $discarded, changed without an action '
      '$uncovered, before did not match the canvas $stale, ops wrong $wrong';
}

Future<Directory> openUnitHive() async {
  CoordinateSystem(playAreaSize: const Size(1920, 1080));
  final directory = await Directory.systemTemp.createTemp('icarus-units-');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => directory.path,
  );
  Hive.init(directory.path);
  if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
  await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
  await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
  await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
  await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
  await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
  return directory;
}

Future<UnitHarness> openInEditor(
  ProviderContainer container,
  StrategyData strategy, {
  bool follow = true,
}) async {
  final migrated = StrategyMigrator.migrateToCurrentVersion(strategy);
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(migrated.id, migrated);
  final journal = ActionJournal();
  final mirror = StoreMirror(
    reads: HiveReads(),
    betweenAnimations: () => Future<void>.value(),
    actions: journal,
  );
  LocalLibrary.follower = mirror;
  final store = switch (await LibraryStore.open(
    MemoryEngine(MemoryStorage()),
    canRead: appCanRead,
  )) {
    StoreOpened(:final store) => store,
    StoreNotOpened(:final problem) => fail('$problem'),
  };
  if (follow) {
    final writes = LibraryBoxWrites();
    await mirror.copyThenFollow(store, writes: writes);
    await writes.stop();
  }
  late final UnitHarness harness;
  final follower = OpsFollower(mirror, () {
    if (harness.faultOnNextReach) {
      harness.faultOnNextReach = false;
      throw StateError('the test broke the follower');
    }
    return container;
  });
  harness = UnitHarness._(container, mirror, journal, follower, store);
  ActionProvider.editFollower = follower;
  follower.attach();
  expect(
    await container.read(strategyProvider.notifier).loadFromHive(migrated.id),
    isTrue,
  );
  await harness.settle();
  if (follow) {
    expect(journal.tally.takenUp, 1, reason: 'the strategy is taken up');
  }
  return harness;
}
