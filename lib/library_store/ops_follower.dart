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
import 'package:icarus/strategy/strategy_page_models.dart';

String actionLabel(UserAction action, ActionWay way) {
  final kind = switch (action) {
    LineUpGraphAction(:final type) => 'lineups ${type.name}',
    LineUpEditAction(:final field) => 'lineup ${field.name}',
    WeaponSelectionAction(:final group) => 'weapon of ${group.name}',
    StrategySettingsAction() => 'strategy settings',
    _ when action.group == ActionGroup.bulk => '${action.type.name}: ${{
        for (final change in action.changes)
          actionLabel(change, ActionWay.done),
      }.join(', ')}',
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

final class OpsFollower implements EditFollower, UnitSource {
  OpsFollower(this._mirror, this._container) {
    _mirror.actions?.source = this;
  }

  final StoreMirror _mirror;
  final ProviderContainer Function() _container;
  final _subscriptions = <ProviderSubscription<Object?>>[];
  final _pointers = <int>{};
  _OpenUnit? _unit;
  var _scheduled = false;
  var _faulted = false;
  String? _takenUp;
  String? _appliedPage;
  var _loadPending = false;
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
      watch(textDraftProvider);
      _subscriptions.add(container.listen<StrategyPageSessionState>(
        strategyPageSessionProvider,
        (previous, next) => _guarded('page session', () {
          if ((previous?.isApplyingPage ?? false) && !next.isApplyingPage) {
            _appliedPage = next.activePageId;
            _loadPending = true;
          }
          _noteChange();
        }),
      ));
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
      _open().actions.add(DeclaredAction(
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
      _open()
        ..pageLevel = true
        ..actions.add(DeclaredAction(label, changes()));
      _schedule();
    });
  }

  _OpenUnit _open() {
    final open = _unit;
    if (open != null) return open;
    _mirror.unitOpened();
    return _unit = _OpenUnit();
  }

  @override
  bool get holdsAUnit => _unit != null;

  @override
  void closeOut() {
    final unit = _unit;
    if (unit == null) return;
    _unit = null;
    _mirror.closedWithoutJudging(
      unit.actions,
      notJudged: 'a unit still open at the end',
      discarded: 'actions in a unit still open at the end',
    );
  }

  void _noteChange() {
    if (_unit == null && _takenUp == null && _localStrategy() == null) return;
    _open();
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
    final id = _localStrategy();
    final pageId = session.activePageId;
    if (_takenUp case final taken? when taken != id) {
      final unit = _unit!;
      _unit = null;
      _release(taken);
      _mirror.closedWithoutJudging(
        unit.actions,
        notJudged: 'the strategy closing',
        discarded: 'actions as the strategy changed',
      );
      if (id == null) return;
      _open();
    }
    if (id == null || pageId == null) {
      final unit = _unit!;
      _unit = null;
      _mirror.closedWithoutJudging(
        unit.actions,
        notJudged:
            id == null ? 'no local strategy open' : 'no page on screen yet',
        discarded: id == null
            ? 'actions with no local strategy open'
            : 'actions before a page was on screen',
      );
      return;
    }
    if (pageId != _appliedPage) return;
    final unit = _unit!;
    _unit = null;
    if (_takenUp == null) {
      _loadPending = false;
      _takeUp(id, pageId, unit.actions);
      return;
    }
    if (_loadPending) {
      _loadPending = false;
      final clock = Stopwatch()..start();
      final snapshot = _capture(id, pageId, everyPage: true);
      _mirror.unit(
        id,
        kind: UnitKind.load,
        declared: unit.actions,
        snapshot: snapshot,
        pages: const {},
        snapshotTime: clock.elapsed,
        notJudged:
            snapshot == null ? 'the library holds no such strategy' : null,
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

  void _takeUp(String id, String pageId, List<DeclaredAction> declared) {
    final hive = const LocalLibrary().storedStrategy(id);
    _seen.clear();
    _last = null;
    final canvas = hive == null ? null : _capture(id, pageId, everyPage: true);
    if (hive == null || canvas == null) {
      _mirror.closedWithoutJudging(
        declared,
        notJudged: 'the library holds no such strategy',
        discarded: 'actions on a strategy the library does not hold',
      );
      return;
    }
    _faulted = false;
    ActionProvider.editFollower ??= this;
    _takenUp = id;
    _mirror.takeUp(id, cloneStrategy(hive), canvas, declared);
  }

  void _release(String id) {
    final hive = const LocalLibrary().storedStrategy(id);
    _mirror.release(id, hive == null ? null : cloneStrategy(hive));
    _takenUp = null;
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
