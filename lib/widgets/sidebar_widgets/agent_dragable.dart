import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/favorite_agents_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_feedback_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

final dragNotifier = NotifierProvider<DragNotifier, bool>(DragNotifier.new);

class DragNotifier extends Notifier<bool> {
  @override
  bool build() {
    return false;
  }

  void updateDragState(bool isDragging) {
    state = isDragging;
  }
}

class AgentDragable extends ConsumerStatefulWidget {
  const AgentDragable({
    super.key,
    required this.agent,
  });
  final AgentData agent;

  @override
  ConsumerState<AgentDragable> createState() => _AgentDragableState();
}

class _AgentDragableState extends ConsumerState<AgentDragable>
    with SingleTickerProviderStateMixin {
  bool _isTileHovered = false;
  bool _isStarHovered = false;
  bool _isStarPressed = false;
  late final AnimationController _clickController;
  late final Animation<double> _clickScale;
  Timer? _favoriteHoverDelayTimer;
  DateTime _starOffEnabledAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _clickController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _clickScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.92),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.92, end: 1.08),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.08, end: 1.0),
        weight: 35,
      ),
    ]).animate(
      CurvedAnimation(parent: _clickController, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _favoriteHoverDelayTimer?.cancel();
    _clickController.dispose();
    super.dispose();
  }

  Future<void> _toggleFavoriteWithFeedback({
    required AgentType type,
    required bool wasFavorite,
  }) async {
    await ref.read(favoriteAgentsProvider.notifier).toggleFavorite(type);
    if (!mounted) return;

    // Keep the newly-favorited state visible for a moment before allowing
    // hover to flip the icon to "unfavorite".
    if (!wasFavorite) {
      _favoriteHoverDelayTimer?.cancel();
      _starOffEnabledAt = DateTime.now().add(const Duration(milliseconds: 500));
      _favoriteHoverDelayTimer = Timer(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        setState(() {});
      });
    }

    await _clickController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    final isFavorite = ref.watch(
      favoriteAgentsProvider
          .select((favorites) => favorites.contains(agent.type)),
    );
    final showStar = isFavorite || _isTileHovered;
    final canShowStarOff = isFavorite &&
        _isStarHovered &&
        DateTime.now().isAfter(_starOffEnabledAt);
    final iconData = canShowStarOff
        ? LucideIcons.starOff
        : (isFavorite ? Icons.star_rounded : LucideIcons.star);
    final iconSize = iconData == Icons.star_rounded ? 18.5 : 16.0;
    final iconColor = isFavorite
        ? (canShowStarOff ? const Color(0xFFE53935) : const Color(0xFFFF9800))
        : (_isStarHovered ? const Color(0xFFFF9800) : const Color(0xFF9AA0A6));

    return IgnorePointer(
      ignoring: ref.watch(dragNotifier) == true,
      child: Draggable(
        data: agent,
        onDragStarted: () {
          if (ref.read(interactionStateProvider) == InteractionState.drawing ||
              ref.read(interactionStateProvider) == InteractionState.erasing) {
            ref
                .read(interactionStateProvider.notifier)
                .update(InteractionState.navigation);
          }
          ref.read(dragNotifier.notifier).updateDragState(true);
        },
        onDraggableCanceled: (velocity, offset) {
          ref.read(dragNotifier.notifier).updateDragState(false);
        },
        onDragCompleted: () {
          ref.read(dragNotifier.notifier).updateDragState(false);
        },
        feedback: Opacity(
          opacity: Settings.feedbackOpacity,
          child: ZoomTransform(child: AgentFeedback(agent: agent)),
        ),
        dragAnchorStrategy: (draggable, context, position) {
          final agentSize = CoordinateSystem.instance
              .scale(ref.watch(strategySettingsProvider).agentSize);
          return Offset(
            (agentSize / 2),
            (agentSize / 2),
          ).scale(ref.read(screenZoomProvider), ref.read(screenZoomProvider));
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _isTileHovered = true),
          onExit: (_) {
            setState(() {
              _isTileHovered = false;
              _isStarHovered = false;
            });
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              InkWell(
                mouseCursor: SystemMouseCursors.click,
                onTap: () {
                  ref.read(abilityBarProvider.notifier).updateData(agent);
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ColoredBox(
                    color: (ref.watch(abilityBarProvider) != null &&
                            ref.watch(abilityBarProvider)!.type == agent.type)
                        ? Settings.tacticalVioletTheme.primary
                        : Settings.tacticalVioletTheme.secondary,
                    child: Image.asset(
                      agent.iconPath,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 130),
                  curve: Curves.easeOutCubic,
                  opacity: showStar ? 1 : 0,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _isStarHovered = true),
                    onExit: (_) => setState(() {
                      _isStarHovered = false;
                      _isStarPressed = false;
                    }),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (_) => setState(() => _isStarPressed = true),
                      onTapUp: (_) => setState(() => _isStarPressed = false),
                      onTapCancel: () => setState(() => _isStarPressed = false),
                      onTap: () => _toggleFavoriteWithFeedback(
                        type: agent.type,
                        wasFavorite: isFavorite,
                      ),
                      child: AnimatedBuilder(
                        animation: _clickController,
                        builder: (context, child) {
                          final pressScale = _isStarPressed ? 0.88 : 1.0;
                          return Transform.scale(
                            scale: pressScale * _clickScale.value,
                            child: child,
                          );
                        },
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 120),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                          child: SizedBox.square(
                            key: ValueKey("${isFavorite}_$canShowStarOff"),
                            dimension: 18,
                            child: Center(
                              child: Icon(
                                iconData,
                                size: iconSize,
                                color: iconColor,
                                shadows: [
                                  BoxShadow(
                                    color: Colors.black.withAlpha(100),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
