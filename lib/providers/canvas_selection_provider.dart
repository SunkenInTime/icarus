import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

/// The kinds of thing the user can select on the canvas. A lineup is
/// selected as its link: the throw spot and landing come with it.
enum SelectableKind { agent, ability, text, image, utility, drawing, lineup }

/// One selected item on the page on screen.
typedef SelectedItem = ({SelectableKind kind, String id});

/// What the user has selected on the page on screen. Selection belongs to
/// this window only: it is never saved or synced, and it empties when the
/// page, the strategy, or the tool changes. Items that leave the page (an
/// undo, a teammate's delete) leave the selection with them.
final canvasSelectionProvider =
    NotifierProvider<CanvasSelectionNotifier, Set<SelectedItem>>(
  CanvasSelectionNotifier.new,
);

/// The ids of every item drawn as selected: the selected items, plus the
/// throw spots and landings of selected lineups, which are drawn as their
/// own items.
final selectedCanvasIdsProvider = Provider<Set<String>>((ref) {
  final selection = ref.watch(canvasSelectionProvider);
  if (selection.isEmpty) return const {};
  final lineupIds = {
    for (final item in selection)
      if (item.kind == SelectableKind.lineup) item.id,
  };
  final links = lineupIds.isEmpty
      ? const <LineUpLink>[]
      : ref.watch(lineUpProvider.select((state) => state.links));
  return {
    for (final item in selection) item.id,
    for (final link in links)
      if (lineupIds.contains(link.id)) ...[link.originId, link.landingId],
  };
});

/// The ids of the selected drawings.
final selectedDrawingIdsProvider = Provider<Set<String>>((ref) {
  return {
    for (final item in ref.watch(canvasSelectionProvider))
      if (item.kind == SelectableKind.drawing) item.id,
  };
});

/// A drag of the selection under way: the items it carries, as they were
/// when it began, and how far it has carried them, in canvas pixels.
typedef CanvasGroupDrag = ({Set<String> ids, Offset by});

/// The drag of the selection under way, or null. Its items are drawn this
/// far from where they are saved until the drag ends and moves them.
final canvasGroupDragProvider =
    NotifierProvider<CanvasGroupDragNotifier, CanvasGroupDrag?>(
  CanvasGroupDragNotifier.new,
);

class CanvasGroupDragNotifier extends Notifier<CanvasGroupDrag?> {
  @override
  CanvasGroupDrag? build() => null;

  void set(CanvasGroupDrag? drag) => state = drag;
}

/// Whether item [id] is one of several selected items that move together:
/// a drag on it drags them all, so its own drag stands aside.
final dragsWithSelectionProvider = Provider.family<bool, String>((ref, id) {
  final selection = ref.watch(canvasSelectionProvider);
  return selection.length > 1 &&
      selection.any((item) => item.id == id && movesWithSelection(item.kind));
});

/// Whether [kind] moves when the selection is dragged. A lineup marks the
/// spot its screenshots were taken from, so it stays where it is.
bool movesWithSelection(SelectableKind kind) => kind != SelectableKind.lineup;

class CanvasSelectionNotifier extends Notifier<Set<SelectedItem>> {
  @override
  Set<SelectedItem> build() {
    void clearOnChange<T>(ProviderListenable<T> provider) {
      ref.listen<T>(provider, (previous, next) {
        if (previous != next) clear();
      });
    }

    clearOnChange(strategyProvider.select((state) => state.strategyId));
    clearOnChange(
      strategyPageSessionProvider.select((state) => state.activePageId),
    );
    clearOnChange(interactionStateProvider);
    clearOnChange(
      currentStrategyCapabilitiesProvider.select(
        (capabilities) => capabilities.canEditPages,
      ),
    );

    void pruneOnChange<T>(ProviderListenable<T> provider) {
      ref.listen<T>(provider, (_, __) => _prune());
    }

    pruneOnChange(agentProvider);
    pruneOnChange(abilityProvider);
    pruneOnChange(textProvider);
    pruneOnChange(placedImageProvider.select((state) => state.images));
    pruneOnChange(utilityProvider);
    pruneOnChange(drawingProvider.select((state) => state.elements));
    pruneOnChange(lineUpProvider.select((state) => state.links));
    return const {};
  }

  /// Every item on the page on screen.
  Set<SelectedItem> _everything() => {
        for (final agent in ref.read(agentProvider))
          (kind: SelectableKind.agent, id: agent.id),
        for (final ability in ref.read(abilityProvider))
          (kind: SelectableKind.ability, id: ability.id),
        for (final text in ref.read(textProvider))
          (kind: SelectableKind.text, id: text.id),
        for (final image in ref.read(placedImageProvider).images)
          (kind: SelectableKind.image, id: image.id),
        for (final utility in ref.read(utilityProvider))
          (kind: SelectableKind.utility, id: utility.id),
        for (final drawing in ref.read(drawingProvider).elements)
          (kind: SelectableKind.drawing, id: drawing.id),
        for (final link in ref.read(lineUpProvider).links)
          (kind: SelectableKind.lineup, id: link.id),
      };

  void _prune() {
    if (state.isEmpty) return;
    final present = _everything();
    final kept = state.where(present.contains).toSet();
    if (kept.length != state.length) state = kept;
  }

  /// Replaces the selection with [items].
  void select(Iterable<SelectedItem> items) => state = {...items};

  /// Adds [items] to the selection.
  void add(Iterable<SelectedItem> items) => state = {...state, ...items};

  /// Selects [item] if it isn't, and unselects it if it is.
  void toggle(SelectedItem item) => state =
      state.contains(item) ? ({...state}..remove(item)) : {...state, item};

  void selectAll() => state = _everything();

  void clear() {
    if (state.isNotEmpty) state = const {};
  }

  /// Moves the items [ids] (a drag of the selection, as it was when the
  /// drag began) by [by], in world coordinates, as one undo step. Lineups
  /// never move this way (see [movesWithSelection]).
  void moveItems(Set<String> ids, Offset by) {
    if (ids.isEmpty ||
        by == Offset.zero ||
        !ref.read(currentStrategyCapabilitiesProvider).canEditPages) {
      return;
    }
    ref.read(actionProvider.notifier).performTransaction(
      groups: const [],
      mutation: () {
        // In each kind's own order: a move brings an item to the front, so
        // the moved items keep their order among themselves.
        for (final agent in [...ref.read(agentProvider)]) {
          if (!ids.contains(agent.id)) continue;
          ref
              .read(agentProvider.notifier)
              .updatePosition(agent.position + by, agent.id);
        }
        for (final ability in [...ref.read(abilityProvider)]) {
          if (!ids.contains(ability.id)) continue;
          ref
              .read(abilityProvider.notifier)
              .updatePosition(ability.position + by, ability.id);
        }
        for (final text in [...ref.read(textProvider)]) {
          if (!ids.contains(text.id)) continue;
          ref
              .read(textProvider.notifier)
              .updatePosition(text.position + by, text.id);
        }
        for (final image in [...ref.read(placedImageProvider).images]) {
          if (!ids.contains(image.id)) continue;
          ref
              .read(placedImageProvider.notifier)
              .updatePosition(image.position + by, image.id);
        }
        for (final utility in [...ref.read(utilityProvider)]) {
          if (!ids.contains(utility.id)) continue;
          ref
              .read(utilityProvider.notifier)
              .updatePosition(utility.position + by, utility.id);
        }
        final drawingIds = {
          for (final drawing in ref.read(drawingProvider).elements)
            if (ids.contains(drawing.id)) drawing.id,
        };
        if (drawingIds.isNotEmpty) {
          ref.read(drawingProvider.notifier).translateDrawings(drawingIds, by);
        }
      },
    );
  }

  /// Deletes everything selected as one undo step.
  void deleteSelected() {
    deleteItems(state);
    clear();
  }

  /// Deletes [selection] (items of the page on screen) as one undo step.
  void deleteItems(Set<SelectedItem> selection) {
    if (selection.isEmpty ||
        !ref.read(currentStrategyCapabilitiesProvider).canEditPages) {
      return;
    }
    ref.read(actionProvider.notifier).performTransaction(
      groups: const [],
      mutation: () {
        final drawingIds = <String>{};
        for (final item in selection) {
          switch (item.kind) {
            case SelectableKind.agent:
              ref.read(agentProvider.notifier).removeAgentAsAction(item.id);
            case SelectableKind.ability:
              ref.read(abilityProvider.notifier).removeAbilityAsAction(item.id);
            case SelectableKind.text:
              ref.read(textProvider.notifier).removeTextAsAction(item.id);
            case SelectableKind.image:
              ref
                  .read(placedImageProvider.notifier)
                  .removeImageAsAction(item.id);
            case SelectableKind.utility:
              ref.read(utilityProvider.notifier).removeUtilityAsAction(item.id);
            case SelectableKind.drawing:
              drawingIds.add(item.id);
            case SelectableKind.lineup:
              ref.read(lineUpProvider.notifier).deleteLink(item.id);
          }
        }
        if (drawingIds.isNotEmpty) {
          ref.read(drawingProvider.notifier).deleteDrawingsById(drawingIds);
        }
      },
    );
    clear();
  }
}
