import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
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
    return Material(
      color: Colors.transparent,
      child: ShadPopover(
        controller: _controller,
        anchor: ShadGlobalAnchor(widget.globalPosition),
        useSameGroupIdForChild: false,
        popover: (_) {
          return Container(
            key: const ValueKey('lineup-stack-selector'),
            constraints: const BoxConstraints(minWidth: 120, maxWidth: 180),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, candidate) in widget.candidates.indexed)
                  MouseRegion(
                    onEnter: (_) {
                      ref.read(hoveredLineUpTargetProvider.notifier).setHoveredItem(
                            groupId: candidate.groupId,
                            itemId: candidate.itemId,
                            ownerToken: _hoverOwnerToken,
                          );
                    },
                    onExit: (_) {
                      ref
                          .read(hoveredLineUpTargetProvider.notifier)
                          .clearIfOwned(_hoverOwnerToken);
                    },
                    child: ShadButton.raw(
                      key: ValueKey(
                        'lineup-stack-option-${candidate.groupId}-${candidate.itemId}',
                      ),
                      variant: ShadButtonVariant.ghost,
                      width: double.infinity,
                      mainAxisAlignment: MainAxisAlignment.start,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      onPressed: () => _selectCandidate(candidate),
                      child: Row(
                        spacing: 8,
                        children: [
                          Text('${index + 1}'),
                          Image.asset(
                            candidate.ability.data.iconPath,
                            width: 18,
                            height: 18,
                            fit: BoxFit.contain,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
        child: const SizedBox.expand(),
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

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ShadContextMenu(
        controller: _controller,
        anchor: ShadGlobalAnchor(widget.globalPosition),
        items: widget.items,
        child: const SizedBox.expand(),
      ),
    );
  }
}
