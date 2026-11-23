import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/canvas_units.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

import '../library_rows/generated_strategies.dart';
import 'unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
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
  StrategyData strategy() {
    opened += 1;
    final id = 'cleared-$opened';
    return generatedStrategy(Optionals.unset).copyWith(
      id: id,
      pages: [
        generatedPage(
          id: '$id-p0',
          sortIndex: 0,
          optionals: Optionals.unset,
          isAttack: true,
        ).copyWith(),
      ],
    );
  }

  test(
      'a first caption, whose action starts from the cleared value \'\' where '
      'the canvas held none, is no finding', () async {
    final h = await openInEditor(container, strategy());
    addTearDown(h.dispose);
    final agent = container.read(agentProvider).first;
    expect(agent.caption, isNull);

    final unit = await h.measure(() =>
        container.read(agentProvider.notifier).setCaption(agent.id, 'Plant B'));

    expect(unit.outcomes, {UnitOutcome.noFinding}, reason: '$unit');
  });

  test(
      'a first wall, whose action starts from the cleared value [] where the '
      'canvas held none, is no finding', () async {
    final h = await openInEditor(container, strategy());
    addTearDown(h.dispose);
    final ability = container.read(abilityProvider).first;
    expect(ability.wallPath, isNull);

    final unit = await h.measure(() => container
        .read(abilityProvider.notifier)
        .setWallPath(ability.id, const [Offset(10, 10), Offset(60, 40)]));

    expect(unit.outcomes, {UnitOutcome.noFinding}, reason: '$unit');
  });

  test(
      'a before of \'\' where the canvas held "Plant B" is still a finding, '
      'naming both values', () {
    final start = strategy();
    final page = start.pages.single;
    final agent = page.agentData.first;
    final held = ActionObjectState.agent(agent)..agent!.caption = 'Plant B';
    final withCaption = start.copyWith(pages: [
      page.copyWith(agentData: [
        held.agent!,
        ...page.agentData.skip(1),
      ]),
    ]);
    final before = ActionObjectState.agent(agent)..agent!.caption = '';
    final after = ActionObjectState.agent(agent)..agent!.caption = 'Retake';

    final replayed =
        replayDeclared(withCaption, [ObjectChanged(page.id, before, after)]);
    final cleared =
        replayDeclared(start, [ObjectChanged(page.id, before, after)]);

    expect([
      for (final s in replayed.stale) '$s'
    ], [
      'agent ${agent.id} caption: the action\'s before is , the canvas held '
          'Plant B',
    ]);
    expect(cleared.stale, isEmpty);
  });
}
