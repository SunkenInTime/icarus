import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class FolderPill extends ConsumerStatefulWidget {
  const FolderPill({
    super.key,
    required this.folder,
    this.isDemo = false,
  });

  final Folder folder;
  final bool isDemo;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _FolderPillState();
}

class _FolderPillState extends ConsumerState<FolderPill>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  bool _isHovered = false;
  final ShadContextMenuController _contextMenuController =
      ShadContextMenuController();
  final ShadContextMenuController _rightClickMenuController =
      ShadContextMenuController();
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
    super.dispose();
  }

  Color get _folderColor =>
      widget.folder.customColor ??
      Folder.folderColorMap[widget.folder.color] ??
      Colors.grey;

  @override
  Widget build(BuildContext context) {
    return Draggable<GridItem>(
      feedback: _buildDragFeedback(),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      data: FolderItem(widget.folder),
      child: DragTarget<GridItem>(
        onWillAcceptWithDetails: (details) {
          final item = details.data;
          if (widget.isDemo) return false;
          if (item is FolderItem) {
            return item.folder.id != widget.folder.id &&
                !_isParentFolder(item.folder.id);
          }
          return true;
        },
        onAcceptWithDetails: (details) {
          if (widget.isDemo) return;
          final item = details.data;
          if (item is StrategyItem) {
            ref.read(strategyProvider.notifier).moveToFolder(
                strategyID: item.strategy.id, parentID: widget.folder.id);
          } else if (item is FolderItem) {
            ref.read(folderProvider.notifier).moveToFolder(
                folderID: item.folder.id, parentID: widget.folder.id);
          }
        },
        builder: (context, candidateData, rejectedData) {
          final isDropTarget = candidateData.isNotEmpty;
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
              items: _buildMenuItems(),
              child: GestureDetector(
                onTap: () {
                  if (widget.isDemo) return;
                  ref.read(folderProvider.notifier).updateID(widget.folder.id);
                },
                child: AnimatedBuilder(
                  animation: _scaleAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _scaleAnimation.value,
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.only(left: 14, right: 6),
                        decoration: BoxDecoration(
                          color: _folderColor,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                            color: isDropTarget
                                ? Colors.white
                                : (_isHovered
                                    ? Colors.white.withValues(alpha: 0.5)
                                    : Colors.white.withValues(alpha: 0.15)),
                            width: isDropTarget ? 2 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _folderColor.withValues(alpha: 0.3),
                              blurRadius: _isHovered ? 8 : 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              widget.folder.icon,
                              color: Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 140),
                              child: Text(
                                widget.folder.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            _buildMenuButton(),
                          ],
                        ),
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

  Widget _buildMenuButton() {
    return ShadContextMenuRegion(
      controller: _contextMenuController,
      items: _buildMenuItems(),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _contextMenuController.toggle();
        },
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: Icon(
            Icons.more_vert,
            color: Colors.white.withValues(alpha: 0.8),
            size: 18,
          ),
        ),
      ),
    );
  }

  List<ShadContextMenuItem> _buildMenuItems() {
    return [
      ShadContextMenuItem(
        leading: const Icon(Icons.text_fields),
        child: const Text('Edit'),
        onPressed: () async {
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
          await ref
              .read(strategyProvider.notifier)
              .exportFolder(widget.folder.id);
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(Icons.delete, color: Colors.redAccent),
        child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        onPressed: () async {
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
    return Opacity(
      opacity: 0.9,
      child: Material(
        color: Colors.transparent,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _folderColor,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.folder.icon,
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
        ),
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
