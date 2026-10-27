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

  /// Deletes everything selected as one undo step.
  void deleteSelected() {
    final selection = state;
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
