import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/action_ops.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/ops_verdict.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart' hide UserAction;

import '../library_rows/generated_strategies.dart';
import 'object_variants.dart';

const _pageId = 'p';

StrategyPage _basePage() => generatedPage(
      id: _pageId,
      sortIndex: 0,
      optionals: Optionals.set,
      isAttack: true,
      lineups: sharedSpotLineups('pl'),
    ).copyWith();

StrategyData _strategyWith(StrategyPage page) =>
    generatedStrategy(Optionals.unset).copyWith(id: 'converted', pages: [page]);

StrategyPage _withObjects(StrategyPage page, List<ActionObjectState> objects) =>
    page.copyWith(
      agentData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.agent) o.agent!,
      ],
      abilityData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.ability) o.ability!,
      ],
      drawingData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.drawing) o.drawing!,
      ],
      textData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.text) o.text!,
      ],
      imageData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.image) o.image!,
      ],
      utilityData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.utility) o.utility!,
      ],
    );

ActionGroup _groupOf(ActionObjectKind kind) => switch (kind) {
      ActionObjectKind.agent => ActionGroup.agent,
      ActionObjectKind.ability => ActionGroup.ability,
      ActionObjectKind.drawing => ActionGroup.drawing,
      ActionObjectKind.text => ActionGroup.text,
      ActionObjectKind.image => ActionGroup.image,
      ActionObjectKind.utility => ActionGroup.utility,
      ActionObjectKind.lineUp => ActionGroup.lineUp,
    };

UserAction _objectAction(
  ActionType type,
  ActionObjectKind kind,
  String id, {
  ActionObjectState? before,
  ActionObjectState? after,
}) =>
    UserAction(
      type: type,
      id: id,
      group: _groupOf(kind),
      objectDelta: ObjectHistoryDelta(before: before, after: after),
    );

final class _Case {
  _Case(
    this.what, {
    required this.before,
    required this.after,
    required this.action,
    this.reversed = false,
  });

  final String what;
  final StrategyPage before;
  final StrategyPage after;
  final UserAction action;
  final bool reversed;
}

StrategyData _readable(StrategyData strategy) =>
    switch (strategyToRows(strategyAsHiveHoldsIt(strategy))) {
      StrategyRowsMade(:final rows) => switch (strategyFromRows(rows)) {
          StrategyDataMade(:final strategy) => strategy,
          StrategyDataRefused(:final problems) => fail('$problems'),
        },
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

Future<List<String>> _run(_Case c) async {
  final store = switch (await LibraryStore.open(
    MemoryEngine(MemoryStorage()),
    canRead: appCanRead,
  )) {
    StoreOpened(:final store) => store,
    StoreNotOpened(:final problem) => fail('$problem'),
  };
  final rows = switch (strategyToRows(strategyAsHiveHoldsIt(
    _strategyWith(c.before),
  ))) {
    StrategyRowsMade(:final rows) => rows,
    StrategyRowsRefused(:final problems) => fail('$problems'),
  };
  expect(await store.putStrategy(rows), isA<Saved<LibraryEdited, Object>>());
  final changes = canvasChangesOf(
    c.action,
    pageId: _pageId,
    reversed: c.reversed,
    now: EditorNow(
      agent: (id) => c.after.agentData.where((a) => a.id == id).firstOrNull,
    ),
  );
  expect(changes, isNotEmpty, reason: c.what);
  final built =
      await (await OpsBuilder.read(store, 'converted'))!.build(changes);
  expect(built.gaps, isEmpty, reason: c.what);
  expect(built.ops, isNotEmpty, reason: c.what);
  expect(
    await store.commitAll('converted', built.ops),
    isA<Saved<List<Committed>, CommitRefusal>>(),
    reason: c.what,
  );
  final read = switch (await readStoredRows(store, 'converted')) {
    StoredRowsRead(:final rows) => switch (strategyFromRows(rows)) {
        StrategyDataMade(:final strategy) => strategy,
        StrategyDataRefused(:final problems) => fail('$problems'),
      },
    StoredRowsNot(:final stored) => fail('$stored'),
  };
  await store.close();
  return [
    for (final d in readBackDifferences(
      _readable(_strategyWith(c.after)),
      read,
    ))
      '$d',
  ];
}

List<_Case> _objectCases(Random random) {
  final base = _basePage();
  final objects = objectsOf(base);
  final cases = <_Case>[];
  for (final kind in ActionObjectKind.values) {
    if (kind == ActionObjectKind.lineUp) continue;
    final object = objects.firstWhere((o) => o.kind == kind);
    final rest = [
      for (final o in objects)
        if (o.id != object.id) o,
    ];
    final variant = variedObject(object, random)!;
    final added = ActionObjectState.fromJson(
      kind,
      {...variant.object.toJson(), 'id': 'added-${kind.name}'},
    );
    final withAdded = _withObjects(base, [...objects, added]);
    final addedNow = objectsOf(withAdded).singleWhere((o) => o.id == added.id);
    final edited = _withObjects(base, [
      for (final o in objects) o.id == object.id ? variant.object : o,
    ]);
    final editedNow = objectsOf(edited).singleWhere((o) => o.id == object.id);
    final without = _withObjects(base, rest);
    final addition =
        _objectAction(ActionType.addition, kind, added.id, after: addedNow);
    final deletion =
        _objectAction(ActionType.deletion, kind, object.id, before: object);
    final edit = _objectAction(ActionType.edit, kind, object.id,
        before: object, after: editedNow);
    cases.addAll([
      _Case('add ${kind.name}',
          before: base, after: withAdded, action: addition),
      _Case('undo add ${kind.name}',
          before: withAdded, after: base, action: addition, reversed: true),
      _Case('delete ${kind.name}',
          before: base, after: without, action: deletion),
      _Case('undo delete ${kind.name}',
          before: without,
          after: _withObjects(base, [...rest, object]),
          action: deletion,
          reversed: true),
      _Case('edit ${kind.name} (${variant.fields.join(', ')})',
          before: base, after: edited, action: edit),
      _Case('undo edit ${kind.name}',
          before: edited, after: base, action: edit, reversed: true),
    ]);
  }
  return cases;
}

StrategyPage _withGraph(StrategyPage page, LineUpGraph graph) =>
    page.copyWith(lineUpGraph: graph);

List<_Case> _otherCases() {
  final base = _basePage();
  final graph = base.lineUpGraph;
  final agent = base.agentData.first;
  final armed = base.copyWith(agentData: [
    for (final a in base.agentData)
      a.id == agent.id
          ? (ActionObjectState.agent(a).agent!..weapon = WeaponType.vandal)
          : a,
  ]);
  final origin = graph.origins.first;
  final landing = graph.landings.first;
  final link = graph.links.first;
  final originArmed = _withGraph(
    base,
    lineupsWithWeapon(graph, origin.id, WeaponType.operator),
  );
  final change = LineUpLinkChange.between(
    link,
    link.copyWith(name: 'Retake smoke', notes: 'From heaven'),
  );
  final visibility = AbilityVisibilityChange.between(
    landing.ability.visualState,
    landing.ability.visualState.copyWith(
      showRangeFill: !landing.ability.visualState.showRangeFill,
      showVisionCone: !landing.ability.visualState.showVisionCone,
    ),
  );
  LineUpEditAction edit(
          LineUpEditField field, String target, Object before, Object after) =>
      LineUpEditAction(
        id: 'edit-${field.name}',
        targetId: target,
        field: field,
        before: before,
        after: after,
      );
  final originMoved = edit(LineUpEditField.originPosition, origin.id,
      origin.agent.position, const Offset(123, 456));
  final landingMoved = edit(LineUpEditField.landingPosition, landing.id,
      landing.ability.position, const Offset(654, 321));
  final linkDetails = edit(
      LineUpEditField.linkDetails, link.id, change.backward, change.forward);
  final landingVisibility = edit(LineUpEditField.landingVisibility, landing.id,
      visibility.backward, visibility.forward);
  LineUpGraph applied(LineUpEditAction a) =>
      lineupsWithField(graph, a.field, a.targetId, a.after);
  final settings = StrategySettings(
    agentSize: base.settings.agentSize + 7,
    abilitySize: base.settings.abilitySize + 3,
    useNeutralTeamColors: !base.settings.useNeutralTeamColors,
  );
  final utility = base.utilityData.first;
  final variant = variedObject(ActionObjectState.agent(agent), Random(7))!;
  final agentEdited = _withObjects(
      base,
      [
        for (final o in objectsOf(base))
          if (o.id == utility.id)
            null
          else if (o.id == agent.id)
            variant.object
          else
            o,
      ].whereType<ActionObjectState>().toList());
  final agentNow = objectsOf(agentEdited).singleWhere((o) => o.id == agent.id);
  final transaction = UserAction(
    type: ActionType.transaction,
    id: 'move',
    group: ActionGroup.bulk,
    changes: [
      _objectAction(ActionType.edit, ActionObjectKind.agent, agent.id,
          before: ActionObjectState.agent(agent), after: agentNow),
      _objectAction(ActionType.deletion, ActionObjectKind.utility, utility.id,
          before: ActionObjectState.utility(utility)),
      originMoved,
      linkDetails,
    ],
  );
  final afterTransaction = _withGraph(
    agentEdited,
    lineupsWithField(
      lineupsWithField(graph, originMoved.field, origin.id, originMoved.after),
      linkDetails.field,
      link.id,
      linkDetails.after,
    ),
  );
  final text = base.textData.first;
  final bulk = UserAction(
    type: ActionType.bulkDeletion,
    id: 'clear',
    group: ActionGroup.bulk,
    changes: [
      _objectAction(ActionType.deletion, ActionObjectKind.agent, agent.id,
          before: ActionObjectState.agent(agent)),
      _objectAction(ActionType.deletion, ActionObjectKind.text, text.id,
          before: ActionObjectState.text(text)),
    ],
  );
  final cleared = _withObjects(base, [
    for (final o in objectsOf(base))
      if (o.id != agent.id && o.id != text.id) o,
  ]);
  return [
    _Case('agent weapon',
        before: base,
        after: armed,
        action: WeaponSelectionAction(
          id: agent.id,
          group: ActionGroup.agent,
          before: agent.weapon,
          after: WeaponType.vandal,
        )),
    _Case('undo agent weapon',
        before: armed,
        after: base,
        action: WeaponSelectionAction(
          id: agent.id,
          group: ActionGroup.agent,
          before: agent.weapon,
          after: WeaponType.vandal,
        ),
        reversed: true),
    _Case('lineup weapon',
        before: base,
        after: originArmed,
        action: WeaponSelectionAction(
          id: origin.id,
          group: ActionGroup.lineUp,
          before: origin.agent.weapon,
          after: WeaponType.operator,
        )),
    for (final a in [originMoved, landingMoved, linkDetails, landingVisibility])
      _Case('lineup ${a.field.name}',
          before: base, after: _withGraph(base, applied(a)), action: a),
    _Case('undo lineup ${linkDetails.field.name}',
        before: _withGraph(base, applied(linkDetails)),
        after: base,
        action: linkDetails,
        reversed: true),
    _Case('strategy settings',
        before: base,
        after: base.copyWith(settings: settings),
        action: StrategySettingsAction(
          id: 'settings',
          before: base.settings,
          after: settings,
        )),
    _Case('undo strategy settings',
        before: base.copyWith(settings: settings),
        after: base,
        action: StrategySettingsAction(
          id: 'settings',
          before: base.settings,
          after: settings,
        ),
        reversed: true),
    _Case('transaction of an agent edit, a delete and two lineup edits',
        before: base, after: afterTransaction, action: transaction),
    _Case('undo that transaction',
        before: afterTransaction,
        after: _withObjects(
          _withGraph(base, graph),
          [
            for (final o in objectsOf(base))
              if (o.id != utility.id) o,
            ActionObjectState.utility(utility),
          ],
        ),
        action: transaction,
        reversed: true),
    _Case('clear of two items', before: base, after: cleared, action: bulk),
  ];
}

void main() {
  test(
      'every kind of editor action, done and undone, converts to ops that leave the store equal to the page the action made',
      () async {
    final cases = [..._objectCases(Random(3)), ..._otherCases()];
    final failures = <String>[];
    for (final c in cases) {
      final differences = await _run(c);
      if (differences.isNotEmpty) failures.add('${c.what}: $differences');
    }
    expect(failures, isEmpty);
    expect(cases.length, greaterThan(45));
  });
}
