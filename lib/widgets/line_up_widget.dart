import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_visibility_context_menu.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

const double _pinnedRingGap = 3;
const double _pinnedRingStroke = 2;
const double _placingDimOpacity = 0.2;

class LineUpOriginAgentWidget extends ConsumerWidget {
  LineUpOriginAgentWidget({Key? key, required this.origin})
      : super(key: key ?? ValueKey('lineup-agent-widget-${origin.id}'));

  final LineUpOrigin origin;

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
    final isPlacing =
        ref.watch(interactionStateProvider) == InteractionState.lineUpPlacing;
    final isPinned = ref.watch(
      lineUpProvider.select(
        (state) => state.placement?.pinnedOriginId == origin.id,
      ),
    );

    return Positioned(
      key: ValueKey('lineup-agent-${origin.id}'),
      left: agentScreen.dx,
      top: agentScreen.dy,
      child: _PinnedEnd(
        isPinned: isPinned,
        dimmed: isPlacing && !isPinned,
        label: 'Origin',
        shape: BoxShape.circle,
        child: AgentWidget(
          lineUpId: origin.id,
          agent: AgentData.agents[origin.agent.type]!,
          isAlly: origin.agent.isAlly,
          id: origin.agent.id,
        ),
      ),
    );
  }
}

class LineUpLandingAbilityWidget extends ConsumerWidget {
  LineUpLandingAbilityWidget({Key? key, required this.landing})
      : super(key: key ?? ValueKey('lineup-ability-widget-${landing.id}'));

  final LineUpLanding landing;

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
    final contextMenuItems = buildAbilityContextMenuItems(
      ref,
      ability,
      landingId: landing.id,
      context: context,
    );
    final isPlacing =
        ref.watch(interactionStateProvider) == InteractionState.lineUpPlacing;
    final isPinned = ref.watch(
      lineUpProvider.select(
        (state) => state.placement?.pinnedLandingId == landing.id,
      ),
    );
    final badgeCount = ref.watch(
      lineUpProvider.select((state) {
        final links = state.linksToLanding(landing.id);
        var maxPerOrigin = 0;
        final counts = <String, int>{};
        for (final link in links) {
          final count = (counts[link.originId] ?? 0) + 1;
          counts[link.originId] = count;
          if (count > maxPerOrigin) maxPerOrigin = count;
        }
        return maxPerOrigin;
      }),
    );

    Widget abilityChild = ability.data.abilityData!.createWidget(
      id: null,
      isAlly: ability.isAlly,
      mapScale: mapScale,
      landingId: landing.id,
      rotation: displayRotation,
      length: ability.length,
      armLengthsMeters: ability.armLengthsMeters,
      visualState: ability.visualState,
      watchMouse: true,
      contextMenuItems: contextMenuItems,
    );
    if (shouldRotate) {
      abilityChild = Transform.rotate(
        angle: displayRotation,
        alignment: Alignment.topLeft,
        origin: ability.data.abilityData!
            .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
            .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor),
        child: abilityChild,
      );
    }

    return Positioned(
      key: ValueKey('lineup-ability-${landing.id}'),
      left: abilityScreen.dx,
      top: abilityScreen.dy,
      child: _PinnedEnd(
        isPinned: isPinned,
        dimmed: isPlacing && !isPinned,
        label: 'Landing spot',
        shape: BoxShape.rectangle,
        badgeCount: badgeCount > 1 ? badgeCount : null,
        child: abilityChild,
      ),
    );
  }
}

/// Wraps a lineup end with the placement styling: dimmed while another end is
/// being placed, or ringed in violet with a chip when it is the pinned one. A
/// [badgeCount] marks a landing with several ways in from one origin.
class _PinnedEnd extends StatelessWidget {
  const _PinnedEnd({
    required this.isPinned,
    required this.dimmed,
    required this.label,
    required this.shape,
    required this.child,
    this.badgeCount,
  });

  final bool isPinned;
  final bool dimmed;
  final String label;
  final BoxShape shape;
  final Widget child;
  final int? badgeCount;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    Widget result = child;

    if (badgeCount != null) {
      result = Stack(
        clipBehavior: Clip.none,
        children: [
          result,
          Positioned(
            top: -7,
            right: -7,
            child: Container(
              key: ValueKey('lineup-count-badge-$badgeCount'),
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.secondary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF3F3F46)),
              ),
              child: Text(
                '$badgeCount',
                style: TextStyle(
                  color: theme.foreground,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (isPinned) {
      const inset = _pinnedRingGap + _pinnedRingStroke;
      result = Stack(
        clipBehavior: Clip.none,
        children: [
          result,
          Positioned.fill(
            left: -inset,
            top: -inset,
            right: -inset,
            bottom: -inset,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: shape,
                  borderRadius: shape == BoxShape.rectangle
                      ? BorderRadius.circular(3 + inset)
                      : null,
                  border: Border.all(
                    color: theme.primary,
                    width: _pinnedRingStroke,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: -inset - 4 - 16,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  key: ValueKey('lineup-pinned-chip-$label'),
                  height: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: TextStyle(
                      color: theme.primaryForeground,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    } else if (dimmed) {
      result = Opacity(opacity: _placingDimOpacity, child: result);
    }

    return result;
  }
}
