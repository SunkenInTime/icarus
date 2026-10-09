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
  final agentType = edit.originPositions.keys
      .map((id) => state.originById(id)?.agent.type)
      .nonNulls
      .firstOrNull;
  final agentName = AgentData.agents[agentType]?.name ?? 'the agent';
  final count = edit.linkIds.length;
  if (count == 1) return 'Drag $agentName or the ability to its new spot';
  return 'Drag $agentName or an ability. These $count lineups share a spot, '
      'so they move together';
}

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
  /// The drag under way: the pointer and the end's top-left where it began,
  /// in this layer's pixels, and the end's stored position then.
  ({Offset pointer, Offset topLeft, Offset position})? _drag;

  /// Where the drag puts the end's top-left, keeping the point that was
  /// grabbed under the pointer.
  Offset _draggedTopLeft(
    DragUpdateDetails details, {
    required Offset topLeft,
    required Offset position,
  }) {
    final box = context.findRenderObject() as RenderBox;
    final drag = _drag ??= (
      pointer: box.globalToLocal(details.globalPosition - details.delta),
      topLeft: topLeft,
      position: position,
    );
    return drag.topLeft +
        (box.globalToLocal(details.globalPosition) - drag.pointer);
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final state = ref.watch(lineUpProvider);
    final edit = state.edit;
    if (edit == null) return const SizedBox.shrink();
    final settings = ref.watch(strategySettingsProvider);
    final currentMap = ref.watch(mapProvider.select((s) => s.currentMap));
    final isAttack = ref.watch(mapProvider.select((s) => s.isAttack));
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final notifier = ref.read(lineUpProvider.notifier);

    final origins = [
      for (final MapEntry(key: id, value: position)
          in edit.originPositions.entries)
        if (state.originById(id) case final origin?)
          origin.copyWith(agent: origin.agent.copyWith(position: position)),
    ];
    final landings = [
      for (final MapEntry(key: id, value: position)
          in edit.landingPositions.entries)
        if (state.landingById(id) case final landing?)
          landing.copyWith(
            ability: landing.ability.copyWith(position: position),
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(interactionStateProvider.notifier)
            .update(InteractionState.navigation);
      });
      return const SizedBox.shrink();
    }

    void endMove({required bool outOfBounds, required void Function() undo}) {
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
                topLeft: screenPositionForWidget(
                  widget: origin.agent,
                  coordinateSystem: coordinateSystem,
                  agentSize: settings.agentSize,
                  isAttack: isAttack,
                ),
                position: origin.agent.position,
              );
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
                  ref.read(lineUpProvider).edit?.originPositions[origin.id];
              endMove(
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
                topLeft: screenPositionForWidget(
                  widget: landing.ability,
                  coordinateSystem: coordinateSystem,
                  mapScale: mapScale,
                  abilitySize: settings.abilitySize,
                  isAttack: isAttack,
                ),
                position: landing.ability.position,
              );
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
                  ref.read(lineUpProvider).edit?.landingPositions[landing.id];
              final anchor = storedAbilityAnchor(
                ability: landing.ability.data.abilityData!,
                mapScale: mapScale,
              );
              endMove(
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
