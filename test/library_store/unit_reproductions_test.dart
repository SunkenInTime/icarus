import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

import '../library_rows/generated_strategies.dart';
import 'package:icarus/strategy/local_library.dart';

import 'unit_harness.dart';

LineUpGraph _threeGroups(String prefix) {
  final shape = sharedSpotLineups(prefix);
  LineUpLink link(String id, int origin, int landing) => LineUpLink(
        id: '$prefix-link-$id',
        originId: '$prefix-origin-$origin',
        landingId: '$prefix-landing-$landing',
      );
  return LineUpGraph(
    origins: shape.origins,
    landings: shape.landings,
    links: [link('x', 1, 1), link('y', 2, 2), link('z', 3, 3)],
  );
}

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
  tearDown(() async => Hive.close());

  var opened = 0;
  StrategyData strategy({LineUpGraph Function(String prefix)? lineups}) {
    opened += 1;
    final id = 'repro-$opened';
    return generatedStrategy(Optionals.unset).copyWith(
      id: id,
      pages: [
        for (var n = 0; n < 2; n++)
          generatedPage(
            id: '$id-p$n',
            sortIndex: n,
            optionals: Optionals.set,
            isAttack: true,
            lineups: (lineups ?? sharedSpotLineups)('$id-p$n'),
          ).copyWith(),
      ],
    );
  }

  Future<UnitHarness> open([StrategyData? data]) async {
    final h = await openInEditor(container, data ?? strategy());
    addTearDown(h.dispose);
    return h;
  }

  ActionProvider actions() => container.read(actionProvider.notifier);

  test(
      'an add and its undo in two turns, with both ops dropped, are two units '
      'with ops wrong, not one equal save', () async {
    final h = await open();
    h.journal.alterOps = (label, ops) =>
        label == 'addition text' || label == 'undo addition text'
            ? const []
            : ops;
    final text = container.read(textProvider).first;
    final added = await h.measure(() => container
        .read(textProvider.notifier)
        .addText(text.copyWith(id: 'added-then-undone')));
    final undone = await h.measure(actions().undoAction);

    expect(added.outcomes, {UnitOutcome.opsWrong}, reason: '$added');
    expect(added.wrong, contains(contains('added-then-undone')));
    expect(undone.outcomes, {UnitOutcome.opsWrong}, reason: '$undone');
    expect(undone.wrong, contains(contains('added-then-undone')));
    expect(h.journal.addsUp, isTrue);
  });

  test('a turn where nothing changed gets no verdict, even when Hive is saved',
      () async {
    final h = await open();
    final id = container.read(strategyProvider).strategyId!;
    final quiet = await h.measure(
        () => container.read(strategyProvider.notifier).forceSaveNow(id));

    expect(quiet.judged, 0, reason: '$quiet');
    expect(quiet.notJudged, isEmpty);
    expect(h.tally.hiveSaves, greaterThan(0));
  });

  test(
      'a weapon change in the same turn as a note edit no action reported names '
      'the note as changed without an action, and its op carries no note',
      () async {
    final h = await open();
    final lineups = container.read(lineUpProvider.notifier);
    final graph = container.read(lineUpProvider).graph;
    final origin = graph.origins.first;
    final link = graph.links.firstWhere((l) => l.originId == origin.id);
    final turn = await h.measure(() {
      ActionProvider.editFollower = null;
      lineups.updateLink(link.copyWith(notes: 'Withheld note'));
      ActionProvider.editFollower = h.follower;
      lineups.setOriginWeapon(
        origin.id,
        origin.agent.weapon == WeaponType.operator
            ? WeaponType.marshal
            : WeaponType.operator,
      );
    });

    expect(turn.outcomes, {UnitOutcome.changedWithoutAction}, reason: '$turn');
    expect(turn.uncovered, contains(contains('notes')));
    expect(turn.wrong, isEmpty);
  });

  test(
      'a marker size change in the same turn as a colour change no action '
      'reported names the colour as changed without an action, and its op '
      'carries no colour', () async {
    final h = await open();
    final settings = container.read(strategySettingsProvider.notifier);
    final now = container.read(strategySettingsProvider);
    final turn = await h.measure(() {
      settings.updateNeutralTeamColors(!now.useNeutralTeamColors);
      actions().performTransaction(
        groups: const [ActionGroup.strategySettings],
        mutation: () => settings.updateAgentSize(now.agentSize + 4),
      );
    });

    expect(turn.outcomes, {UnitOutcome.changedWithoutAction}, reason: '$turn');
    expect(turn.uncovered, contains(contains('useNeutralTeamColors')));
    expect(turn.uncovered, isNot(contains(contains('agentSize'))));
    expect(turn.wrong, isEmpty);
  });

  test(
      'the first rename of the open strategy is a change no action reported, '
      'never an equal save compared with itself', () async {
    final h = await open();
    final id = container.read(strategyProvider).strategyId!;
    final committed = h.tally.opsCommitted;
    final renamed = await h.measure(() => container
        .read(strategyProvider.notifier)
        .renameStrategy(id, 'Renamed by the test'));

    expect(renamed.outcomes, {UnitOutcome.changedWithoutAction},
        reason: '$renamed');
    expect(renamed.uncovered, ['strategy $id name']);
    expect(h.tally.opsCommitted, committed);
  });

  test(
      'a caption edit closed with "Don\'t save" leaves the store as Hive holds '
      'it, so repeating the edit after reopening makes its op again', () async {
    final h = await open();
    final id = container.read(strategyProvider).strategyId!;
    final text = container.read(textProvider).first.id;
    void edit() => container
        .read(textProvider.notifier)
        .setCaption(text, 'Caption that was discarded');

    expect((await h.measure(edit)).outcomes, {UnitOutcome.noFinding});
    await container.read(strategyProvider.notifier).clearCurrentStrategy();
    await h.settle();
    expect(h.tally.released, 1);
    expect(h.tally.releasesThatPutHiveBack, 1);

    expect(
      await container.read(strategyProvider.notifier).loadFromHive(id),
      isTrue,
    );
    await h.settle();
    expect(h.tally.takenUp, 2);
    final committed = h.tally.opsCommitted;
    final repeated = await h.measure(edit);

    expect(repeated.outcomes, {UnitOutcome.noFinding}, reason: '$repeated');
    expect(h.tally.opsCommitted, greaterThan(committed));
  });

  test(
      'undo while holding a view cone handle, then releasing where the drag '
      'began, is one unit that names the rotation no action declared',
      () async {
    final h = await open();
    final utilities = container.read(utilityProvider.notifier);
    int cone() => container
        .read(utilityProvider)
        .indexWhere((u) => u.type == UtilityType.viewCone90);
    final start = container.read(utilityProvider)[cone()];
    final rotated = start.rotation + 0.7;
    final length = start.length;
    final first = await h.measure(() {
      utilities.updateRotationHistory(cone());
      utilities.updateRotation(cone(), rotated, length);
    });
    expect(first.outcomes, {UnitOutcome.noFinding}, reason: '$first');

    final router = GestureBinding.instance.pointerRouter;
    final held = await h.measure(() async {
      router.route(const PointerDownEvent(pointer: 41));
      utilities.updateRotationHistory(cone());
      await Future<void>.delayed(Duration.zero);
      actions().undoAction();
      await Future<void>.delayed(Duration.zero);
      utilities.updateRotation(cone(), rotated, length);
      await Future<void>.delayed(Duration.zero);
      router.route(const PointerUpEvent(pointer: 41));
    });

    expect(held.judged, 1, reason: '$held');
    expect(held.findings.single.kind, 'undo edit utility + edit utility');
    expect(held.outcomes, {UnitOutcome.changedWithoutAction}, reason: '$held');
    expect(held.uncovered, ['utility ${start.id} rotation']);
    expect(held.wrong, isEmpty);
  });

  test(
      'deleting and restoring the lineup that joins the first and third groups '
      'keeps every group where the canvas has it', () async {
    final h = await open(strategy(lineups: _threeGroups));
    final lineups = container.read(lineUpProvider.notifier);
    final graph = container.read(lineUpProvider).graph;
    final first = graph.origins.first;
    final third = graph.landings.last;
    final bridge = LineUpLink(
      id: 'bridge',
      originId: first.id,
      landingId: third.id,
    );
    final steps = {
      'joined': () => lineups.addCopies(
          LineUpGraph(origins: [first], landings: [third], links: [bridge])),
      'deleted': () => lineups.deleteLink('bridge'),
      'restored': actions().undoAction,
      'deleted again': actions().redoAction,
      'restored again': actions().undoAction,
    };
    for (final MapEntry(key: step, value: perform) in steps.entries) {
      final unit = await h.measure(perform);
      expect(unit.outcomes, {UnitOutcome.noFinding}, reason: '$step: $unit');
    }
  });

  test('a lineup on a page made by adding a page can be edited through ops',
      () async {
    final h = await open();
    final session = container.read(strategyPageSessionProvider);
    final original = session.activePageId;
    await container.read(strategyProvider.notifier).addPage('Copied');
    await h.settle();
    final copied = container
        .read(strategyPageSessionProvider)
        .availablePageIds
        .firstWhere((id) => !session.availablePageIds.contains(id));
    if (container.read(strategyPageSessionProvider).activePageId != copied) {
      await container.read(strategyProvider.notifier).setActivePage(copied);
      await h.settle();
    }
    expect(container.read(strategyPageSessionProvider).activePageId, copied);
    expect(copied, isNot(original));
    final link = container.read(lineUpProvider).graph.links.first;
    final edited = await h.measure(() => container
        .read(lineUpProvider.notifier)
        .updateLink(link.copyWith(notes: 'Edited on the copy')));

    expect(edited.outcomes, {UnitOutcome.noFinding}, reason: '$edited');
  });

  test('a lineup copied to the next page can be edited there through ops',
      () async {
    final h = await open();
    final link = container.read(lineUpProvider).graph.links.first;
    final session = container.read(strategyPageSessionProvider);
    final destination =
        session.availablePageIds.firstWhere((id) => id != session.activePageId);
    final strategyId = container.read(strategyProvider).strategyId!;
    final linksBefore = {
      for (final l in const LocalLibrary()
          .storedStrategy(strategyId)!
          .pages
          .singleWhere((page) => page.id == destination)
          .lineUpGraph
          .links)
        l.id,
    };
    final copied = await h.measure(() =>
        container.read(strategyProvider.notifier).copyLineUpsToAdjacentPage(
          linkIds: {link.id},
          direction: PageTransitionDirection.forward,
        ));
    expect(copied.outcomes, {UnitOutcome.noFinding}, reason: '$copied');
    await container.read(strategyProvider.notifier).setActivePage(destination);
    await h.settle();
    final there = container
        .read(lineUpProvider)
        .graph
        .links
        .where((l) => !linksBefore.contains(l.id))
        .single;
    expect(there.id, isNot(link.id));
    expect(there.name, link.name);
    final edited = await h.measure(() => container
        .read(lineUpProvider.notifier)
        .updateLink(there.copyWith(notes: 'Edited where it was copied')));

    expect(edited.outcomes, {UnitOutcome.noFinding}, reason: '$edited');
  });

  test(
      'reordering, deleting and adding auto-named pages declares the pages '
      'they rename; the added page differs only by its copies\' ids', () async {
    opened += 1;
    final id = 'repro-$opened';
    final h = await open(generatedStrategy(Optionals.unset).copyWith(
      id: id,
      pages: [
        for (var n = 0; n < 3; n++)
          generatedPage(
            id: '$id-p$n',
            sortIndex: n,
            optionals: Optionals.set,
            isAttack: true,
            isAutoNamed: true,
          ).copyWith(name: 'Page ${n + 1}'),
      ],
    ));
    final strategies = container.read(strategyProvider.notifier);
    final steps = {
      'reorder': () => strategies.reorderPage(0, 2),
      'delete': () => strategies.deletePage('$id-p1'),
    };
    for (final MapEntry(key: step, value: perform) in steps.entries) {
      final unit = await h.measure(perform);
      expect(unit.outcomes, {UnitOutcome.noFinding}, reason: '$step: $unit');
    }
    final added = await h.measure(() => strategies.addPage());
    expect(added.uncovered, isEmpty, reason: '$added');
    expect(added.wrong.where((line) => line.contains(' name')), isEmpty,
        reason: '$added');
    expect(added.wrong, everyElement(matches(r' (missing|extra)$')),
        reason: 'only the copies\' ids differ: $added');
  });
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
