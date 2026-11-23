import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/canvas_units.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

String actionLabel(UserAction action, ActionWay way) {
  final kind = switch (action) {
    LineUpGraphAction(:final type) => 'lineups ${type.name}',
    LineUpEditAction(:final field) => 'lineup ${field.name}',
    WeaponSelectionAction(:final group) => 'weapon of ${group.name}',
    StrategySettingsAction() => 'strategy settings',
    _ when action.group == ActionGroup.bulk => action.type.name,
    _ => '${action.type.name} ${action.group.name}',
  };
  return switch (way) {
    ActionWay.done => kind,
    ActionWay.undone => 'undo $kind',
    ActionWay.redone => 'redo $kind',
  };
}

final class _OpenUnit {
  final actions = <DeclaredAction>[];
  var pageLevel = false;
}

final class OpsFollower implements EditFollower {
  OpsFollower(this._mirror, this._container);

  final StoreMirror _mirror;
  final ProviderContainer Function() _container;
  final _subscriptions = <ProviderSubscription<Object?>>[];
  final _pointers = <int>{};
  _OpenUnit? _unit;
  var _scheduled = false;
  var _faulted = false;
  String? _takenUp;
  String? _pageOnScreen;
  StrategyData? _last;
  final _seen = <String, StrategyPage>{};

  @override
  void attach() {
    _guarded('attach', () {
      final container = _container();
      void watch<T>(ProviderListenable<T> provider) {
        _subscriptions.add(container.listen<T>(
          provider,
          (_, __) => _guarded('canvas change', _noteChange),
        ));
      }

      watch(agentProvider);
      watch(abilityProvider);
      watch(drawingProvider);
      watch(textProvider);
      watch(placedImageProvider);
      watch(utilityProvider);
      watch(lineUpProvider);
      watch(strategySettingsProvider);
      watch(mapProvider);
      watch(strategyThemeProvider);
      watch(strategyProvider);
      watch(strategyPageSessionProvider);
      watch(textDraftProvider);
      _mirror.actions?.onHiveWrite =
          (_) => _guarded('library write', _noteChange);
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    });
  }

  void detach() {
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    _subscriptions.clear();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
  }

  void _onPointer(PointerEvent event) {
    _guarded('pointer', () {
      switch (event) {
        case PointerDownEvent():
          _pointers.add(event.pointer);
        case PointerUpEvent() || PointerCancelEvent():
          if (_pointers.remove(event.pointer) && _pointers.isEmpty) {
            _schedule();
          }
        default:
          break;
      }
    });
  }

  String? _localStrategy() {
    final strategy = _container().read(strategyProvider);
    final id = strategy.strategyId;
    if (id == null ||
        !strategy.isOpen ||
        strategy.source != StrategySource.local) {
      return null;
    }
    return id;
  }

  EditorNow _now() {
    final agents = _container().read(agentProvider);
    return EditorNow(
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
    _guarded('${action.type.name} ${action.group.name}', () {
      final kept = action.copy();
      final pageId =
          _container().read(strategyPageSessionProvider).activePageId;
      if (_localStrategy() == null || pageId == null) return;
      (_unit ??= _OpenUnit()).actions.add(DeclaredAction(
            actionLabel(kept, way),
            canvasChangesOf(
              kept,
              pageId: pageId,
              reversed: way == ActionWay.undone,
              now: _now(),
            ),
          ));
      _schedule();
    });
  }

  @override
  void onPagesChanged(List<CanvasChange> Function() changes, String label) {
    _guarded(label, () {
      if (_localStrategy() == null) return;
      (_unit ??= _OpenUnit())
        ..pageLevel = true
        ..actions.add(DeclaredAction(label, changes()));
      _schedule();
    });
  }

  void _noteChange() {
    _unit ??= _OpenUnit();
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() => _guarded('unit', _closeIfDone));
  }

  bool get _held =>
      _pointers.isNotEmpty || _container().read(textDraftProvider).isNotEmpty;

  void _closeIfDone() {
    _scheduled = false;
    if (_unit == null || _held) return;
    final session = _container().read(strategyPageSessionProvider);
    if (session.isApplyingPage) return;
    final unit = _unit!;
    _unit = null;
    final id = _localStrategy();
    final pageId = session.activePageId;
    if (_takenUp != null && _takenUp != id) {
      _release(_takenUp!);
    }
    if (id == null || pageId == null) return;
    if (_takenUp == null) {
      _takeUp(id, pageId);
      return;
    }
    if (pageId != _pageOnScreen) {
      _pageOnScreen = pageId;
      final clock = Stopwatch()..start();
      final snapshot = _capture(id, pageId, everyPage: true);
      _mirror.unit(
        id,
        kind: UnitKind.load,
        declared: unit.actions,
        snapshot: snapshot,
        pages: const {},
        snapshotTime: clock.elapsed,
      );
      return;
    }
    if (_faulted) {
      _mirror.unit(
        id,
        kind: unit.actions.isEmpty ? UnitKind.silent : UnitKind.user,
        declared: unit.actions,
        snapshot: null,
        pages: const {},
        notJudged: 'a follower fault',
      );
      return;
    }
    final clock = Stopwatch()..start();
    final snapshot = _capture(id, pageId, everyPage: unit.pageLevel);
    final elapsed = clock.elapsed;
    final onScreen =
        snapshot?.pages.where((page) => page.id == pageId).firstOrNull;
    _mirror.unit(
      id,
      kind: unit.actions.isEmpty ? UnitKind.silent : UnitKind.user,
      declared: unit.actions,
      snapshot: snapshot,
      pages: {
        pageId,
        if (unit.pageLevel && snapshot != null)
          for (final page in snapshot.pages) page.id,
        ..._changedPages,
      },
      notJudged: snapshot == null ? 'the library holds no such strategy' : null,
      items: onScreen == null ? 0 : itemsOn(onScreen),
      snapshotTime: elapsed,
    );
  }

  var _changedPages = <String>{};

  void _takeUp(String id, String pageId) {
    final hive = const LocalLibrary().storedStrategy(id);
    if (hive == null) return;
    _seen.clear();
    _last = null;
    _faulted = false;
    ActionProvider.editFollower ??= this;
    final canvas = _capture(id, pageId, everyPage: true);
    if (canvas == null) return;
    _takenUp = id;
    _pageOnScreen = pageId;
    _mirror.takeUp(id, cloneStrategy(hive), canvas);
  }

  void _release(String id) {
    final hive = const LocalLibrary().storedStrategy(id);
    _mirror.release(id, hive == null ? null : cloneStrategy(hive));
    _takenUp = null;
    _pageOnScreen = null;
    _last = null;
    _seen.clear();
  }

  StrategyData? _capture(
    String id,
    String pageId, {
    required bool everyPage,
  }) {
    final hive = const LocalLibrary().storedStrategy(id);
    if (hive == null) return null;
    final container = _container();
    final carried = {
      for (final page in _last?.pages ?? const <StrategyPage>[]) page.id: page,
    };
    final changed = <String>{};
    final pages = <StrategyPage>[];
    for (final stored in hive.pages) {
      if (stored.id == pageId) {
        final lineups = container.read(lineUpProvider).graph;
        final map = container.read(mapProvider);
        pages.add(pageOf(
          id: stored.id,
          name: stored.name,
          isAutoNamed: stored.isAutoNamed,
          sortIndex: stored.sortIndex,
          isAttack: map.isAttack,
          settings: container.read(strategySettingsProvider),
          objects: [
            for (final agent in container.read(agentProvider))
              ActionObjectState.agent(agent),
            for (final ability in container.read(abilityProvider))
              ActionObjectState.ability(ability),
            for (final drawing in container.read(drawingProvider).elements)
              ActionObjectState.drawing(drawing),
            for (final text in container.read(textProvider))
              ActionObjectState.text(text),
            for (final image in container.read(placedImageProvider).images)
              ActionObjectState.image(image),
            for (final utility in container.read(utilityProvider))
              ActionObjectState.utility(utility),
          ],
          lineups: lineups,
        ));
        continue;
      }
      final kept = carried[stored.id];
      if (!everyPage && kept != null && identical(_seen[stored.id], stored)) {
        pages.add(kept);
        continue;
      }
      _seen[stored.id] = stored;
      if (kept != null) changed.add(stored.id);
      pages.add(clonePage(stored));
    }
    _changedPages = changed;
    final theme = container.read(strategyThemeProvider);
    final snapshot = hive.copyWith(
      name: container.read(strategyProvider).strategyName ?? hive.name,
      mapData: container.read(mapProvider).currentMap,
      themeProfileId: theme.profileId,
      clearThemeProfileId: theme.profileId == null,
      themeOverridePalette: theme.overridePalette,
      clearThemeOverridePalette: theme.overridePalette == null,
      pages: pages,
    );
    _last = snapshot;
    return snapshot;
  }

  bool isOpenInEditor(String strategyId) {
    try {
      return _localStrategy() == strategyId;
    } on Object {
      return false;
    }
  }

  void _guarded(String label, void Function() follow) {
    try {
      follow();
    } on Object catch (error) {
      _faulted = true;
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
