import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/ops_follower.dart';
import 'package:icarus/library_store/ops_verdict.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus_library/icarus_library.dart' hide UserAction;

import '../library_rows/generated_strategies.dart';
import 'unit_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  setUpAll(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    appProviderContainer = container;
  });
  setUp(() async => openUnitHive());
  tearDown(() async {
    LocalLibrary.follower = null;
    ActionProvider.editFollower = null;
    await Hive.close();
  });

  var opened = 0;
  StrategyData strategy({int pages = 1}) {
    opened += 1;
    final id = 'journaled-$opened';
    return generatedStrategy(Optionals.unset).copyWith(
      id: id,
      pages: [
        for (var n = 0; n < pages; n++)
          generatedPage(
            id: '$id-p$n',
            sortIndex: n,
            optionals: Optionals.set,
            isAttack: true,
          ).copyWith(),
      ],
    );
  }

  Future<UnitHarness> open({int pages = 1}) async {
    final h = await openInEditor(container, strategy(pages: pages));
    addTearDown(h.dispose);
    return h;
  }

  String openId() => container.read(strategyProvider).strategyId!;

  Future<StrategyRowSet> storedRows(UnitHarness h) async =>
      switch (await readStoredRows(h.store, openId())) {
        StoredRowsRead(:final rows) => rows,
        StoredRowsNot(:final stored) => fail('$stored'),
      };

  Future<String?> storedCaption(UnitHarness h, String itemId) async {
    final rows = await storedRows(h);
    final row = rows.elements.whereType<LiveElement>().singleWhere(
          (row) => row.publicId == itemId,
        );
    return (row.payload.toJson()['data'] as Map)['caption'] as String?;
  }

  test(
      'a Hive save behind the canvas is reported against the store and never '
      'moves the store back', () async {
    final h = await open();
    final hiveBefore = const LocalLibrary().storedStrategy(openId())!;
    final behind = hiveBefore.copyWith();
    final text = container.read(textProvider).first.id;
    final silent = await h.measure(() => h.silently(() => container
        .read(textProvider.notifier)
        .setCaption(text, 'Caption only the canvas has')));
    expect(silent.outcomes, {UnitOutcome.changedWithoutAction},
        reason: '$silent');
    expect(await storedCaption(h, text), 'Caption only the canvas has');

    final save =
        await h.measure(() => const LocalLibrary().savePageOnScreen(behind));

    expect(save.judged, 0, reason: '$save');
    expect(h.tally.hiveSavesDifferent, 1);
    expect(h.tally.hiveFindings.single.differences,
        contains(contains('$text caption')));
    expect(await storedCaption(h, text), 'Caption only the canvas has');
  });

  test(
      'a Hive save made in the same turn as a page command is compared after '
      'that turn\'s ops: a rename differs only where Hive\'s stored copy is '
      'behind the canvas', () async {
    final h = await open();
    final page = const LocalLibrary().storedStrategy(openId())!.pages.first.id;
    final saves = h.tally.hiveSaves;
    final verdicts = h.tally.hiveSavesEqualToStore + h.tally.hiveSavesDifferent;
    final renamed = await h.measure(() =>
        container.read(strategyProvider.notifier).renamePage(page, 'Retake'));

    expect(renamed.outcomes, {UnitOutcome.noFinding}, reason: '$renamed');
    expect(h.tally.hiveSaves, greaterThan(saves));
    expect(h.tally.hiveSavesEqualToStore + h.tally.hiveSavesDifferent,
        greaterThan(verdicts),
        reason: 'the save was compared with the store');
    expect(
      [for (final f in h.tally.hiveFindings) ...f.differences],
      everyElement(isIn([
        'strategy ${openId()} themeProfile',
        'image ${openId()}-p0-image scale',
      ])),
      reason: 'only what the canvas changed at open, which a page command '
          'writes to Hive from its stored copy',
    );
  });

  test(
      'a Hive write of the open strategy that fails is counted as failed and '
      'never compared', () async {
    final h = await open();
    final stored = const LocalLibrary().storedStrategy(openId())!.copyWith();
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).close();
    final write = await const LocalLibrary().savePageOnScreen(stored);
    await h.settle();

    expect(write, isA<LibraryWriteFailed>());
    expect(h.tally.hiveSavesFailed, 1);
    expect(h.tally.hiveSaves, 0);
  });

  test(
      'putting the store right after a delete removes the strategy first, so '
      'the deleted row cannot refuse the image, and the store then holds the '
      'canvas', () async {
    final h = await open();
    final text = container.read(textProvider).first.id;
    final agent = container.read(agentProvider).first.id;
    final deleted = await h.measure(
        () => container.read(textProvider.notifier).removeTextAsAction(text));
    expect(deleted.outcomes, {UnitOutcome.noFinding});
    expect(
        (await storedRows(h)).elements.whereType<DeletedElement>(), isNotEmpty);

    final silent = await h.measure(() => h.silently(() => container
        .read(agentProvider.notifier)
        .setCaption(agent, 'Put right from the canvas')));
    expect(silent.outcomes, {UnitOutcome.changedWithoutAction});
    expect(h.tally.repairsFromCanvas, greaterThan(0));
    expect(h.mirror.refusedStrategies, isEmpty);
    expect((await storedRows(h)).elements.whereType<DeletedElement>(), isEmpty);
    expect(await storedCaption(h, agent), 'Put right from the canvas');
  });

  test(
      'the open strategy is not known equal while it is taken up, so read mode '
      'draws it from Hive, and closing puts Hive back and hands it back',
      () async {
    final h = await open();
    final id = openId();
    expect(h.mirror.strategiesNotKnownEqual, contains(id));
    expect(h.tally.notJudged, containsPair('the strategy opening', 1));
    expect(h.tally.notJudged.keys, isNot(contains('no local strategy open')));

    final text = container.read(textProvider).first;
    final caption = text.caption;
    await h.measure(() =>
        container.read(textProvider.notifier).setCaption(text.id, 'Unsaved'));
    await container.read(strategyProvider.notifier).clearCurrentStrategy();
    await h.settle();

    expect(h.tally.released, 1);
    expect(h.tally.releasesThatPutHiveBack, 1);
    expect(h.mirror.strategiesNotKnownEqual, isNot(contains(id)));
    final rows = switch (await readStoredRows(h.store, id)) {
      StoredRowsRead(:final rows) => rows,
      StoredRowsNot(:final stored) => fail('$stored'),
    };
    final row = rows.elements
        .whereType<LiveElement>()
        .singleWhere((row) => row.publicId == text.id);
    expect((row.payload.toJson()['data'] as Map)['caption'], caption);
  });

  test(
      'after a follower fault no unit is judged, and judging starts again once '
      'the strategy is taken up again', () async {
    final h = await open();
    final id = openId();
    final text = container.read(textProvider).first.id;
    void caption(String value) =>
        container.read(textProvider.notifier).setCaption(text, value);

    h.faultOnNextReach = true;
    final faulted = await h.measure(() => caption('During the fault'));
    expect(h.tally.followerFaults, hasLength(1));
    expect(ActionProvider.editFollower, isNull);
    expect(faulted.judged, 0, reason: '$faulted');
    expect(faulted.notJudged, {'a follower fault': 1});

    final after = await h.measure(() => caption('After the fault'));
    expect(after.judged, 0, reason: '$after');
    expect(after.notJudged, {'a follower fault': 1});

    await container.read(strategyProvider.notifier).clearCurrentStrategy();
    await h.settle();
    expect(
        await container.read(strategyProvider.notifier).loadFromHive(id), true);
    await h.settle();
    expect(ActionProvider.editFollower, same(h.follower));
    final again = await h.measure(() => caption('Taken up again'));
    expect(again.outcomes, {UnitOutcome.noFinding}, reason: '$again');
    expect(h.journal.addsUp, isTrue);
  });

  test(
      'a text being typed is one unit: nothing is judged while the draft is '
      'open, and committing it is judged with its action', () async {
    final h = await open();
    final text = container.read(textProvider).first.id;
    final drafts = container.read(textDraftProvider.notifier);
    for (final typed in ['P', 'Pl', 'Pla', 'Plant']) {
      final keystroke = await h.measure(() => drafts.setDraft(text, typed));
      expect(keystroke.judged + keystroke.notJudged.length, 0,
          reason: '$typed: $keystroke');
    }
    final committed = await h.measure(() => drafts.commitDraft(text));

    expect(committed.judged, 1, reason: '$committed');
    expect(committed.outcomes, {UnitOutcome.noFinding});
    expect(h.tally.findings, isEmpty);
  });

  group('every unit opened gets a disposition, and nothing is dropped unseen',
      () {
    final router = GestureBinding.instance.pointerRouter;

    test(
        'an edit made after a page switch under a held pointer is counted as '
        'discarded, not lost in the page load', () async {
      final h = await open(pages: 2);
      final other = container
          .read(strategyPageSessionProvider)
          .availablePageIds
          .firstWhere((id) =>
              id != container.read(strategyPageSessionProvider).activePageId);
      final held = await h.measure(() async {
        router.route(const PointerDownEvent(pointer: 51));
        await container.read(strategyProvider.notifier).setActivePage(other);
        await Future<void>.delayed(Duration.zero);
        final agent = container.read(agentProvider).first.id;
        container
            .read(agentProvider.notifier)
            .setCaption(agent, 'Edited across the switch');
        await Future<void>.delayed(Duration.zero);
        router.route(const PointerUpEvent(pointer: 51));
      });

      expect(held.discarded, {'actions inside a page switch': 1},
          reason: '$held');
      expect(held.judged, 0);
      expect(h.journal.addsUp, isTrue);
    });

    test(
        'an edit in one strategy, held until another opens, is counted as '
        'discarded', () async {
      final h = await open();
      final second = strategy();
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(second.id, StrategyMigrator.migrateToCurrentVersion(second));
      final held = await h.measure(() async {
        router.route(const PointerDownEvent(pointer: 52));
        final text = container.read(textProvider).first.id;
        container
            .read(textProvider.notifier)
            .setCaption(text, 'Edited before the other opened');
        await Future<void>.delayed(Duration.zero);
        await container.read(strategyProvider.notifier).loadFromHive(second.id);
        await Future<void>.delayed(Duration.zero);
        router.route(const PointerUpEvent(pointer: 52));
      });

      expect(held.discarded, {'actions as the strategy changed': 1},
          reason: '$held');
      expect(h.tally.takenUp, 2);
      expect(h.journal.addsUp, isTrue);
    });

    test(
        'a unit still held when the run ends is counted as discarded, and '
        'nothing is left open', () async {
      final h = await open();
      router.route(const PointerDownEvent(pointer: 53));
      final text = container.read(textProvider).first.id;
      container
          .read(textProvider.notifier)
          .setCaption(text, 'Still held at the end');
      await h.settle();
      expect(h.journal.unitsStillOpen, 1);
      expect(h.journal.addsUp, isTrue);

      await h.mirror.releaseTakenUp();
      router.route(const PointerUpEvent(pointer: 53));

      expect(h.tally.discarded, {'actions in a unit still open at the end': 1});
      expect(h.journal.unitsStillOpen, 0);
      expect(h.tally.unitsOpened, h.tally.unitsDisposed);
    });

    test(
        'a unit whose second commit the store refuses, after its first '
        'landed, is not judged with the reason, and the units still add up',
        () async {
      final engine = _RefusingEngine();
      final h = await openInEditor(container, strategy(),
          engine: (memory) => engine..inner = memory);
      addTearDown(h.dispose);
      final agent = container.read(agentProvider).first.id;
      final text = container.read(textProvider).first.id;
      engine.refuseFrom = engine.commits + 2;
      final unit = await h.measure(() {
        container
            .read(agentProvider.notifier)
            .setCaption(agent, 'Lands in the store');
        container
            .read(textProvider.notifier)
            .setCaption(text, 'Refused by the store');
      });

      expect(unit.notJudged, {'the store did not save': 1}, reason: '$unit');
      expect(h.mirror.phase, isA<MirrorStopped>());
      expect(h.tally.unitsOpened, h.tally.unitsDisposed);
    });

    test(
        'whether the last action\'s commit has returned is told by that '
        'action alone, not by op and action totals from earlier units',
        () async {
      final engine = _RefusingEngine();
      final h = await openInEditor(container, strategy(),
          engine: (memory) => engine..inner = memory);
      addTearDown(h.dispose);
      await h.measure(
          () => container.read(actionProvider.notifier).clearAllAsAction());
      expect(h.tally.opsCommitted, greaterThan(h.tally.actions));

      final hold = engine.hold = Completer<void>();
      final agentsBefore = container.read(agentProvider).length;
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
          id: 'held-agent',
          type: AgentType.jett,
          position: const Offset(40, 40)));
      for (var turn = 0; turn < 5; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(container.read(agentProvider), hasLength(agentsBefore + 1));
      expect(h.journal.settled(h.journal.lastAction), isFalse);

      engine.hold = null;
      hold.complete();
      await h.settle();
      expect(h.journal.settled(h.journal.lastAction), isTrue);
    });

    test(
        'opening a strategy before the mirror is following is counted, not '
        'dropped', () async {
      final h = await openInEditor(container, strategy(), follow: false);
      addTearDown(h.dispose);

      expect(h.tally.takenUp, 0);
      expect(h.tally.notJudged, {'the mirror was not following yet': 1});
      expect(h.journal.addsUp, isTrue);
    });
  });

  test(
      'a follower whose error cannot even be described leaves add, undo and '
      'redo alone through the real hooks, detaches each time and is counted',
      () async {
    final journal = ActionJournal();
    final mirror = StoreMirror(
      reads: HiveReads(),
      betweenAnimations: () => Future<void>.value(),
      actions: journal,
    );
    final own = ProviderContainer();
    addTearDown(own.dispose);
    OpsFollower throwing() => OpsFollower(mirror, () => throw _Unprintable());
    final agent = generatedPage(
      id: 'canvas',
      sortIndex: 0,
      optionals: Optionals.set,
      isAttack: true,
    ).agentData.first;
    own.read(agentProvider.notifier).addAgent(agent);
    final actions = own.read(actionProvider.notifier);

    ActionProvider.editFollower = throwing();
    own.read(agentProvider.notifier).setWeapon(agent.id, WeaponType.vandal);
    expect(ActionProvider.editFollower, isNull);
    expect(own.read(actionProvider).last, isA<WeaponSelectionAction>());
    expect(own.read(agentProvider).single.weapon, WeaponType.vandal);

    ActionProvider.editFollower = throwing();
    actions.undoAction();
    expect(ActionProvider.editFollower, isNull);
    expect(actions.poppedItems, hasLength(1));
    expect(own.read(agentProvider).single.weapon, isNot(WeaponType.vandal));

    ActionProvider.editFollower = throwing();
    actions.redoAction();
    expect(ActionProvider.editFollower, isNull);
    expect(actions.poppedItems, isEmpty);
    expect(own.read(agentProvider).single.weapon, WeaponType.vandal);

    expect(journal.tally.followerFaults, hasLength(3));
  });

  test(
      'the comparison reads the order of lineups inside each group, and the '
      'order of the groups, as separate differences', () {
    final page = generatedPage(
      id: 'lineups',
      sortIndex: 0,
      optionals: Optionals.unset,
      isAttack: true,
      lineups: sharedSpotLineups('pl'),
    ).copyWith();
    final graph = page.lineUpGraph;
    StrategyData withLinks(List<String> ids) => strategy().copyWith(pages: [
          page.copyWith(
            lineUpGraph: LineUpGraph(
              origins: graph.origins,
              landings: graph.landings,
              links: [
                for (final id in ids)
                  graph.links.singleWhere((link) => link.id == 'pl-link-$id'),
              ],
            ),
          ),
        ]);
    List<String> between(List<String> expected, List<String> read) => [
          for (final difference
              in readBackDifferences(withLinks(expected), withLinks(read)))
            '$difference',
        ];

    expect(between(['a', 'b', 'c', 'd'], ['b', 'c', 'd', 'a']),
        ['lineup group pl-link-a order']);
    expect(between(['a', 'b', 'c', 'd'], ['d', 'a', 'b', 'c']),
        ['lineup groups lineups order']);
    expect(between(['a', 'b', 'c', 'd'], ['a', 'b', 'c', 'd']), isEmpty);
  });
}

final class _Unprintable implements Exception {
  @override
  String toString() => throw StateError('cannot describe this error');
}

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );
}

final class _RefusingEngine implements StorageEngine {
  late StorageEngine inner;
  var commits = 0;
  var refuseFrom = 1 << 30;
  Completer<void>? hold;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
        Leased(:final lease) => Leased(_RefusingLease(lease, this)),
        final other => other,
      };
}

final class _RefusingLease implements StorageLease {
  _RefusingLease(this._inner, this._engine);

  final StorageLease _inner;
  final _RefusingEngine _engine;

  @override
  int get maxKeyLength => _inner.maxKeyLength;

  @override
  LeaseStatus get status => _inner.status;

  @override
  Future<KeyRead> read(String area, String key) => _inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      _inner.keys(area, prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _inner.entries(area, prefix);

  @override
  Future<Stored<List<String>>> areas(String prefix) => _inner.areas(prefix);

  @override
  Future<Committing> commit(List<Change> changes) async {
    if (_engine.hold case final hold?) await hold.future;
    _engine.commits += 1;
    if (_engine.commits >= _engine.refuseFrom) {
      return const CommitRefused(DeviceFailure('refused by the test'));
    }
    return _inner.commit(changes);
  }

  @override
  Future<Releasing> release() => _inner.release();
}
