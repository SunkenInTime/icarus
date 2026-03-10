import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/dialogs/strategy/temporary_session_flow.dart';
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
  static const EdgeInsets _displayMargin = EdgeInsets.all(16);
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
      final canProceed = await resolveTemporarySessionForNavigation(
        context: context,
        ref: ref,
      );
      if (!canProceed) return;
      final latestState = ref.read(strategyProvider);
      // Keep current work persisted before switching strategies.
      if (latestState.stratName != null &&
          !latestState.isTemporarySession &&
          !latestState.isSaved) {
        await ref
            .read(strategyProvider.notifier)
            .forceSaveNow(latestState.id);
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

  Future<void> _startTemporaryCopy() async {
    if (_isSwitching || _isEditingName) return;
    await ref
        .read(strategyProvider.notifier)
        .startTemporaryCopyFromCurrentStrategy();
  }

  void _handleNameFocusChange() {
    if (_nameFocusNode.hasFocus || !_isEditingName) return;
    _commitEditingName();
  }

  void _startEditingName() {
    final currentStrategy = ref.read(strategyProvider);
    final currentName = currentStrategy.stratName;
    if (_isSwitching ||
        _isEditingName ||
        currentName == null ||
        currentStrategy.isTemporarySession) {
      return;
    }

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
        .where(
          (strategy) =>
              strategy.id != currentStrategyId &&
              !StrategyProvider.isTemporaryStrategyId(strategy.id),
        )
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

  Color? _sessionAccentColor(StrategyState strategy) {
    if (strategy.isQuickBoard) return Settings.quickBoardAccent;
    if (strategy.isTemporaryCopy) return Settings.tempCopyAccent;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final currentStrategy = ref.watch(strategyProvider);
    final strategyName = currentStrategy.stratName ?? 'Untitled Strategy';
    final displayName = currentStrategy.isQuickBoard
        ? 'Quick Board'
        : strategyName;
    final strategiesBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final accentColor = _sessionAccentColor(currentStrategy);

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
                                        onTap: _isSwitching || _isEditingName
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
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    width: _barWidth,
                    decoration: BoxDecoration(
                      color: Settings.tacticalVioletTheme.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: accentColor?.withValues(alpha: 0.5)
                            ?? Settings.tacticalVioletTheme.border,
                      ),
                    ),
                    child: Row(
                      children: [
                        if (currentStrategy.isTemporarySession) ...[
                          const SizedBox(width: 10),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: accentColor,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: accentColor!.withValues(alpha: 0.5),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ],
                        Expanded(
                          child: _isEditingName
                          ? Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Shortcuts(
                                shortcuts: <ShortcutActivator, Intent>{
                                  ...ShortcutInfo.textEditingOverrides,
                                  const SingleActivator(
                                    LogicalKeyboardKey.escape,
                                  ): const DismissIntent(),
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
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                        horizontal: 0,
                                        vertical: 8,
                                      ),
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
                            )
                          : Tooltip(
                              message: currentStrategy.stratName == null
                                  ? 'Load a strategy to rename it'
                                  : currentStrategy.isTemporarySession
                                      ? 'Rename is disabled in draft mode'
                                      : 'Rename strategy',
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: currentStrategy.stratName == null
                                          || currentStrategy.isTemporarySession
                                      ? null
                                      : _startEditingName,
                                  mouseCursor: currentStrategy.stratName == null
                                          || currentStrategy.isTemporarySession
                                      ? SystemMouseCursors.basic
                                      : SystemMouseCursors.click,
                                  borderRadius: BorderRadius.circular(8),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      displayName,
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
                        Container(
                          width: 1,
                          height: 30,
                          color: accentColor?.withValues(alpha: 0.3)
                              ?? Settings.tacticalVioletTheme.border,
                        ),
                        SizedBox(
                          width: 38,
                          child: ShadIconButton.ghost(
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
                                    size: 16,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!currentStrategy.isTemporarySession) ...[
                    const SizedBox(width: 8),
                    _DraftCopyButton(
                      onPressed: currentStrategy.stratName == null
                          ? null
                          : _startTemporaryCopy,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DraftCopyButton extends StatefulWidget {
  const _DraftCopyButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  State<_DraftCopyButton> createState() => _DraftCopyButtonState();
}

class _DraftCopyButtonState extends State<_DraftCopyButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isEnabled = widget.onPressed != null;
    const accent = Settings.tempCopyAccent;

    return MouseRegion(
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: ShadTooltip(
          builder: (context) =>
              const Text('Create an editable draft copy of this strategy'),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _isHovered && isEnabled
                  ? accent.withValues(alpha: 0.12)
                  : Settings.tacticalVioletTheme.secondary,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isHovered && isEnabled
                    ? accent.withValues(alpha: 0.4)
                    : Settings.tacticalVioletTheme.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.penLine,
                  size: 14,
                  color: _isHovered && isEnabled
                      ? accent
                      : Colors.white.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 6),
                Text(
                  'Draft Copy',
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: _isHovered && isEnabled
                            ? accent
                            : Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
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
