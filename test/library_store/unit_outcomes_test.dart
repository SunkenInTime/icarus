import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/const/transition_data.dart';

import '../library_rows/generated_strategies.dart';
import 'unit_harness.dart';

typedef Perform = FutureOr<void> Function(ProviderContainer c);

final class OutcomeCase {
  const OutcomeCase(
    this.kind,
    this.perform, {
    required this.names,
    this.dropLabel,
    this.setup,
    this.turnsWithNoAction = 1,
    this.asIs = _covered,
    this.notJudgedAsIs,
  });

  final String kind;
  final Perform perform;
  final Pattern names;
  final String? dropLabel;
  final Perform? setup;
  final int turnsWithNoAction;
  final Set<UnitOutcome> asIs;
  final String? notJudgedAsIs;
}

const _covered = {UnitOutcome.noFinding};

ActionObjectState _renamed(ActionObjectState object, String id) =>
    ActionObjectState.fromJson(object.kind, {...object.toJson(), 'id': id});

T _first<T>(List<T> list) => list.first;

LineUpGraph _copyOf(LineUpGraph graph, String linkId, String suffix) {
  final link = graph.links.singleWhere((l) => l.id == linkId);
  final origin = graph.origins.singleWhere((o) => o.id == link.originId);
  final landing = graph.landings.singleWhere((l) => l.id == link.landingId);
  return LineUpGraph(
    origins: [
      origin.copyWith(
        id: '${origin.id}$suffix',
        agent: origin.agent.copyWith(lineUpID: '${origin.id}$suffix'),
      ),
    ],
    landings: [
      landing.copyWith(
        id: '${landing.id}$suffix',
        ability: landing.ability.copyWith(lineUpID: '${landing.id}$suffix'),
      ),
    ],
    links: [
      link.copyWith(
        id: '${link.id}$suffix',
        originId: '${origin.id}$suffix',
        landingId: '${landing.id}$suffix',
      ),
    ],
  ).deepCopy();
}

List<OutcomeCase> _objectCases() => [
      OutcomeCase('addition agent', (c) {
        final agent = _first(c.read(agentProvider));
        c.read(agentProvider.notifier).addAgent(
            _renamed(ActionObjectState.agent(agent), 'added-agent').agent!);
      }, names: 'agent added-agent '),
      OutcomeCase('deletion agent', (c) {
        c
            .read(agentProvider.notifier)
            .removeAgentAsAction(_first(c.read(agentProvider)).id);
      }, names: '-p0-agent '),
      OutcomeCase('edit agent', (c) {
        c.read(agentProvider.notifier).setCaption(
            _first(c.read(agentProvider)).id, 'Caption the test wrote');
      }, names: '-p0-agent caption'),
      OutcomeCase('addition ability', (c) {
        final ability = _first(c.read(abilityProvider));
        c.read(abilityProvider.notifier).addAbility(
            _renamed(ActionObjectState.ability(ability), 'added-ability')
                .ability!);
      }, names: 'ability added-ability '),
      OutcomeCase('deletion ability', (c) {
        c
            .read(abilityProvider.notifier)
            .removeAbilityAsAction(_first(c.read(abilityProvider)).id);
      }, names: '-p0-ability '),
      OutcomeCase('edit ability', (c) {
        c.read(abilityProvider.notifier).setCaption(
            _first(c.read(abilityProvider)).id, 'Caption the test wrote');
      }, names: '-p0-ability caption'),
      OutcomeCase('addition drawing', (c) {
        final drawing = _first(c.read(drawingProvider).elements);
        c.read(drawingProvider.notifier).addDrawings([
          _renamed(ActionObjectState.drawing(drawing), 'added-drawing')
              .drawing!,
        ]);
      }, names: 'drawing added-drawing '),
      OutcomeCase('deletion drawing', (c) {
        c.read(drawingProvider.notifier).deleteDrawing(0);
      }, names: '-p0-free '),
      OutcomeCase('edit drawing', (c) {
        c.read(drawingProvider.notifier).translateDrawings(
          {_first(c.read(drawingProvider).elements).id},
          const Offset(4, 3),
        );
      }, names: '-p0-free listOfPoints'),
      OutcomeCase('addition text', (c) {
        final text = _first(c.read(textProvider));
        c.read(textProvider.notifier).addText(
            _renamed(ActionObjectState.text(text), 'added-text').text!);
      }, names: 'text added-text '),
      OutcomeCase('deletion text', (c) {
        c
            .read(textProvider.notifier)
            .removeTextAsAction(_first(c.read(textProvider)).id);
      }, names: '-p0-text '),
      OutcomeCase('edit text', (c) {
        c.read(textProvider.notifier).setCaption(
            _first(c.read(textProvider)).id, 'Caption the test wrote');
      }, names: '-p0-text caption'),
      OutcomeCase('addition image', (c) {
        final image = _first(c.read(placedImageProvider).images);
        c.read(placedImageProvider.notifier).addImageCopy(
            _renamed(ActionObjectState.image(image), 'added-image').image!);
      }, names: 'image added-image '),
      OutcomeCase('deletion image', (c) {
        c
            .read(placedImageProvider.notifier)
            .removeImageAsAction(_first(c.read(placedImageProvider).images).id);
      }, names: '-p0-image '),
      OutcomeCase('edit image', (c) {
        c.read(placedImageProvider.notifier).setCaption(
            _first(c.read(placedImageProvider).images).id,
            'Caption the test wrote');
      }, names: '-p0-image caption'),
      OutcomeCase('addition utility', (c) {
        final utility = _first(c.read(utilityProvider));
        c.read(utilityProvider.notifier).addUtility(
            _renamed(ActionObjectState.utility(utility), 'added-utility')
                .utility!);
      }, names: 'utility added-utility '),
      OutcomeCase('deletion utility', (c) {
        c
            .read(utilityProvider.notifier)
            .removeUtilityAsAction(_first(c.read(utilityProvider)).id);
      }, names: '-p0-utility-spike '),
      OutcomeCase('edit utility', (c) {
        c.read(utilityProvider.notifier).setCaption(
            _first(c.read(utilityProvider)).id, 'Caption the test wrote');
      }, names: '-p0-utility-spike caption'),
      OutcomeCase('weapon of agent', (c) {
        final agent = _first(c.read(agentProvider));
        c.read(agentProvider.notifier).setWeapon(
              agent.id,
              agent.weapon == WeaponType.vandal
                  ? WeaponType.phantom
                  : WeaponType.vandal,
            );
      }, names: '-p0-agent weapon'),
      OutcomeCase('weapon of lineUp', (c) {
        final origin = _first(c.read(lineUpProvider).graph.origins);
        c.read(lineUpProvider.notifier).setOriginWeapon(
              origin.id,
              origin.agent.weapon == WeaponType.operator
                  ? WeaponType.marshal
                  : WeaponType.operator,
            );
      }, names: '-p0-origin-1 agent'),
      OutcomeCase('lineups addition', (c) {
        final graph = c.read(lineUpProvider).graph;
        c
            .read(lineUpProvider.notifier)
            .addCopies(_copyOf(graph, graph.links.last.id, '-copy'));
      }, names: '-p0-link-d-copy '),
      OutcomeCase('lineups deletion', (c) {
        c
            .read(lineUpProvider.notifier)
            .deleteLink(c.read(lineUpProvider).graph.links.last.id);
      }, names: '-p0-link-d '),
      OutcomeCase('lineup originPosition', (c) {
        final origin = _first(c.read(lineUpProvider).graph.origins);
        c.read(lineUpProvider.notifier).updateOriginAgentPosition(
            origin.id, origin.agent.position + const Offset(12, 8));
      }, names: '-p0-origin-1 agent'),
      OutcomeCase('lineup landingPosition', (c) {
        final landing = _first(c.read(lineUpProvider).graph.landings);
        c.read(lineUpProvider.notifier).updateLandingPosition(
            landing.id, landing.ability.position + const Offset(-6, 9));
      }, names: '-p0-landing-1 ability'),
      OutcomeCase('lineup landingVisibility', (c) {
        final landing = _first(c.read(lineUpProvider).graph.landings);
        final state = landing.ability.visualState;
        c.read(lineUpProvider.notifier).updateLandingAbilityVisualState(
              landingId: landing.id,
              visualState: state.copyWith(showRangeFill: !state.showRangeFill),
            );
      }, names: '-p0-landing-1 ability'),
      OutcomeCase('lineup linkDetails', (c) {
        final link = _first(c.read(lineUpProvider).graph.links);
        c
            .read(lineUpProvider.notifier)
            .updateLink(link.copyWith(notes: 'Jump throw from box'));
      }, names: '-p0-link-a notes'),
      OutcomeCase('transaction: strategy settings', (c) {
        final settings = c.read(strategySettingsProvider.notifier);
        final size = c.read(strategySettingsProvider).agentSize;
        c.read(actionProvider.notifier).performTransaction(
          groups: const [ActionGroup.strategySettings],
          mutation: () => settings.updateAgentSize(size + 4),
        );
      }, names: ' agentSize'),
      OutcomeCase('transaction: deletion agent, deletion text', (c) {
        final agent = _first(c.read(agentProvider)).id;
        final text = _first(c.read(textProvider)).id;
        c.read(actionProvider.notifier).performTransaction(
          groups: const [],
          mutation: () {
            c.read(agentProvider.notifier).removeAgentAsAction(agent);
            c.read(textProvider.notifier).removeTextAsAction(text);
          },
        );
      }, names: '-p0-text '),
    ];

Perform _raise<T>(
  List<String> Function(ProviderContainer c) ids,
  void Function(ProviderContainer c, String id) drag,
) =>
    (c) => drag(c, ids(c).first);

List<OutcomeCase> _editsWithoutUndoStepCases() => [
      OutcomeCase('tag colour text', (c) {
        c
            .read(textProvider.notifier)
            .updateTagColor(_first(c.read(textProvider)).id, 0xFF0EA5E9);
      }, names: '-p0-text tagColorValue'),
      OutcomeCase('tag colour image', (c) {
        c.read(placedImageProvider.notifier).updateTagColor(
            _first(c.read(placedImageProvider).images).id, 0xFF0EA5E9);
      }, names: '-p0-image tagColorValue'),
      OutcomeCase('resize text', (c) {
        final text = _first(c.read(textProvider));
        c.read(textProvider.notifier).resize(text.id,
            size: text.size + 40, position: text.position + const Offset(5, 5));
      }, names: '-p0-text size'),
      OutcomeCase('resize image', (c) {
        final image = _first(c.read(placedImageProvider).images);
        c.read(placedImageProvider.notifier).resize(image.id,
            scale: image.scale * 1.5,
            position: image.position + const Offset(5, 5));
      }, names: '-p0-image scale'),
      OutcomeCase('side of the page on screen', (c) async {
        await c.read(strategyProvider.notifier).switchSide(allPages: false);
      }, names: RegExp(r'^page \S+-p0 isAttack$')),
      OutcomeCase('neutral colours of the page on screen', (c) {
        c.read(strategySettingsProvider.notifier).updateNeutralTeamColors(
            !c.read(strategySettingsProvider).useNeutralTeamColors);
      }, names: '-p0 useNeutralTeamColors'),
      OutcomeCase('map', (c) {
        c.read(mapProvider.notifier).updateMap(MapValue.bind);
      }, names: RegExp(r'^strategy \S+ map$')),
      OutcomeCase('theme', (c) {
        c.read(strategyProvider.notifier).setThemeProfileForCurrentStrategy(
            MapThemeProfilesProvider.immutableValorantProfileId);
      }, names: RegExp(r'^strategy \S+ themeProfile$')),
      OutcomeCase('strategy name', (c) async {
        await c.read(strategyProvider.notifier).renameStrategy(
            c.read(strategyProvider).strategyId!, 'Renamed by the test');
      }, names: RegExp(r'^strategy \S+ name$')),
      OutcomeCase(
        'edit agent + raise agent',
        _raise((c) => [for (final a in c.read(agentProvider)) a.id], (c, id) {
          final agent = c.read(agentProvider).singleWhere((a) => a.id == id);
          c
              .read(agentProvider.notifier)
              .updatePosition(agent.position + const Offset(12, 7), id);
        }),
        names: RegExp(r'^agent list \S+ order$'),
        dropLabel: 'raise agent',
      ),
      OutcomeCase(
        'edit ability + raise ability',
        _raise((c) => [for (final a in c.read(abilityProvider)) a.id], (c, id) {
          final ability =
              c.read(abilityProvider).singleWhere((a) => a.id == id);
          c
              .read(abilityProvider.notifier)
              .updatePosition(ability.position + const Offset(12, 7), id);
        }),
        names: RegExp(r'^ability list \S+ order$'),
        dropLabel: 'raise ability',
      ),
      OutcomeCase(
        'edit utility + raise utility',
        _raise((c) => [for (final u in c.read(utilityProvider)) u.id], (c, id) {
          final utility =
              c.read(utilityProvider).singleWhere((u) => u.id == id);
          c
              .read(utilityProvider.notifier)
              .updatePosition(utility.position + const Offset(12, 7), id);
        }),
        names: RegExp(r'^utility list \S+ order$'),
        dropLabel: 'raise utility',
      ),
      OutcomeCase(
        'edit text + raise text',
        _raise((c) => [for (final t in c.read(textProvider)) t.id], (c, id) {
          final text = c.read(textProvider).singleWhere((t) => t.id == id);
          c
              .read(textProvider.notifier)
              .updatePosition(text.position + const Offset(12, 7), id);
        }),
        setup: (c) {
          final text = _first(c.read(textProvider));
          c.read(textProvider.notifier).addText(
              _renamed(ActionObjectState.text(text), 'second-text').text!);
        },
        names: RegExp(r'^text list \S+ order$'),
        dropLabel: 'raise text',
      ),
      OutcomeCase(
        'edit image + raise image',
        _raise(
            (c) => [for (final i in c.read(placedImageProvider).images) i.id],
            (c, id) {
          final image =
              c.read(placedImageProvider).images.singleWhere((i) => i.id == id);
          c
              .read(placedImageProvider.notifier)
              .updatePosition(image.position + const Offset(12, 7), id);
        }),
        setup: (c) {
          final image = _first(c.read(placedImageProvider).images);
          c.read(placedImageProvider.notifier).addImageCopy(
              _renamed(ActionObjectState.image(image), 'second-image').image!);
        },
        names: RegExp(r'^image list \S+ order$'),
        dropLabel: 'raise image',
      ),
    ];

final _clearAll = OutcomeCase(
  'bulkDeletion: deletion agent, deletion ability, deletion drawing, '
  'deletion text, deletion image, deletion utility, lineups deletion',
  (c) => c.read(actionProvider.notifier).clearAllAsAction(),
  names: '-p0-text ',
);

String _secondPage(ProviderContainer c) {
  final session = c.read(strategyPageSessionProvider);
  return session.availablePageIds
      .firstWhere((id) => id != session.activePageId);
}

List<OutcomeCase> _pageCases() => [
      OutcomeCase('page add', (c) async {
        await c.read(strategyProvider.notifier).addPage('Retake');
      },
          names: RegExp(r'^page \S+ (missing|extra)$'),
          asIs: {UnitOutcome.opsWrong}),
      OutcomeCase('page rename', (c) async {
        await c
            .read(strategyProvider.notifier)
            .renamePage(_secondPage(c), 'Retake');
      }, names: '-p1 name'),
      OutcomeCase('page delete', (c) async {
        await c.read(strategyProvider.notifier).deletePage(_secondPage(c));
      }, names: '-p1 '),
      OutcomeCase('page reorder', (c) async {
        await c.read(strategyProvider.notifier).reorderPage(0, 2);
      }, names: RegExp(r'^pages \S+ order$')),
      OutcomeCase('side of the page on screen + side on all pages', (c) async {
        await c.read(strategyProvider.notifier).switchSide(allPages: true);
      }, names: '-p2 isAttack', dropLabel: 'side on all pages'),
      OutcomeCase('settings on all pages', (c) async {
        final value = !c.read(strategySettingsProvider).useNeutralTeamColors;
        c
            .read(strategySettingsProvider.notifier)
            .updateNeutralTeamColors(value);
        await c
            .read(strategyProvider.notifier)
            .applyNeutralTeamColorsToAllPages(value);
      }, turnsWithNoAction: 2, names: '-p2 useNeutralTeamColors'),
      OutcomeCase(
        'copy item to page',
        (c) async {
          await c
              .read(strategyProvider.notifier)
              .copyPlacedWidgetToAdjacentPage(
                widgetId: _first(c.read(agentProvider)).id,
                direction: PageTransitionDirection.forward,
              );
        },
        names: '-p0-agent ',
        asIs: const {},
        notJudgedAsIs: 'a commit was refused',
      ),
      OutcomeCase('copy lineups to page', (c) async {
        await c.read(strategyProvider.notifier).copyLineUpsToAdjacentPage(
          linkIds: {_first(c.read(lineUpProvider).graph.links).id},
          direction: PageTransitionDirection.forward,
        );
      }, names: '-p0-link-a~cp1~'),
    ];

Set<String> everyActionKind() => {
      for (final group in ActionGroup.values)
        if (!{
          ActionGroup.bulk,
          ActionGroup.strategySettings,
          ActionGroup.lineUp,
        }.contains(group))
          for (final type in [
            ActionType.addition,
            ActionType.deletion,
            ActionType.edit,
          ])
            '${type.name} ${group.name}',
      'weapon of agent',
      'weapon of lineUp',
      'lineups addition',
      'lineups deletion',
      for (final field in LineUpEditField.values) 'lineup ${field.name}',
      'transaction: strategy settings',
      'bulkDeletion',
      'page add',
      'page rename',
      'page delete',
      'page reorder',
      'side on all pages',
      'settings on all pages',
      'copy item to page',
      'copy lineups to page',
      ...editsWithoutUndoStep,
    };

const editsWithoutUndoStep = [
  'tag colour text',
  'tag colour image',
  'resize text',
  'resize image',
  'side of the page on screen',
  'neutral colours of the page on screen',
  'map',
  'theme',
  'strategy name',
  'raise agent',
  'raise ability',
  'raise text',
  'raise image',
  'raise utility',
];

final class _Observed {
  _Observed(this.tally, this.kind)
      : ok = tally.byKind[kind]?.noFinding ?? 0,
        changed = tally.byKind[kind]?.changedWithoutAction ?? 0,
        stale = tally.byKind[kind]?.beforeNotOnCanvas ?? 0,
        wrong = tally.byKind[kind]?.opsWrong ?? 0,
        verdicts = switch (tally.byKind[kind]) {
          final k? => k.judged +
              k.notJudged.values.fold<int>(0, (a, b) => a + b) +
              k.discarded.values.fold<int>(0, (a, b) => a + b),
          null => 0,
        },
        findings = tally.findings.length;

  final ActionOpsTally tally;
  final String kind;
  final int ok;
  final int changed;
  final int stale;
  final int wrong;
  final int verdicts;
  final int findings;

  Set<UnitOutcome> since(_Observed before) => {
        if (ok > before.ok) UnitOutcome.noFinding,
        if (changed > before.changed) UnitOutcome.changedWithoutAction,
        if (stale > before.stale) UnitOutcome.beforeNotOnCanvas,
        if (wrong > before.wrong) UnitOutcome.opsWrong,
      };

  List<UnitFinding> newFindings(_Observed before) =>
      tally.findings.sublist(before.findings);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  setUpAll(() {
    container = ProviderContainer();
    appProviderContainer = container;
  });
  setUp(() async => openUnitHive());
  tearDown(() async => Hive.close());

  var opened = 0;
  StrategyData strategy() {
    opened += 1;
    final id = 'units-$opened';
    return generatedStrategy(Optionals.unset).copyWith(
      id: id,
      pages: [
        for (var n = 0; n < 3; n++)
          generatedPage(
            id: '$id-p$n',
            sortIndex: n,
            optionals: n.isEven ? Optionals.set : Optionals.unset,
            isAttack: true,
            lineups: sharedSpotLineups('$id-p$n'),
          ).copyWith(),
      ],
    );
  }

  Future<String> run(
    OutcomeCase c, {
    required String scenario,
    required String kind,
    required Set<UnitOutcome> expected,
    String? notJudged,
    List<Perform> before = const [],
    required bool dropOps,
    required bool silently,
  }) async {
    final h = await openInEditor(container, strategy());
    try {
      for (final step in [if (c.setup case final setup?) setup, ...before]) {
        await step(container);
        await h.settle();
      }
      final measured = silently ? 'no action' : kind;
      final start = _Observed(h.tally, measured);
      if (dropOps) {
        final dropped = c.dropLabel ?? kind;
        h.journal.alterOps = (label, ops) => label == dropped ? const [] : ops;
      }
      if (silently) {
        await h.silently(() => c.perform(container));
      } else {
        await c.perform(container);
        await h.settle();
      }
      final end = _Observed(h.tally, measured);
      final outcomes = end.since(start);
      final findings = [
        for (final f in end.newFindings(start))
          if (f.kind == measured) f,
      ];
      final reasons = h.tally.byKind[measured]?.notJudged ?? const {};
      final problems = <String>[
        if (!h.journal.addsUp) 'units do not add up',
        if (notJudged != null && (reasons[notJudged] ?? 0) == 0)
          'not judged for "$notJudged" was expected; reasons $reasons',
        if (end.verdicts - start.verdicts !=
            (silently ? c.turnsWithNoAction : 1))
          '${end.verdicts - start.verdicts} units of kind "$measured" given '
              'a disposition, expected exactly one (kinds ${h.tally.byKind.keys.toList()})',
        if (!outcomes.containsAll(expected) ||
            outcomes.difference(expected).isNotEmpty)
          'outcomes $outcomes, expected $expected; findings '
              '${[
            for (final f in findings) '${f.uncovered} | ${f.wrong} | ${f.gaps}'
          ]}',
        if (dropOps &&
            !findings.any((f) => f.wrong.any((line) => line.contains(c.names))))
          'ops wrong does not name "${c.names}": '
              '${[for (final f in findings) ...f.wrong]}',
        if (silently &&
            !findings
                .any((f) => f.uncovered.any((line) => line.contains(c.names))))
          'changed without an action does not name "${c.names}": '
              '${[for (final f in findings) ...f.uncovered]}',
      ];
      return problems.isEmpty ? '' : '$kind, $scenario: ${problems.join('; ')}';
    } finally {
      await h.dispose();
    }
  }

  Future<List<String>> threeCases(
    OutcomeCase c, {
    String? kind,
    List<Perform> before = const [],
    Set<UnitOutcome>? asIs,
  }) async {
    final label = kind ?? c.kind;
    return [
      await run(c,
          scenario: 'as it is',
          kind: label,
          expected: asIs ?? c.asIs,
          notJudged: c.notJudgedAsIs,
          before: before,
          dropOps: false,
          silently: false),
      await run(c,
          scenario: 'its ops dropped',
          kind: label,
          expected: {
            ...(asIs ?? c.asIs).difference(_covered),
            UnitOutcome.opsWrong,
          },
          before: before,
          dropOps: true,
          silently: false),
      await run(c,
          scenario: 'the same change with no action',
          kind: label,
          expected: {UnitOutcome.changedWithoutAction},
          before: before,
          dropOps: false,
          silently: true),
    ];
  }

  final cases = [
    ..._objectCases(),
    _clearAll,
    ..._pageCases(),
    ..._editsWithoutUndoStepCases(),
  ];

  test('every action kind has its three cases', () {
    expect(
      everyActionKind().where((kind) => !cases.any((c) =>
          c.kind == kind ||
          c.kind.startsWith('$kind: ') ||
          c.kind.split(' + ').contains(kind))),
      isEmpty,
    );
  });

  for (final c in cases) {
    test(
        '"${c.kind}": as it is, its ops dropped, and the same change made '
        'with no action each read as the table says', () async {
      final problems = await threeCases(c);
      expect(problems.where((p) => p.isNotEmpty), isEmpty);
    });
  }

  for (final c in _objectCases()) {
    test(
        '"undo ${c.kind}" and "redo ${c.kind}": as they are, their ops '
        'dropped, and the same change made with no action', () async {
      final undo = OutcomeCase(
          'undo ${c.kind}', (c) => c.read(actionProvider.notifier).undoAction(),
          names: c.names);
      final redo = OutcomeCase(
          'redo ${c.kind}', (c) => c.read(actionProvider.notifier).redoAction(),
          names: c.names);
      final problems = [
        ...await threeCases(undo, before: [c.perform]),
        ...await threeCases(redo, before: [
          c.perform,
          (c) => c.read(actionProvider.notifier).undoAction(),
        ]),
      ];
      expect(problems.where((p) => p.isNotEmpty), isEmpty);
    });
  }
}
