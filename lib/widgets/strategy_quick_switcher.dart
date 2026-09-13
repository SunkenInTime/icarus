import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/widgets/overflow_tooltip_text.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Displays the current strategy name with a recent-strategies dropdown.
class StrategyQuickSwitcher extends ConsumerStatefulWidget {
  const StrategyQuickSwitcher({super.key});

  @override
  ConsumerState<StrategyQuickSwitcher> createState() =>
      _StrategyQuickSwitcherState();
}

class _StrategyQuickSwitcherState extends ConsumerState<StrategyQuickSwitcher> {
  static const double _barWidth = 280;
  static const double _barHeight = 30;
  static const double _barRadius = 8;
  static const double _chevronWidth = 38;
  // Menu geometry, matching the library strip's popovers.
  static const double _menuRadius = 12;
  static const double _menuInset = 6;
  static const double _rowInset = 6;
  static const EdgeInsets _displayMargin = EdgeInsets.symmetric(horizontal: 16);
  final OverlayPortalController _controller = OverlayPortalController();
  final LayerLink _layerLink = LayerLink();
  late final TextEditingController _nameController;
  late final FocusNode _nameFocusNode;
  bool _isOpen = false;
  bool _isSwitching = false;
  bool _isEditingName = false;
  bool _isRenaming = false;
  String? _originalName;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _nameFocusNode = FocusNode()..addListener(_handleNameFocusChange);
  }

  @override
  void dispose() {
    _nameFocusNode
      ..removeListener(_handleNameFocusChange)
      ..dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _openPortal() {
    if (_isEditingName) return;
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
    if (_isSwitching || _isEditingName) return;
    final currentStrategy = ref.read(strategyProvider);
    if (currentStrategy.id == strategyId) return;

    _closePortal();
    setState(() => _isSwitching = true);

    try {
      await guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'StrategyQuickSwitcher.switchStrategy',
        onContinue: () async {
          ref
              .read(interactionStateProvider.notifier)
              .update(InteractionState.navigation);
          ref
              .read(agentFilterProvider.notifier)
              .updateFilterState(FilterState.all);
          await ref.read(strategyProvider.notifier).loadFromHive(strategyId);
        },
      );
    } finally {
      if (mounted) {
        setState(() => _isSwitching = false);
      }
    }
  }

  void _handleNameFocusChange() {
    if (_nameFocusNode.hasFocus || !_isEditingName) return;
    _commitEditingName();
  }

  void _startEditingName() {
    final currentStrategy = ref.read(strategyProvider);
    final currentName = currentStrategy.stratName;
    if (_isSwitching || _isEditingName || currentName == null) return;

    _closePortal();
    _originalName = currentName;
    _nameController.value = TextEditingValue(
      text: currentName,
      selection: TextSelection(baseOffset: 0, extentOffset: currentName.length),
    );
    setState(() => _isEditingName = true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isEditingName) return;
      _nameFocusNode.requestFocus();
      _nameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _nameController.text.length,
      );
    });
  }

  void _cancelEditingName() {
    final originalName = _originalName;
    if (originalName != null) {
      _nameController.text = originalName;
    }

    _originalName = null;
    setState(() {
      _isEditingName = false;
      _isRenaming = false;
    });
    _nameFocusNode.unfocus();
  }

  Future<void> _commitEditingName() async {
    if (!_isEditingName || _isRenaming) return;

    final nextName = _nameController.text.trim();
    final originalName = _originalName ?? '';
    if (nextName == originalName) {
      _originalName = null;
      setState(() => _isEditingName = false);
      _nameFocusNode.unfocus();
      return;
    }

    if (nextName.isEmpty) {
      Settings.showToast(
        message: 'Strategy name cannot be empty.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_isEditingName) return;
        _nameFocusNode.requestFocus();
        _nameController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _nameController.text.length,
        );
      });
      return;
    }

    setState(() => _isRenaming = true);
    try {
      await ref
          .read(strategyProvider.notifier)
          .renameStrategy(ref.read(strategyProvider).id, nextName);
      if (!mounted) return;
      _originalName = null;
      setState(() {
        _isEditingName = false;
        _isRenaming = false;
      });
      _nameFocusNode.unfocus();
    } catch (_) {
      if (!mounted) rethrow;
      setState(() => _isRenaming = false);
      rethrow;
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
    final currentStrategyId = currentStrategy.id;
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
              currentStrategyId: currentStrategyId,
            );

            return OverlayPortal.overlayChildLayoutBuilder(
              controller: _controller,
              overlayChildBuilder: (context, layoutInfo) {
                final childRect = MatrixUtils.transformRect(
                  layoutInfo.childPaintTransform,
                  Offset.zero & layoutInfo.childSize,
                );
                final maxLeft = math.max(
                  0.0,
                  layoutInfo.overlaySize.width - _barWidth,
                );
                final left = childRect.left.clamp(0.0, maxLeft).toDouble();
                final top = childRect.bottom + 6;
                final maxHeight = math.max(
                  0.0,
                  math.min(280.0, layoutInfo.overlaySize.height - top - 8),
                );
                return Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _closePortal,
                      ),
                    ),
                    Positioned(
                      left: left,
                      top: top,
                      width: _barWidth,
                      // A floating menu like the library strip's: popover
                      // grey, hairline border, panel radius, one shadow. The
                      // rows inside are flat.
                      child: Container(
                        constraints: BoxConstraints(maxHeight: maxHeight),
                        decoration: BoxDecoration(
                          color: Settings.tacticalVioletTheme.popover,
                          borderRadius: BorderRadius.circular(_menuRadius),
                          border: Border.all(
                            color: Settings.tacticalVioletTheme.border,
                          ),
                          boxShadow: const [Settings.floatingMenuShadow],
                        ),
                        child: recents.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  _menuInset + _rowInset,
                                  _menuInset + 6,
                                  _menuInset + _rowInset,
                                  _menuInset + 6,
                                ),
                                child: Text(
                                  'No recent strategies',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Settings
                                        .tacticalVioletTheme.mutedForeground,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                shrinkWrap: true,
                                padding: const EdgeInsets.all(_menuInset),
                                itemCount: recents.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 2),
                                itemBuilder: (context, index) {
                                  final strategy = recents[index];
                                  final attackLabel = _attackLabel(strategy);
                                  final mapName = _mapName(strategy);
                                  final thumbnail =
                                      'assets/maps/thumbnails/${Maps.mapNames[strategy.mapData]}_thumbnail.webp';
                                  return _StrategyQuickSwitchItem(
                                    strategyName: strategy.name,
                                    mapName: mapName,
                                    attackLabel: attackLabel,
                                    attackColor: _attackColor(attackLabel),
                                    lastEdited: _timeAgo(strategy.lastEdited),
                                    thumbnailPath: thumbnail,
                                    onTap: _isSwitching || _isEditingName
                                        ? null
                                        : () => _switchStrategy(strategy.id),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                );
              },
              // A two-segment control. The children are clipped to the
              // bar's inner rounded rect, so each segment's hover fill runs
              // edge to edge and the bar's own corners round it off.
              child: Container(
                key: const ValueKey('strategy-quick-switcher-control'),
                width: _barWidth,
                height: _barHeight,
                decoration: BoxDecoration(
                  color: Settings.tacticalVioletTheme.card,
                  borderRadius: BorderRadius.circular(_barRadius),
                  border: Border.all(
                    color: Settings.tacticalVioletTheme.border,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  children: [
                    Expanded(
                      child: _isEditingName
                          ? Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Center(
                                child: TextEditingShortcutScope(
                                  extraShortcuts: const <ShortcutActivator,
                                      Intent>{
                                    SingleActivator(
                                      LogicalKeyboardKey.enter,
                                    ): EnterTextIntent(),
                                    SingleActivator(
                                      LogicalKeyboardKey.escape,
                                    ): DismissIntent(),
                                  },
                                  child: Actions(
                                    actions: <Type, Action<Intent>>{
                                      EnterTextIntent:
                                          CallbackAction<EnterTextIntent>(
                                        onInvoke: (_) {
                                          _commitEditingName();
                                          return null;
                                        },
                                      ),
                                      DismissIntent:
                                          CallbackAction<DismissIntent>(
                                        onInvoke: (_) {
                                          _cancelEditingName();
                                          return null;
                                        },
                                      ),
                                    },
                                    child: TextField(
                                      controller: _nameController,
                                      focusNode: _nameFocusNode,
                                      enabled: !_isRenaming,
                                      textAlign: TextAlign.center,
                                      textInputAction: TextInputAction.done,
                                      cursorColor:
                                          Settings.tacticalVioletTheme.primary,
                                      style: ShadTheme.of(context)
                                          .textTheme
                                          .small
                                          .copyWith(color: Colors.white),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                        border: InputBorder.none,
                                        hintText: 'Untitled Strategy',
                                        hintStyle: ShadTheme.of(context)
                                            .textTheme
                                            .small
                                            .copyWith(color: Colors.white54),
                                      ),
                                      onSubmitted: (_) => _commitEditingName(),
                                      onTapOutside: (_) {
                                        _nameFocusNode.unfocus();
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : ShadTooltip(
                              builder: (context) => Text(
                                currentStrategy.stratName == null
                                    ? 'Load a strategy to rename it'
                                    : 'Rename strategy',
                              ),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: currentStrategy.stratName == null
                                      ? null
                                      : _startEditingName,
                                  mouseCursor: currentStrategy.stratName == null
                                      ? SystemMouseCursors.basic
                                      : SystemMouseCursors.click,
                                  hoverColor:
                                      Settings.tacticalVioletTheme.accent,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Text(
                                        strategyName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: ShadTheme.of(context)
                                            .textTheme
                                            .small
                                            .copyWith(color: Colors.white),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                    Container(
                      width: 1,
                      color: Settings.tacticalVioletTheme.border,
                    ),
                    SizedBox(
                      width: _chevronWidth,
                      child: ShadIconButton.ghost(
                        width: _chevronWidth,
                        height: double.infinity,
                        padding: EdgeInsets.zero,
                        decoration: const ShadDecoration(
                          border: ShadBorder(radius: BorderRadius.zero),
                        ),
                        onPressed: _isSwitching || _isEditingName
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
                                    ? LucideIcons.chevronUp
                                    : LucideIcons.chevronDown,
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
  static const double _rowHeight = 40;
  static const double _thumbnail = 28;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    // A flat menu row: thumbnail, name over map, side over time. Hover is
    // the ghost button's grey fill; nothing here is bordered or shadowed.
    return ShadButton.ghost(
      height: _rowHeight,
      expands: true,
      mainAxisAlignment: MainAxisAlignment.start,
      padding: const EdgeInsets.symmetric(
        horizontal: _StrategyQuickSwitcherState._rowInset,
      ),
      gap: 10,
      onPressed: widget.onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.asset(
          widget.thumbnailPath,
          width: _thumbnail,
          height: _thumbnail,
          fit: BoxFit.cover,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                OverflowTooltipText(
                  widget.strategyName,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    color: theme.foreground,
                  ),
                ),
                Text(
                  widget.mapName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    color: theme.mutedForeground,
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
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  color: widget.attackColor,
                ),
              ),
              Text(
                widget.lastEdited,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  color: theme.mutedForeground,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
