import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

String actionLabel(UserAction action, ActionWay way) {
  final kind = switch (action) {
    LineUpGraphAction(:final type) => 'lineups ${type.name}',
    LineUpEditAction(:final field) => 'lineup ${field.name}',
    WeaponSelectionAction(:final group) => 'weapon of ${group.name}',
    StrategySettingsAction() => 'strategy settings',
    _ when action.group == ActionGroup.bulk =>
      '${action.type.name} of ${action.changes.length}',
    _ => '${action.type.name} ${action.group.name}',
  };
  return switch (way) {
    ActionWay.done => kind,
    ActionWay.undone => 'undo $kind',
    ActionWay.redone => 'redo $kind',
  };
}

final class OpsFollower implements EditFollower {
  OpsFollower(this._mirror, this._container);

  final StoreMirror _mirror;
  final ProviderContainer Function() _container;

  String? _localStrategy() {
    final strategy = _container().read(strategyProvider);
    final id = strategy.strategyId;
    if (id == null || strategy.source != StrategySource.local) return null;
    return id;
  }

  EditorNow _now() {
    final container = _container();
    final agents = container.read(agentProvider);
    return EditorNow(
      lineups: container.read(lineUpProvider).graph,
      agent: (id) {
        for (final agent in agents) {
          if (agent.id == id) return agent;
        }
        return null;
      },
    );
  }

  static const _nothingRead =
      EditorNow(lineups: LineUpGraph.empty, agent: _none);

  static Null _none(String id) => null;

  @override
  void onAction(UserAction action, {required ActionWay way}) {
    final strategyId = _localStrategy();
    final pageId = _container().read(strategyPageSessionProvider).activePageId;
    if (strategyId == null || pageId == null) return;
    final kept = action.copy();
    final undone = way == ActionWay.undone;
    final changes = readsTheEditor(kept)
        ? Future.microtask(
            () => canvasChangesOf(
              kept,
              pageId: pageId,
              reversed: undone,
              now: _now(),
            ),
          )
        : Future.value(
            canvasChangesOf(
              kept,
              pageId: pageId,
              reversed: undone,
              now: _nothingRead,
            ),
          );
    _mirror.journal(strategyId, actionLabel(kept, way), changes);
  }

  @override
  void onPagesChanged(List<CanvasChange> Function() changes, String label) {
    final strategyId = _localStrategy();
    if (strategyId == null) return;
    _mirror.journal(strategyId, label, Future.value(changes()));
  }
}
