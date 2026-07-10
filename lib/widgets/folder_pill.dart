import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_context_menu_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/drag_tilt_feedback.dart';
import 'package:icarus/widgets/drop_insertion_indicator.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/overflow_tooltip_text.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _folderPillCornerRadius = 8;
const double _folderPillMenuButtonRadius = 6;

class FolderPill extends ConsumerStatefulWidget {
  const FolderPill({
    super.key,
    required this.folder,
    this.isDemo = false,
    this.strategyCount,
    this.folderCount,
  });

  final Folder folder;
  final bool isDemo;
  final int? strategyCount;
  final int? folderCount;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _FolderPillState();
}

class _FolderPillState extends ConsumerState<FolderPill>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  bool _isHovered = false;
  bool _isMenuButtonHovered = false;
  bool _menuButtonWasOpenOnPointerDown = false;
  DropInsertionSide? _pinnedDropSide;
  final ShadContextMenuController _contextMenuController =
      ShadContextMenuController();
  final ShadContextMenuController _rightClickMenuController =
      ShadContextMenuController();
  final DragTiltController _dragTiltController = DragTiltController();
  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.03,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    _contextMenuController.dispose();
    _rightClickMenuController.dispose();
    super.dispose();
  }

  void _closeMenus() {
    _contextMenuController.hide();
    _rightClickMenuController.hide();
  }

  void _handleMenuButtonPressed() {
    if (_menuButtonWasOpenOnPointerDown) {
      _menuButtonWasOpenOnPointerDown = false;
      _closeMenus();
      return;
    }

    dismissLibraryContextMenus(ref);
    _contextMenuController.show();
  }

  Color get _folderColor =>
      widget.folder.customColor ??
      Folder.folderColorMap[widget.folder.color] ??
      Colors.grey;

  bool _isPinnedFolderReorderCandidate(
    GridItem item,
    Map<String, int> pinned,
    String id,
    bool isPinned,
  ) {
    return item is FolderItem &&
        item.folder.id != id &&
        isPinned &&
        pinned.containsKey(item.folder.id);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      libraryContextMenuDismissalProvider,
      (_, __) => _closeMenus(),
    );

    final pinned = ref.watch(pinnedItemsProvider);
    final id = widget.folder.id;
    final isPinned = pinned.containsKey(id);

    return Draggable<GridItem>(
      feedback: TiltDragFeedback(
        controller: _dragTiltController,
        opacity: 0.9,
        child: _buildDragFeedback(),
      ),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragUpdate: (details) => _dragTiltController.addDelta(details.delta.dx),
      data: FolderItem(widget.folder),
      child: DragTarget<GridItem>(
        onWillAcceptWithDetails: (details) {
          final item = details.data;
          if (widget.isDemo) return false;
          if (item is FolderItem) {
            return item.folder.id != id && !_isParentFolder(item.folder.id);
          }
          return true;
        },
        onMove: (details) {
          final item = details.data;
          final nextSide =
              _isPinnedFolderReorderCandidate(item, pinned, id, isPinned)
                  ? resolveDropInsertionSide(
                      context: context,
                      globalOffset: details.offset,
                      current: _pinnedDropSide,
                    )
                  : null;
          if (nextSide != _pinnedDropSide) {
            setState(() => _pinnedDropSide = nextSide);
          }
        },
        onLeave: (_) {
          if (_pinnedDropSide != null) {
            setState(() => _pinnedDropSide = null);
          }
        },
        onAcceptWithDetails: (details) async {
          if (widget.isDemo) return;
          final item = details.data;
          if (item is FolderItem &&
              item.folder.id != id &&
              isPinned &&
              pinned.containsKey(item.folder.id)) {
            final insertionSide = _pinnedDropSide ??
                resolveDropInsertionSide(
                  context: context,
                  globalOffset: details.offset,
                );
            if (mounted) {
              setState(() => _pinnedDropSide = null);
            }
            if (insertionSide == null) return;

            await ref.read(pinnedItemsProvider.notifier).movePin(
                  id: item.folder.id,
                  targetId: id,
                  insertAfterTarget: insertionSide == DropInsertionSide.after,
                );
            return;
          }

          if (item is StrategyItem) {
            ref.read(strategyProvider.notifier).moveToFolder(
                strategyID: item.strategy.id, parentID: widget.folder.id);
          } else if (item is FolderItem) {
            ref.read(folderProvider.notifier).moveToFolder(
                folderID: item.folder.id, parentID: widget.folder.id);
          }
        },
        builder: (context, candidateData, rejectedData) {
          final isPinnedDropTarget = candidateData.any(
            (item) =>
                item is FolderItem &&
                item.folder.id != id &&
                isPinned &&
                pinned.containsKey(item.folder.id),
          );
          final isDropTarget = candidateData.isNotEmpty;
          final isMoveIntoFolderTarget = isDropTarget && !isPinnedDropTarget;
          final isHoverActive = _isHovered && !isPinnedDropTarget;
          return MouseRegion(
            onEnter: (_) {
              setState(() => _isHovered = true);
              _animationController.forward();
            },
            onExit: (_) {
              setState(() => _isHovered = false);
              _animationController.reverse();
            },
            cursor: SystemMouseCursors.click,
            child: ShadContextMenuRegion(
              controller: _rightClickMenuController,
              items: _buildMenuItems(isPinned: isPinned),
              child: GestureDetector(
                onTap: () {
                  if (widget.isDemo) return;
                  ref.read(folderProvider.notifier).updateID(widget.folder.id);
                },
                child: AnimatedBuilder(
                  animation: _scaleAnimation,
                  builder: (context, child) {
                    final dropSide = _pinnedDropSide;
                    final slotKey = dropSide == null
                        ? null
                        : dropInsertionSlotKey(
                            itemId: id,
                            side: dropSide,
                            pinnedOrder: pinnedIdsInManualOrder(pinned),
                          );
                    return Transform.scale(
                      scale: isPinnedDropTarget ? 1 : _scaleAnimation.value,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            height: 44,
                            padding: const EdgeInsets.only(left: 14, right: 6),
                            decoration: BoxDecoration(
                              color: _folderColor,
                              borderRadius: BorderRadius.circular(
                                  _folderPillCornerRadius),
                              border: Border.all(
                                color: isMoveIntoFolderTarget
                                    ? Colors.white
                                    : (isHoverActive
                                        ? Colors.white.withValues(alpha: 0.5)
                                        : Colors.white.withValues(alpha: 0.15)),
                                width: isMoveIntoFolderTarget ? 2 : 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _folderColor.withValues(alpha: 0.3),
                                  blurRadius: isHoverActive ? 8 : 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FolderIconView(
                                  iconId: widget.folder.iconId,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 140),
                                  child: OverflowTooltipText(
                                    widget.folder.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (isPinned) ...[
                                  const SizedBox(width: 6),
                                  Icon(
                                    Icons.push_pin,
                                    color: Colors.white.withValues(alpha: 0.78),
                                    size: 14,
                                  ),
                                ],
                                const SizedBox(width: 4),
                                _buildMenuButton(isPinned: isPinned),
                              ],
                            ),
                          ),
                          if (dropSide != null && slotKey != null)
                            Positioned.fill(
                              child: DropInsertionIndicator(
                                key: ValueKey(slotKey),
                                slotKey: slotKey,
                                side: dropSide,
                                gap: 18,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMenuButton({required bool isPinned}) {
    final backgroundAlpha = _isMenuButtonHovered ? 0.16 : 0.04;
    final iconAlpha = _isMenuButtonHovered ? 0.96 : 0.74;

    return ShadContextMenuRegion(
      controller: _contextMenuController,
      items: _buildMenuItems(isPinned: isPinned),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isMenuButtonHovered = true),
        onExit: (_) => setState(() => _isMenuButtonHovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: backgroundAlpha),
            borderRadius: BorderRadius.circular(_folderPillMenuButtonRadius),
          ),
          child: Listener(
            onPointerDown: (_) {
              _menuButtonWasOpenOnPointerDown = _contextMenuController.isOpen;
            },
            child: InkWell(
              borderRadius: BorderRadius.circular(_folderPillMenuButtonRadius),
              mouseCursor: SystemMouseCursors.click,
              hoverColor: Colors.transparent,
              splashColor: Colors.white.withValues(alpha: 0.12),
              highlightColor: Colors.white.withValues(alpha: 0.08),
              onTap: _handleMenuButtonPressed,
              child: Icon(
                Icons.more_vert,
                color: Colors.white.withValues(alpha: iconAlpha),
                size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<ShadContextMenuItem> _buildMenuItems({required bool isPinned}) {
    final id = widget.folder.id;
    return [
      ShadContextMenuItem(
        leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined),
        child: Text(isPinned ? 'Unpin' : 'Pin'),
        onPressed: () {
          _closeMenus();
          if (widget.isDemo) return;
          ref.read(pinnedItemsProvider.notifier).togglePin(id);
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(Icons.text_fields),
        child: const Text('Edit'),
        onPressed: () async {
          _closeMenus();
          if (widget.isDemo) return;
          await showDialog<String>(
            context: context,
            builder: (context) {
              return FolderEditDialog(folder: widget.folder);
            },
          );
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(Icons.file_upload),
        child: const Text('Export'),
        onPressed: () async {
          _closeMenus();
          await ref
              .read(strategyProvider.notifier)
              .exportFolder(widget.folder.id);
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(Icons.delete, color: Colors.redAccent),
        child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        onPressed: () async {
          _closeMenus();
          ConfirmAlertDialog.show(
            context: context,
            title:
                "Are you sure you want to delete '${widget.folder.name}' folder?",
            content:
                "This will also delete all strategies and subfolders within it.",
            confirmText: "Delete",
            isDestructive: true,
          ).then((confirmed) {
            if (confirmed) {
              if (widget.isDemo) return;
              ref.read(folderProvider.notifier).deleteFolder(widget.folder.id);
            }
          });
        },
      ),
    ];
  }

  Widget _buildDragFeedback() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _folderColor,
        borderRadius: BorderRadius.circular(_folderPillCornerRadius),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FolderIconView(
            iconId: widget.folder.iconId,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 10),
          Text(
            widget.folder.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  bool _isParentFolder(String folderId) {
    String? currentParentId = widget.folder.parentID;
    while (currentParentId != null) {
      if (currentParentId == folderId) return true;
      final parentFolder =
          ref.read(folderProvider.notifier).findFolderByID(currentParentId);
      currentParentId = parentFolder?.parentID;
    }
    return false;
  }
}
