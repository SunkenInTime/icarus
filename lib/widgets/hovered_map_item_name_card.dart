import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/hovered_map_item_name_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';

class HoveredMapItemNameCard extends ConsumerStatefulWidget {
  const HoveredMapItemNameCard({super.key});

  @override
  ConsumerState<HoveredMapItemNameCard> createState() =>
      _HoveredMapItemNameCardState();
}

class _HoveredMapItemNameCardState
    extends ConsumerState<HoveredMapItemNameCard> {
  static const Duration _hideDelay = Duration(milliseconds: 125);

  Timer? _hideTimer;
  String? _visibleName;
  int _visibleNameVersion = 0;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  String? _resolveLineUpName(WidgetRef ref, HoveredLineUpTarget target) {
    LineUpGroup? group;
    for (final candidate in ref.watch(lineUpProvider).groups) {
      if (candidate.id == target.groupId) {
        group = candidate;
        break;
      }
    }
    if (group == null) {
      return null;
    }

    if (target.kind == LineUpHoverKind.item && target.itemId != null) {
      LineUpItem? item;
      for (final candidate in group.items) {
        if (candidate.id == target.itemId) {
          item = candidate;
          break;
        }
      }
      return item?.ability.data.name;
    }

    return AgentData.agents[group.agent.type]?.name;
  }

  String? _resolveHoveredName(WidgetRef ref) {
    final lineUpTarget = ref.watch(hoveredLineUpTargetProvider);
    if (lineUpTarget != null) {
      return _resolveLineUpName(ref, lineUpTarget);
    }

    final hoveredTarget = ref.watch(hoveredDeleteTargetProvider);
    if (hoveredTarget == null) {
      return ref.watch(hoveredMapItemNameProvider);
    }

    switch (hoveredTarget.type) {
      case DeleteTargetType.agent:
        for (final agent in ref.watch(agentProvider)) {
          if (agent.id == hoveredTarget.id) {
            return AgentData.agents[agent.type]?.name;
          }
        }
        return null;
      case DeleteTargetType.ability:
        for (final ability in ref.watch(abilityProvider)) {
          if (ability.id == hoveredTarget.id) {
            return ability.data.name;
          }
        }
        return null;
      case DeleteTargetType.lineup:
        for (final group in ref.watch(lineUpProvider).groups) {
          if (group.id == hoveredTarget.id) {
            return AgentData.agents[group.agent.type]?.name;
          }
        }
        return null;
      case DeleteTargetType.text:
      case DeleteTargetType.image:
      case DeleteTargetType.utility:
        return ref.watch(hoveredMapItemNameProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _resolveHoveredName(ref);
    final isScreenshot = ref.watch(screenshotProvider);
    final nextName = isScreenshot ? null : name?.trim();
    if (nextName != null && nextName.isNotEmpty) {
      _hideTimer?.cancel();
      _hideTimer = null;
      if (_visibleName != nextName) {
        _visibleNameVersion++;
        _visibleName = nextName;
      }
    } else if (_visibleName != null && _hideTimer == null) {
      _hideTimer = Timer(_hideDelay, () {
        if (!mounted) return;
        setState(() {
          _visibleName = null;
          _hideTimer = null;
        });
      });
    }

    final visibleName = _visibleName;
    final shouldShow = visibleName != null && visibleName.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 16),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 120),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        child: shouldShow
            ? IntrinsicWidth(
                key: ValueKey('hovered-map-item-$_visibleNameVersion'),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    maxWidth: 160,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Settings.abilityBGColor,
                      borderRadius: const BorderRadius.all(Radius.circular(4)),
                      border: Border.all(
                        color: Settings.tacticalVioletTheme.border,
                        width: 2,
                      ),
                      boxShadow: const [Settings.cardForegroundBackdrop],
                    ),
                    child: Text(
                      visibleName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: Settings.tacticalVioletTheme.foreground,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
              )
            : const SizedBox(
                key: ValueKey('empty-hovered-map-item-name'),
                height: 0,
                width: 0,
              ),
      ),
    );
  }
}
