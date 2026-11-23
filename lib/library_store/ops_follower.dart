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
      lineups: () => container.read(lineUpProvider).graph.deepCopy(),
      agent: (id) {
        for (final agent in agents) {
          if (agent.id == id) return agent;
        }
        return null;
      },
    );
  }

  @override
  void onAction(UserAction action, {required ActionWay way}) {
    _following('${action.type.name} ${action.group.name}', () {
      final kept = action.copy();
      final strategyId = _localStrategy();
      final pageId =
          _container().read(strategyPageSessionProvider).activePageId;
      if (strategyId == null || pageId == null) return;
      _mirror.journal(
        strategyId,
        actionLabel(kept, way),
        canvasChangesOf(
          kept,
          pageId: pageId,
          reversed: way == ActionWay.undone,
          now: _now(),
        ),
      );
    });
  }

  @override
  void onPagesChanged(List<CanvasChange> Function() changes, String label) {
    _following(label, () {
      final strategyId = _localStrategy();
      if (strategyId == null) return;
      _mirror.journal(strategyId, label, changes());
    });
  }

  bool isOpenInEditor(String strategyId) {
    try {
      return _localStrategy() == strategyId;
    } on Object {
      return false;
    }
  }

  void _following(String label, void Function() follow) {
    try {
      follow();
    } on Object catch (error) {
      if (identical(ActionProvider.editFollower, this)) {
        ActionProvider.editFollower = null;
      }
      try {
        _mirror.followerFaulted(label, _described(error));
      } on Object {
        return;
      }
    }
  }

  static String _described(Object error) {
    try {
      return '$error';
    } on Object {
      return 'a ${error.runtimeType} that could not be described';
    }
  }
}
