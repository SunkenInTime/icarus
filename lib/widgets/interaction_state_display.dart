import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Displays the current strategy name with a recent-strategies dropdown.
class InteractionStateDisplay extends ConsumerStatefulWidget {
  const InteractionStateDisplay({super.key});

  @override
  ConsumerState<InteractionStateDisplay> createState() =>
      _InteractionStateDisplayState();
}

class _InteractionStateDisplayState
    extends ConsumerState<InteractionStateDisplay> {
  static const double _barWidth = 280;
  static const EdgeInsets _displayMargin = EdgeInsets.all(16);
  final OverlayPortalController _controller = OverlayPortalController();
  final LayerLink _layerLink = LayerLink();
  bool _isOpen = false;
  bool _isSwitching = false;

  @override
  void dispose() {
    super.dispose();
  }

  void _openPortal() {
    _controller.show();
    setState(() => _isOpen = true);
  }

  void _closePortal() {
    _controller.hide();
    if (_isOpen) {
      setState(() => _isOpen = false);
    }
  }

  Future<void> _switchStrategy(String strategyId) async {
    if (_isSwitching) return;
    final currentStrategy = ref.read(strategyProvider);
    if (currentStrategy.id == strategyId) return;

    _closePortal();
    setState(() => _isSwitching = true);

    try {
      // Keep current work persisted before switching strategies.
      if (currentStrategy.stratName != null) {
        await ref
            .read(strategyProvider.notifier)
            .forceSaveNow(currentStrategy.id);
      }
      ref
          .read(interactionStateProvider.notifier)
          .update(InteractionState.navigation);
      ref.read(agentFilterProvider.notifier).updateFilterState(FilterState.all);
      await ref.read(strategyProvider.notifier).loadFromHive(strategyId);
    } finally {
      if (mounted) {
        setState(() => _isSwitching = false);
      }
    }
  }

  List<StrategyData> _recentStrategies({
    required Box<StrategyData> box,
    required String currentStrategyId,
  }) {
    final strategies = box.values
        .where((strategy) => strategy.id != currentStrategyId)
        .toList(growable: false);
    strategies.sort((a, b) => b.lastEdited.compareTo(a.lastEdited));
    return strategies;
  }

  String _mapName(StrategyData strategy) {
    final raw = Maps.mapNames[strategy.mapData];
    if (raw == null || raw.isEmpty) return 'Unknown';
    return raw[0].toUpperCase() + raw.substring(1);
  }

  String _attackLabel(StrategyData strategy) {
    if (strategy.pages.isEmpty) return 'Unknown';
    final first = strategy.pages.first.isAttack;
    final mixed = strategy.pages.any((page) => page.isAttack != first);
    if (mixed) return 'Mixed';
    return first ? 'Attack' : 'Defend';
  }

  Color _attackColor(String attackLabel) {
    switch (attackLabel) {
      case 'Attack':
        return Colors.redAccent;
      case 'Defend':
        return Colors.lightBlueAccent;
      default:
        return Colors.orangeAccent;
    }
  }

  String _timeAgo(DateTime date) {
    final difference = DateTime.now().difference(date);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) {
      final minutes = difference.inMinutes;
      final plural = minutes == 1 ? '' : 's';
      return '$minutes min$plural ago';
    }
    if (difference.inHours < 24) {
      final hours = difference.inHours;
      final plural = hours == 1 ? '' : 's';
      return '$hours hour$plural ago';
    }
    if (difference.inDays < 30) {
      final days = difference.inDays;
      final plural = days == 1 ? '' : 's';
      return '$days day$plural ago';
    }
    final months = (difference.inDays / 30).floor();
    final plural = months == 1 ? '' : 's';
    return '$months month$plural ago';
  }

  @override
  Widget build(BuildContext context) {
    final currentStrategy = ref.watch(strategyProvider);
    final strategyName = currentStrategy.stratName ?? 'Untitled Strategy';
    final strategiesBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    return Padding(
      padding: _displayMargin,
      child: CompositedTransformTarget(
        link: _layerLink,
        child: ValueListenableBuilder<Box<StrategyData>>(
          valueListenable: strategiesBox.listenable(),
          builder: (context, box, _) {
            final recents = _recentStrategies(
              box: box,
              currentStrategyId: currentStrategy.id,
            );

            return OverlayPortal(
              controller: _controller,
              overlayChildBuilder: (context) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _closePortal,
                      ),
                    ),
                    CompositedTransformFollower(
                      link: _layerLink,
                      targetAnchor: Alignment.bottomLeft,
                      followerAnchor: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Material(
                          color: Colors.transparent,
                          child: Container(
                            width: _barWidth,
                            constraints: const BoxConstraints(maxHeight: 280),
                            decoration: BoxDecoration(
                              color: Settings.tacticalVioletTheme.background,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Settings.tacticalVioletTheme.border,
                              ),
                            ),
                            child: recents.isEmpty
                                ? Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    child: Text(
                                      'No recent strategies',
                                      style: ShadTheme.of(context)
                                          .textTheme
                                          .small
                                          .copyWith(color: Colors.white70),
                                    ),
                                  )
                                : ListView.separated(
                                    shrinkWrap: true,
                                    padding: const EdgeInsets.all(8),
                                    itemCount: recents.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 8),
                                    itemBuilder: (context, index) {
                                      final strategy = recents[index];
                                      final attackLabel =
                                          _attackLabel(strategy);
                                      final mapName = _mapName(strategy);
                                      final thumbnail =
                                          'assets/maps/thumbnails/${Maps.mapNames[strategy.mapData]}_thumbnail.webp';
                                      return _StrategyQuickSwitchItem(
                                        strategyName: strategy.name,
                                        mapName: mapName,
                                        attackLabel: attackLabel,
                                        attackColor: _attackColor(attackLabel),
                                        lastEdited:
                                            _timeAgo(strategy.lastEdited),
                                        thumbnailPath: thumbnail,
                                        onTap: _isSwitching
                                            ? null
                                            : () =>
                                                _switchStrategy(strategy.id),
                                      );
                                    },
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
              child: Container(
                width: _barWidth,
                decoration: BoxDecoration(
                  color: Settings.tacticalVioletTheme.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Settings.tacticalVioletTheme.border,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text(
                          strategyName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: ShadTheme.of(context).textTheme.small.copyWith(
                                color: Colors.white,
                              ),
                        ),
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 30,
                      color: Settings.tacticalVioletTheme.border,
                    ),
                    SizedBox(
                      width: 38,
                      child: ShadIconButton.ghost(
                        onPressed: _isSwitching
                            ? null
                            : () => _isOpen ? _closePortal() : _openPortal(),
                        icon: _isSwitching
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                _isOpen
                                    ? Icons.keyboard_arrow_up
                                    : Icons.keyboard_arrow_down,
                                color: Colors.white,
                                size: 18,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StrategyQuickSwitchItem extends StatefulWidget {
  const _StrategyQuickSwitchItem({
    required this.strategyName,
    required this.mapName,
    required this.attackLabel,
    required this.attackColor,
    required this.lastEdited,
    required this.thumbnailPath,
    this.onTap,
  });

  final String strategyName;
  final String mapName;
  final String attackLabel;
  final Color attackColor;
  final String lastEdited;
  final String thumbnailPath;
  final VoidCallback? onTap;

  @override
  State<_StrategyQuickSwitchItem> createState() =>
      _StrategyQuickSwitchItemState();
}

class _StrategyQuickSwitchItemState extends State<_StrategyQuickSwitchItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isEnabled = widget.onTap != null;
    final borderColor = _isHovered
        ? Settings.tacticalVioletTheme.primary
        : Settings.tacticalVioletTheme.border;
    final backgroundColor = _isHovered
        ? Settings.tacticalVioletTheme.card.withValues(alpha: 0.85)
        : Settings.tacticalVioletTheme.card;

    return MouseRegion(
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
          boxShadow: const [Settings.cardForegroundBackdrop],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(10),
            mouseCursor:
                isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            hoverColor:
                Settings.tacticalVioletTheme.primary.withValues(alpha: 0.12),
            splashColor:
                Settings.tacticalVioletTheme.primary.withValues(alpha: 0.2),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      widget.thumbnailPath,
                      width: 46,
                      height: 46,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.strategyName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ShadTheme.of(context).textTheme.small.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.mapName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ShadTheme.of(context).textTheme.small.copyWith(
                                color: Colors.white70,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.attackLabel,
                        style: ShadTheme.of(context).textTheme.small.copyWith(
                              color: widget.attackColor,
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.lastEdited,
                        style: ShadTheme.of(context).textTheme.small.copyWith(
                              color: Colors.white54,
                            ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
