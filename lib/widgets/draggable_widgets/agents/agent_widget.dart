import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Grayscale color matrix for dead agents
const List<double> _identityColorMatrix = <double>[
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
];

const List<double> _grayscaleColorMatrix = <double>[
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
];

/// Muted background colors for dead agents
const Color _mutedAllyBGColor = Color.fromARGB(255, 60, 60, 60);
const Color _mutedEnemyBGColor = Color.fromARGB(255, 70, 50, 50);

/// Muted outline colors for dead agents
const Color _mutedAllyOutlineColor = Color.fromARGB(100, 100, 100, 100);
const Color _mutedEnemyOutlineColor = Color.fromARGB(100, 120, 80, 80);

class AgentWidget extends ConsumerWidget {
  const AgentWidget({
    super.key,
    required this.agent,
    required this.id,
    required this.isAlly,
    this.lineUpId,
    this.state = AgentState.none,
    this.forcedAgentSize,
    this.deadStateProgress,
  });

  final String? lineUpId;
  final String? id;
  final bool isAlly;
  final AgentData agent;
  final AgentState state;
  final double? forcedAgentSize;
  final double? deadStateProgress;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final mapScale = Maps.mapScale[ref.watch(mapProvider).currentMap] ?? 1.0;
    final agentSize =
        forcedAgentSize ?? ref.watch(strategySettingsProvider).agentSize;
    final useNeutralTeamColors =
        ref.watch(strategySettingsProvider).useNeutralTeamColors;
    final isScreenshot = ref.watch(screenshotProvider);
    final deadProgress =
        (deadStateProgress ?? (state == AgentState.dead ? 1.0 : 0.0))
            .clamp(0.0, 1.0);
    final hasDeadStyling = deadProgress > 0;
    final hoverTarget = ref.watch(hoveredLineUpTargetProvider);
    final isLineUpHovered =
        lineUpId != null && (hoverTarget?.matchesAgent(lineUpId!) ?? false);

    final agentImage = RepaintBoundary(child: Image.asset(agent.iconPath));

    // Determine background color
    Color bgColor = isAlly ? Settings.allyBGColor : Settings.enemyBGColor;
    if (useNeutralTeamColors) {
      bgColor = ShadTheme.of(context).colorScheme.secondary;
    }

    final deadBgColor = isAlly ? _mutedAllyBGColor : _mutedEnemyBGColor;
    bgColor = Color.lerp(bgColor, deadBgColor, deadProgress) ?? bgColor;

    if (isLineUpHovered) {
      bgColor = Colors.deepPurple;
    }

    // Determine outline color
    Color outlineColor =
        isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor;
    if (useNeutralTeamColors) {
      outlineColor = Settings.neutralTeamShade(outlineColor);
    }

    final deadOutlineColor =
        isAlly ? _mutedAllyOutlineColor : _mutedEnemyOutlineColor;
    outlineColor = Color.lerp(outlineColor, deadOutlineColor, deadProgress) ??
        outlineColor;

    if (isLineUpHovered) {
      outlineColor = Colors.deepPurpleAccent;
    }

    Widget agentDisplay = agentImage;
    if (hasDeadStyling) {
      final xOpacity = Curves.easeIn.transform(
        ((deadProgress - 0.45) / 0.55).clamp(0.0, 1.0),
      );
      agentDisplay = Stack(
        children: [
          ColorFiltered(
            colorFilter: ColorFilter.matrix(_lerpColorMatrix(deadProgress)),
            child: agentImage,
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: xOpacity,
                child: const CustomPaint(
                  painter: _DeadXOverlayPainter(),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final bool isLineUp = lineUpId != null;

    // final bool isNoneInteractive = (id == null || id!.isEmpty);

    final decoration = BoxDecoration(
      color: bgColor,
      border: Border.all(
        color: outlineColor,
      ),
      borderRadius: const BorderRadius.all(
        Radius.circular(3),
      ),
    );

    final scaledSize = coordinateSystem.scale(agentSize);
    final deleteTarget = lineUpId != null
        ? HoveredDeleteTarget.lineup(id: lineUpId!, ownerToken: Object())
        : (id?.isNotEmpty ?? false)
            ? HoveredDeleteTarget.agent(id: id!, ownerToken: Object())
            : null;
    final plainAgent = lineUpId == null && (id?.isNotEmpty ?? false)
        ? ref.watch(
            agentProvider.select(
              (agents) => agents.whereType<PlacedAgent>().firstWhere(
                    (entry) => entry.id == id,
                    orElse: () => PlacedAgent(
                      type: agent.type,
                      position: Offset.zero,
                      id: '',
                    ),
                  ),
            ),
          )
        : null;

    final canShowAgentContextMenu =
        !isScreenshot && (lineUpId != null || (id != null && id!.isNotEmpty));
    final contextMenuItems = <ShadContextMenuItem>[
      if (canShowAgentContextMenu)
        ShadContextMenuItem.raw(
          variant: ShadContextMenuItemVariant.primary,
          height: 36,
          closeOnTap: false,
          padding: const EdgeInsets.only(bottom: 4),
          insetPadding: const EdgeInsets.only(left: 4, right: 4),
          backgroundColor: Colors.transparent,
          selectedBackgroundColor: Colors.transparent,
          child: _AgentAbilityContextMenuRow(
            agent: agent,
            isAlly: isAlly,
            mapScale: mapScale,
          ),
        ),
      if (lineUpId != null)
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.plus),
          child: const Text('Add Lineup Item'),
          onPressed: () {
            final group =
                ref.read(lineUpProvider.notifier).getGroupById(lineUpId!);
            if (group == null) return;
            ref
                .read(abilityBarProvider.notifier)
                .updateData(AgentData.agents[group.agent.type]!);
            ref
                .read(interactionStateProvider.notifier)
                .update(InteractionState.lineUpPlacing);
            ref.read(lineUpProvider.notifier).startNewItemForGroup(lineUpId!);
          },
        ),
      if (lineUpId != null)
        ShadContextMenuItem(
          leading: Icon(
            Icons.delete,
            color: Settings.tacticalVioletTheme.destructive,
          ),
          child: const Text('Delete Lineup Group'),
          onPressed: () {
            ref.read(lineUpProvider.notifier).deleteGroupById(lineUpId!);
          },
        ),
      if (lineUpId == null && plainAgent != null && plainAgent.id.isNotEmpty)
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.plus),
          child: const Text('Create Lineup'),
          onPressed: () {
            ref
                .read(interactionStateProvider.notifier)
                .update(InteractionState.lineUpPlacing);
            ref.read(lineUpProvider.notifier).startNewGroup(plainAgent);
          },
        ),
    ];

    Widget agentCard;
    // Use Ink + InkWell so the ripple shows on top of the background

    if (isLineUp || isScreenshot) {
      agentCard = Container(
        decoration: decoration,
        width: scaledSize,
        height: scaledSize,
        child: agentDisplay,
      );
    } else {
      agentCard = Material(
        color: Colors.transparent,
        child: Ink(
          decoration: decoration,
          width: scaledSize,
          height: scaledSize,
          child: InkWell(
            mouseCursor: SystemMouseCursors.click,
            borderRadius: const BorderRadius.all(Radius.circular(3)),
            highlightColor: Colors.white.withValues(alpha: 0.2),
            splashColor: Colors.white.withValues(alpha: 0.3),
            onLongPress: () {
              if (id == null) return;
              ref.read(agentProvider.notifier).toggleAgentState(id!);
            },
            child: agentDisplay,
          ),
        ),
      );
    }

    return MouseWatch(
      lineUpId: lineUpId,
      cursor: SystemMouseCursors.click,
      deleteTarget: deleteTarget,
      contextMenuItems: contextMenuItems.isEmpty ? null : contextMenuItems,
      child: agentCard,
    );
  }
}

class _AgentAbilityContextMenuRow extends ConsumerWidget {
  const _AgentAbilityContextMenuRow({
    required this.agent,
    required this.isAlly,
    required this.mapScale,
  });

  final AgentData agent;
  final bool isAlly;
  final double mapScale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      spacing: 4,
      // crossAxisAlignment: CrossAxisAlignment.start,
      //
      mainAxisSize: MainAxisSize.max,
      // mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final ability in agent.abilities)
          _AgentAbilityContextMenuButton(
            ability: ability,
            isAlly: isAlly,
            mapScale: mapScale,
          ),
      ],
    );
  }
}

class _AgentAbilityContextMenuButton extends ConsumerStatefulWidget {
  const _AgentAbilityContextMenuButton({
    required this.ability,
    required this.isAlly,
    required this.mapScale,
  });

  final AbilityInfo ability;
  final bool isAlly;
  final double mapScale;

  @override
  ConsumerState<_AgentAbilityContextMenuButton> createState() =>
      _AgentAbilityContextMenuButtonState();
}

class _AgentAbilityContextMenuButtonState
    extends ConsumerState<_AgentAbilityContextMenuButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final ability = widget.ability;
    final background = _isHovered || _isPressed
        ? theme.colorScheme.accent
        : theme.colorScheme.secondary;
    final borderColor = _isHovered || _isPressed
        ? theme.colorScheme.ring
        : theme.colorScheme.border;

    return Draggable<DraggedAbilityData>(
      data: DraggedAbilityData(
        ability: ability,
        isAlly: widget.isAlly,
      ),
      onDragStarted: () {
        setState(() => _isPressed = false);
        final interactionState = ref.read(interactionStateProvider);
        if (interactionState == InteractionState.drawing ||
            interactionState == InteractionState.erasing) {
          ref
              .read(interactionStateProvider.notifier)
              .update(InteractionState.navigation);
        }
      },
      dragAnchorStrategy: (draggable, context, position) {
        final info = (draggable.data as DraggedAbilityData).ability;
        final scaleFactor = CoordinateSystem.instance.scaleFactor *
            ref.read(screenZoomProvider);
        final abilitySize = ref.read(strategySettingsProvider).abilitySize;

        return info.abilityData!
            .getAnchorPoint(
              mapScale: widget.mapScale,
              abilitySize: abilitySize,
            )
            .scale(scaleFactor, scaleFactor);
      },
      feedback: Opacity(
        opacity: Settings.feedbackOpacity,
        child: ZoomTransform(
          child: ability.abilityData!.createWidget(
            id: null,
            isAlly: widget.isAlly,
            mapScale: widget.mapScale,
          ),
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() {
          _isHovered = false;
          _isPressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapCancel: () => setState(() => _isPressed = false),
          onTapUp: (_) => setState(() => _isPressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            width: 36,
            height: 36,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: borderColor),
            ),
            child: Image.asset(ability.iconPath),
          ),
        ),
      ),
    );
  }
}

List<double> _lerpColorMatrix(double t) {
  return List<double>.generate(
    _identityColorMatrix.length,
    (index) =>
        _identityColorMatrix[index] +
        (_grayscaleColorMatrix[index] - _identityColorMatrix[index]) * t,
  );
}

/// Draws a red X overlay for dead agents
class _DeadXOverlayPainter extends CustomPainter {
  const _DeadXOverlayPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red.withValues(alpha: 0.8)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Add some padding so the X doesn't touch the edges
    const padding = 4.0;

    // Draw first diagonal (top-left to bottom-right)
    canvas.drawLine(
      const Offset(padding, padding),
      Offset(size.width - padding, size.height - padding),
      paint,
    );

    // Draw second diagonal (top-right to bottom-left)
    canvas.drawLine(
      Offset(size.width - padding, padding),
      Offset(padding, size.height - padding),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
