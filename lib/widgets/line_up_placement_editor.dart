import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/line_up_line_painter.dart';
import 'package:icarus/widgets/line_up_placer.dart';
import 'package:icarus/widgets/line_up_widget.dart';

/// The one thing to do next while editing placement. Empty once something
/// has moved: the pill would cover what is being dragged, and Save is lit.
String lineUpEditStatus(LineUpState state) {
  final edit = state.edit;
  if (edit == null || state.editMovesAnything) return '';
  final agentType = edit.originIds
      .map((id) => state.originById(id)?.agent.type)
      .nonNulls
      .firstOrNull;
  final agentName = AgentData.agents[agentType]?.name ?? 'the agent';
  final count = edit.linkIds.length;
  if (count == 1) return 'Drag $agentName or the ability to its new spot';
  return 'Drag $agentName or an ability. These $count lineups share a spot, '
      'so they move together';
}

/// One end of an edited lineup: its id, and whether it is an origin (else a
/// landing).
typedef _End = (String id, bool origin);

/// Placement editing: the lineups being moved, drawn over the dimmed page at
/// their draft positions. Each origin and landing follows the pointer with
/// its lines; Save in LineupControlButtons writes the move.
class LineUpPlacementEditor extends ConsumerStatefulWidget {
  const LineUpPlacementEditor({super.key});

  @override
  ConsumerState<LineUpPlacementEditor> createState() =>
      _LineUpPlacementEditorState();
}

class _LineUpPlacementEditorState extends ConsumerState<LineUpPlacementEditor> {
  /// The drag under way: which end, how far the pointer has moved in window
  /// pixels, and the end's top-left in this layer's pixels and its stored
  /// position where the drag began.
  ({
    _End end,
    Offset moved,
    Offset topLeft,
    Offset position,
  })? _drag;

  /// The end whose drag a reload of the page took back while the pointer
  /// was still down. The rest of that gesture moves nothing; dragging
  /// another end clears it.
  _End? _takenBack;

  /// Where the drag of [end] puts its top-left, keeping the point that was
  /// grabbed under the pointer, or null once a reload took the drag back.
  /// The movement adds up the updates' deltas: the first update reports
  /// where the pointer went down, not where it is.
  Offset? _draggedTopLeft(
    DragUpdateDetails details, {
    required _End end,
    required Offset topLeft,
    required Offset position,
  }) {
    if (_takenBack == end) return null;
    _takenBack = null;
    final box = context.findRenderObject() as RenderBox;
    final drag = _drag = (
      end: end,
      moved: (_drag?.moved ?? Offset.zero) + details.delta,
      topLeft: _drag?.topLeft ?? topLeft,
      position: _drag?.position ?? position,
    );
    // The map can be zoomed and panned, so the movement is converted to this
    // layer's pixels as a whole.
    return drag.topLeft +
        (box.globalToLocal(drag.moved) - box.globalToLocal(Offset.zero));
  }

  void _leave() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(interactionStateProvider.notifier)
          .update(InteractionState.navigation);
    });
  }

  /// A reload of the page reopens the edit, deciding which drags it keeps
  /// (see LineUpProvider.fromHive). The drag under way carries on only if
  /// the reload kept its draft; otherwise following the pointer would put
  /// back a drag the reload undid.
  void _onEditReopened(LineUpPlacementEdit? edit) {
    bool inEdit(_End end) {
      final (id, origin) = end;
      return (origin ? edit?.originIds : edit?.landingIds)?.contains(id) ??
          false;
    }

    // An end the reload removed has no gesture left to finish.
    if (_takenBack case final end? when !inEdit(end)) _takenBack = null;
    final drag = _drag;
    if (drag == null) return;
    final (id, origin) = drag.end;
    final drafts = origin ? edit?.movedOrigins : edit?.movedLandings;
    if (drafts?.containsKey(id) ?? false) return;
    _drag = null;
    if (inEdit(drag.end)) _takenBack = drag.end;
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    ref.listen(lineUpProvider, (previous, next) {
      // Drags keep the edit's lineups; a new set means it was reopened.
      if (!identical(previous?.edit?.linkIds, next.edit?.linkIds)) {
        _onEditReopened(next.edit);
      }
    });
    final state = ref.watch(lineUpProvider);
    final edit = state.edit;
    // The page's lineups were replaced (another page opened, or a reload
    // took every lineup being moved) and the edit went with them.
    if (edit == null) {
      _leave();
      return const SizedBox.shrink();
    }
    final settings = ref.watch(strategySettingsProvider);
    final currentMap = ref.watch(mapProvider.select((s) => s.currentMap));
    final isAttack = ref.watch(mapProvider.select((s) => s.isAttack));
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final notifier = ref.read(lineUpProvider.notifier);

    // Dragged ends sit at their drafts; the rest wherever the page has them.
    final origins = [
      for (final id in edit.originIds)
        if (state.originById(id) case final origin?)
          edit.movedOrigins[id] == null
              ? origin
              : origin.copyWith(
                  agent: origin.agent.copyWith(
                    position: edit.movedOrigins[id],
                  ),
                ),
    ];
    final landings = [
      for (final id in edit.landingIds)
        if (state.landingById(id) case final landing?)
          edit.movedLandings[id] == null
              ? landing
              : landing.copyWith(
                  ability: landing.ability.copyWith(
                    position: edit.movedLandings[id],
                  ),
                ),
    ];
    final draft = LineUpState(
      origins: origins,
      landings: landings,
      links: [
        for (final link in state.links)
          if (edit.linkIds.contains(link.id)) link,
      ],
    );
    // A teammate or an undo removed every lineup being moved.
    if (draft.links.isEmpty) {
      _leave();
      return const SizedBox.shrink();
    }

    void endMove(
      _End end, {
      required bool outOfBounds,
      required void Function() undo,
    }) {
      if (_takenBack == end) {
        _takenBack = null;
        return;
      }
      // Dropped off the map: the end goes back to where the drag began.
      if (outOfBounds) undo();
      _drag = null;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: LinePainter(
                resizeCounter: ref.watch(lineUpCanvasResizeProvider),
                hoveredLineUpTarget: null,
                lineUpState: draft,
                coordinateSystem: coordinateSystem,
                abilitySize: settings.abilitySize,
                agentSize: coordinateSystem.scale(settings.agentSize),
                mapScale: mapScale,
                isAttack: isAttack,
                color: Settings.accentInk,
              ),
            ),
          ),
        ),
        for (final origin in origins)
          LineUpOriginAgentWidget(
            key: ValueKey('lineup-edit-agent-${origin.id}'),
            origin: origin,
            interactive: false,
            onMove: (details) {
              final topLeft = _draggedTopLeft(
                details,
                end: (origin.id, true),
                topLeft: screenPositionForWidget(
                  widget: origin.agent,
                  coordinateSystem: coordinateSystem,
                  agentSize: settings.agentSize,
                  isAttack: isAttack,
                ),
                position: origin.agent.position,
              );
              if (topLeft == null) return;
              notifier.moveEditedOrigin(
                origin.id,
                storedAgentPositionForRenderedScreenPosition(
                  coordinateSystem: coordinateSystem,
                  renderedScreenPosition: topLeft,
                  agentSize: settings.agentSize,
                  isAttack: isAttack,
                ),
              );
            },
            onMoveEnd: () {
              final start = _drag?.position;
              final position =
                  ref.read(lineUpProvider).edit?.movedOrigins[origin.id];
              endMove(
                (origin.id, true),
                outOfBounds: position != null &&
                    coordinateSystem
                        .isOutOfBounds(position + storedAgentAnchor),
                undo: () {
                  if (start != null) {
                    notifier.moveEditedOrigin(origin.id, start);
                  }
                },
              );
            },
          ),
        for (final landing in landings)
          LineUpLandingAbilityWidget(
            key: ValueKey('lineup-edit-ability-${landing.id}'),
            landing: landing,
            interactive: false,
            onMove: (details) {
              final abilityData = landing.ability.data.abilityData!;
              final topLeft = _draggedTopLeft(
                details,
                end: (landing.id, false),
                topLeft: screenPositionForWidget(
                  widget: landing.ability,
                  coordinateSystem: coordinateSystem,
                  mapScale: mapScale,
                  abilitySize: settings.abilitySize,
                  isAttack: isAttack,
                ),
                position: landing.ability.position,
              );
              if (topLeft == null) return;
              notifier.moveEditedLanding(
                landing.id,
                storedAbilityPositionForRenderedScreenPosition(
                  ability: abilityData,
                  coordinateSystem: coordinateSystem,
                  renderedScreenPosition: topLeft,
                  mapScale: mapScale,
                  abilitySize: settings.abilitySize,
                  isAttack: isAttack,
                ),
              );
            },
            onMoveEnd: () {
              final start = _drag?.position;
              final position =
                  ref.read(lineUpProvider).edit?.movedLandings[landing.id];
              final anchor = storedAbilityAnchor(
                ability: landing.ability.data.abilityData!,
                mapScale: mapScale,
              );
              endMove(
                (landing.id, false),
                outOfBounds: position != null &&
                    coordinateSystem.isOutOfBounds(position + anchor),
                undo: () {
                  if (start != null) {
                    notifier.moveEditedLanding(landing.id, start);
                  }
                },
              );
            },
          ),
        if (lineUpEditStatus(state) case final status when status.isNotEmpty)
          LineUpStatusPill(
            key: const ValueKey('lineup-edit-status'),
            text: status,
          ),
      ],
    );
  }
}
