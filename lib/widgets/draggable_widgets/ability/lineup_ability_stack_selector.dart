import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

Future<LineUpAbilityStackCandidate?> showLineUpAbilityStackSelector({
  required BuildContext context,
  required Offset globalPosition,
  required List<LineUpAbilityStackCandidate> candidates,
}) {
  return showGeneralDialog<LineUpAbilityStackCandidate?>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close lineup ability stack selector',
    barrierColor: Colors.transparent,
    pageBuilder: (context, animation, secondaryAnimation) {
      return _LineUpAbilityStackSelectorDialog(
        globalPosition: globalPosition,
        candidates: candidates,
      );
    },
  );
}

Future<void> showLineUpAbilityContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required List<ShadContextMenuItem> items,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close lineup ability context menu',
    barrierColor: Colors.transparent,
    pageBuilder: (context, animation, secondaryAnimation) {
      return _LineUpAbilityContextMenuDialog(
        globalPosition: globalPosition,
        items: items,
      );
    },
  );
}

class _LineUpAbilityStackSelectorDialog extends ConsumerStatefulWidget {
  const _LineUpAbilityStackSelectorDialog({
    required this.globalPosition,
    required this.candidates,
  });

  final Offset globalPosition;
  final List<LineUpAbilityStackCandidate> candidates;

  @override
  ConsumerState<_LineUpAbilityStackSelectorDialog> createState() =>
      _LineUpAbilityStackSelectorDialogState();
}

class _LineUpAbilityStackSelectorDialogState
    extends ConsumerState<_LineUpAbilityStackSelectorDialog> {
  final ShadPopoverController _controller = ShadPopoverController();
  final Object _hoverOwnerToken = Object();
  LineUpAbilityStackCandidate? _selectedCandidate;
  ProviderContainer? _container;
  bool _didCloseRoute = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controller.show();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    _container
        ?.read(hoveredLineUpTargetProvider.notifier)
        .clearIfOwned(_hoverOwnerToken);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (_controller.isOpen || _didCloseRoute || !mounted) {
      return;
    }

    _didCloseRoute = true;
    _container
        ?.read(hoveredLineUpTargetProvider.notifier)
        .clearIfOwned(_hoverOwnerToken);
    Navigator.of(context).pop(_selectedCandidate);
  }

  void _selectCandidate(LineUpAbilityStackCandidate candidate) {
    _selectedCandidate = candidate;
    if (_didCloseRoute || !mounted) {
      return;
    }

    _didCloseRoute = true;
    _container
        ?.read(hoveredLineUpTargetProvider.notifier)
        .clearIfOwned(_hoverOwnerToken);
    Navigator.of(context).pop(candidate);
  }

  @override
  Widget build(BuildContext context) {
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final contentPadding = EdgeInsets.all(
      (abilitySize * 0.24).clamp(4.0, 10.0),
    );
    final indexStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontSize: abilitySize * 0.68,
          fontWeight: FontWeight.w600,
          height: 1.0,
        );

    return Material(
      color: Colors.transparent,
      child: ShadPopover(
        controller: _controller,
        anchor: ShadGlobalAnchor(widget.globalPosition),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        useSameGroupIdForChild: false,
        child: const SizedBox.expand(),
        popover: (_) {
          return IntrinsicWidth(
            child: Container(
              key: const ValueKey('lineup-stack-selector'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (index, candidate) in widget.candidates.indexed)
                    _LineUpStackSelectorOption(
                      key: ValueKey(
                        'lineup-stack-option-${candidate.groupId}-${candidate.itemId}',
                      ),
                      index: index,
                      candidate: candidate,
                      abilitySize: abilitySize,
                      indexStyle: indexStyle,
                      contentPadding: contentPadding,
                      onSelect: () => _selectCandidate(candidate),
                      onHoverLineUpEnter: () {
                        ref
                            .read(hoveredLineUpTargetProvider.notifier)
                            .setHoveredItem(
                              groupId: candidate.groupId,
                              itemId: candidate.itemId,
                              ownerToken: _hoverOwnerToken,
                            );
                      },
                      onHoverLineUpExit: () {
                        ref
                            .read(hoveredLineUpTargetProvider.notifier)
                            .clearIfOwned(_hoverOwnerToken);
                      },
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LineUpStackSelectorOption extends StatefulWidget {
  const _LineUpStackSelectorOption({
    super.key,
    required this.index,
    required this.candidate,
    required this.abilitySize,
    required this.indexStyle,
    required this.contentPadding,
    required this.onSelect,
    required this.onHoverLineUpEnter,
    required this.onHoverLineUpExit,
  });

  final int index;
  final LineUpAbilityStackCandidate candidate;
  final double abilitySize;
  final TextStyle? indexStyle;
  final EdgeInsetsGeometry contentPadding;
  final VoidCallback onSelect;
  final VoidCallback onHoverLineUpEnter;
  final VoidCallback onHoverLineUpExit;

  @override
  State<_LineUpStackSelectorOption> createState() =>
      _LineUpStackSelectorOptionState();
}

class _LineUpStackSelectorOptionState
    extends State<_LineUpStackSelectorOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ringColor = ShadTheme.of(context).colorScheme.ring;
    final gap = (widget.abilitySize * 0.2).clamp(4.0, 8.0);

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHoverLineUpEnter();
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.onHoverLineUpExit();
      },
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onSelect,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: widget.contentPadding,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _hovered ? ringColor : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: gap,
            children: [
              Text('${widget.index + 1}', style: widget.indexStyle),
              Image.asset(
                widget.candidate.ability.data.iconPath,
                width: widget.abilitySize,
                height: widget.abilitySize,
                fit: BoxFit.contain,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LineUpAbilityContextMenuDialog extends StatefulWidget {
  const _LineUpAbilityContextMenuDialog({
    required this.globalPosition,
    required this.items,
  });

  final Offset globalPosition;
  final List<ShadContextMenuItem> items;

  @override
  State<_LineUpAbilityContextMenuDialog> createState() =>
      _LineUpAbilityContextMenuDialogState();
}

class _LineUpAbilityContextMenuDialogState
    extends State<_LineUpAbilityContextMenuDialog> {
  final ShadContextMenuController _controller = ShadContextMenuController();
  bool _didCloseRoute = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controller.show();
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (_controller.isOpen || _didCloseRoute || !mounted) {
      return;
    }

    _didCloseRoute = true;
    Navigator.of(context).pop();
  }

  void _closeRouteIfNeeded() {
    if (_didCloseRoute || !mounted) {
      return;
    }

    _didCloseRoute = true;
    Navigator.of(context).pop();
  }

  ShadContextMenuItem _wrapItem(ShadContextMenuItem item) {
    return ShadContextMenuItem.raw(
      key: item.key,
      variant: item.variant,
      items: [
        for (final nested in item.items)
          if (nested is ShadContextMenuItem) _wrapItem(nested) else nested,
      ],
      enabled: item.enabled,
      leading: item.leading,
      trailing: item.trailing,
      leadingPadding:
          item.leadingPadding ?? const EdgeInsetsDirectional.only(end: 6),
      trailingPadding:
          item.trailingPadding ?? const EdgeInsetsDirectional.only(start: 6),
      padding: item.padding ?? EdgeInsets.zero,
      insetPadding:
          item.insetPadding ?? const EdgeInsets.symmetric(horizontal: 4),
      onPressed: () {
        _closeRouteIfNeeded();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          item.onPressed?.call();
        });
      },
      anchor: item.anchor,
      showDelay: item.showDelay,
      height: item.height,
      buttonVariant: item.buttonVariant,
      decoration: item.decoration,
      textStyle: item.textStyle,
      trailingTextStyle: item.trailingTextStyle,
      constraints: item.constraints ?? const BoxConstraints(minWidth: 0),
      subMenuPadding: item.subMenuPadding,
      backgroundColor: item.backgroundColor,
      selectedBackgroundColor: item.selectedBackgroundColor,
      closeOnTap: true,
      child: item.child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ShadContextMenu(
        controller: _controller,
        anchor: ShadGlobalAnchor(widget.globalPosition),
        constraints: const BoxConstraints(minWidth: 0),
        padding: const EdgeInsets.symmetric(vertical: 4),
        items: [
          for (final item in widget.items) _wrapItem(item),
        ],
        child: const SizedBox.expand(),
      ),
    );
  }
}
