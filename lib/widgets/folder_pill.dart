import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/library_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class FolderPill extends ConsumerStatefulWidget {
  const FolderPill({
    super.key,
    required this.data,
    this.isDemo = false,
    this.enableDragAndDrop = true,
    this.onOpen,
    this.onEdit,
    this.onExport,
    this.onDelete,
  });

  final LibraryFolderItemData data;
  final bool isDemo;
  final bool enableDragAndDrop;
  final VoidCallback? onOpen;
  final VoidCallback? onEdit;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _FolderPillState();
}

class _FolderPillState extends ConsumerState<FolderPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final Animation<double> _scaleAnimation;
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
    _contextMenuController.dispose();
    _rightClickMenuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildInteractiveContent();
    if (!widget.enableDragAndDrop || widget.isDemo) {
      return content;
    }

    return Draggable<LibraryDragItem>(
      feedback: _buildDragFeedback(),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      data: FolderDragItem(widget.data.id),
      child: DragTarget<LibraryDragItem>(
        onWillAcceptWithDetails: (details) {
          final item = details.data;
          if (item is FolderDragItem) {
            return item.id != widget.data.id;
          }
          return true;
        },
        onAcceptWithDetails: (details) {
          final item = details.data;
          if (item is StrategyDragItem) {
            ref.read(strategyProvider.notifier).moveToFolder(
                  strategyID: item.id,
                  parentID: widget.data.id,
                );
          } else if (item is FolderDragItem) {
            ref.read(folderProvider.notifier).moveToFolder(
                  folderID: item.id,
                  parentID: widget.data.id,
                );
          }
        },
        builder: (context, candidateData, rejectedData) {
          return _buildInteractiveContent(
            isDropTarget: candidateData.isNotEmpty,
          );
        },
      ),
    );
  }

  Widget _buildInteractiveContent({bool isDropTarget = false}) {
    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _animationController.forward();
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        _animationController.reverse();
      },
      cursor: widget.onOpen == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: ShadContextMenuRegion(
        controller: _rightClickMenuController,
        items: _buildMenuItems(),
        child: GestureDetector(
          onTap: widget.isDemo ? null : widget.onOpen,
          child: AnimatedBuilder(
            animation: _scaleAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _scaleAnimation.value,
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.only(left: 14, right: 6),
                  decoration: BoxDecoration(
                    color: widget.data.backgroundColor,
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
                        color:
                            widget.data.backgroundColor.withValues(alpha: 0.3),
                        blurRadius: _isHovered ? 8 : 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.data.icon,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 140),
                        child: Text(
                          widget.data.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_buildMenuItems().isNotEmpty) ...[
                        const SizedBox(width: 4),
                        _buildMenuButton(),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
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
          padding: const EdgeInsets.all(4),
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
    final items = <ShadContextMenuItem>[];

    if (widget.onEdit != null) {
      items.add(
        ShadContextMenuItem(
          leading: const Icon(Icons.text_fields),
          onPressed: widget.onEdit,
          child: const Text('Edit'),
        ),
      );
    }

    if (widget.onExport != null) {
      items.add(
        ShadContextMenuItem(
          leading: const Icon(Icons.file_upload),
          onPressed: widget.onExport,
          child: const Text('Export'),
        ),
      );
    }

    if (widget.onDelete != null) {
      items.add(
        ShadContextMenuItem(
          leading: const Icon(Icons.delete, color: Colors.redAccent),
          onPressed: widget.onDelete,
          child:
              const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        ),
      );
    }

    return items;
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
            color: widget.data.backgroundColor,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.data.icon,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Text(
                widget.data.name,
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
}
