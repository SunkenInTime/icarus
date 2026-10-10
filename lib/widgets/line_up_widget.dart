import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_visibility_context_menu.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

const double _pinnedRingGap = 3;
const double _pinnedRingStroke = 2;

class LineUpOriginAgentWidget extends ConsumerWidget {
  LineUpOriginAgentWidget({
    Key? key,
    required this.origin,
    this.interactive = true,
    this.onMove,
    this.onMoveEnd,
  }) : super(key: key ?? ValueKey('lineup-agent-widget-${origin.id}'));

  final LineUpOrigin origin;

  /// False for the full-opacity copy the placer draws over the dimmed map
  /// while this origin is pinned; the real one underneath keeps the hitbox.
  final bool interactive;

  /// Set only while placement editing moves this origin: the marker follows
  /// the pointer itself, with no drag image, and reports each move. Placed
  /// lineups stay where they are otherwise.
  final ValueChanged<DragUpdateDetails>? onMove;

  /// Called when a move reported through [onMove] ends.
  final VoidCallback? onMoveEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final agentSize = ref.watch(strategySettingsProvider).agentSize;
    final isAttack = ref.watch(mapProvider).isAttack;
    final agentScreen = screenPositionForWidget(
      widget: origin.agent,
      coordinateSystem: coordinateSystem,
      agentSize: agentSize,
      isAttack: isAttack,
    );
    final isPinned = ref.watch(
      lineUpProvider.select(
        (state) => state.placement?.pinnedOriginId == origin.id,
      ),
    );

    Widget marker = _PinnedEnd(
      isPinned: isPinned,
      child: AgentWidget(
        lineUpId: origin.id,
        agent: AgentData.agents[origin.agent.type]!,
        isAlly: origin.agent.isAlly,
        weapon: origin.agent.weapon,
        id: origin.agent.id,
        isInteractive: interactive,
      ),
    );
    final canEdit = ref.watch(
      currentStrategyCapabilitiesProvider.select(
        (capabilities) => capabilities.canEditPages,
      ),
    );
    final moving = canEdit && onMove != null;
    if (moving) {
      marker = _MovableEnd(
        key: ValueKey('lineup-agent-drag-${origin.id}'),
        onMove: onMove!,
        onMoveEnd: onMoveEnd,
        child: marker,
      );
    }

    return Positioned(
      key: ValueKey('lineup-agent-${origin.id}'),
      left: agentScreen.dx,
      top: agentScreen.dy,
      child: IgnorePointer(
        ignoring: !interactive && !moving,
        child: marker,
      ),
    );
  }
}

class LineUpLandingAbilityWidget extends ConsumerWidget {
  LineUpLandingAbilityWidget({
    Key? key,
    required this.landing,
    this.interactive = true,
    this.onMove,
    this.onMoveEnd,
  }) : super(key: key ?? ValueKey('lineup-ability-widget-${landing.id}'));

  final LineUpLanding landing;

  /// False for the full-opacity copy the placer draws over the dimmed map
  /// while this landing is pinned; the real one underneath keeps the hitbox.
  final bool interactive;

  /// Set only while placement editing moves this landing: the marker follows
  /// the pointer itself, with no drag image, and reports each move. Placed
  /// lineups stay where they are otherwise.
  final ValueChanged<DragUpdateDetails>? onMove;

  /// Called when a move reported through [onMove] ends.
  final VoidCallback? onMoveEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final currentMap = ref.watch(
      mapProvider.select((state) => state.currentMap),
    );
    final isAttack = ref.watch(mapProvider).isAttack;
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final ability = landing.ability;
    final abilityScreen = screenPositionForWidget(
      widget: ability,
      coordinateSystem: coordinateSystem,
      mapScale: mapScale,
      abilitySize: abilitySize,
      isAttack: isAttack,
    );
    final displayRotation = coordinateSystem.rotationForSide(
      ability.rotation,
      isAttack: isAttack,
    );
    final shouldRotate = isRotatable(ability.data.abilityData!);
    final contextMenuItems = interactive
        ? buildAbilityContextMenuItems(
            ref,
            ability,
            landingId: landing.id,
            context: context,
          )
        : null;
    final isPinned = ref.watch(
      lineUpProvider.select(
        (state) => state.placement?.pinnedLandingId == landing.id,
      ),
    );
    Widget buildAbility({required bool isFeedback}) {
      final child = ability.data.abilityData!.createWidget(
        id: null,
        isAlly: ability.isAlly,
        mapScale: mapScale,
        landingId: landing.id,
        // Landings can't be turned yet, so a plain icon stays upright.
        rotation:
            turnsGlyph(ability.data.abilityData!) ? null : displayRotation,
        length: ability.length,
        armLengthsMeters: ability.armLengthsMeters,
        visualState: ability.visualState,
        watchMouse: interactive && !isFeedback,
        contextMenuItems: isFeedback ? null : contextMenuItems,
      );
      if (!shouldRotate) return child;
      return Transform.rotate(
        angle: displayRotation,
        alignment: Alignment.topLeft,
        origin: ability.data.abilityData!
            .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
            .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor),
        child: child,
      );
    }

    Widget marker = _PinnedEnd(
      isPinned: isPinned,
      child: buildAbility(isFeedback: false),
    );
    final canEdit = ref.watch(
      currentStrategyCapabilitiesProvider.select(
        (capabilities) => capabilities.canEditPages,
      ),
    );
    final moving = canEdit && onMove != null;
    if (moving) {
      marker = _MovableEnd(
        key: ValueKey('lineup-ability-drag-${landing.id}'),
        onMove: onMove!,
        onMoveEnd: onMoveEnd,
        // The ability art has transparent gaps; the whole box takes the drag.
        child: ColoredBox(color: Colors.transparent, child: marker),
      );
    }

    return Positioned(
      key: ValueKey('lineup-ability-${landing.id}'),
      left: abilityScreen.dx,
      top: abilityScreen.dy,
      child: IgnorePointer(
        ignoring: !interactive && !moving,
        child: marker,
      ),
    );
  }
}

/// What a lineup end being moved in placement editing carries. Nothing on
/// the canvas accepts it (the delete area takes placed widgets), so dropping
/// it only ends the move.
class _MovingLineUpEnd {
  const _MovingLineUpEnd();
}

/// A lineup end that moves with the pointer while placement editing is on.
/// The marker itself is redrawn at each new position, so there is no drag
/// image, and the lines into it follow live.
class _MovableEnd extends StatelessWidget {
  const _MovableEnd({
    super.key,
    required this.onMove,
    required this.onMoveEnd,
    required this.child,
  });

  final ValueChanged<DragUpdateDetails> onMove;
  final VoidCallback? onMoveEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Draggable<_MovingLineUpEnd>(
        data: const _MovingLineUpEnd(),
        feedback: const SizedBox.shrink(),
        onDragUpdate: onMove,
        onDragEnd: (_) => onMoveEnd?.call(),
        child: child,
      ),
    );
  }
}

/// Wraps a lineup end: ringed in violet when it is the pinned one.
class _PinnedEnd extends StatelessWidget {
  const _PinnedEnd({required this.isPinned, required this.child});

  final bool isPinned;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    // The tree shape stays the same whatever the state, so the child keeps its
    // element (and its registered hitbox) when a pin comes and goes.
    const inset = _pinnedRingGap + _pinnedRingStroke;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (isPinned)
          Positioned.fill(
            left: -inset,
            top: -inset,
            right: -inset,
            bottom: -inset,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3 + inset),
                  border: Border.all(
                    color: theme.primary,
                    width: _pinnedRingStroke,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
