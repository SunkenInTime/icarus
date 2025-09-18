// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/custom_folder_painter.dart';
import 'package:icarus/widgets/dialogs/custom_alert_dialog.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';

class FolderTile extends ConsumerStatefulWidget {
  const FolderTile({
    super.key,
    required this.folder,
    this.isDemo = false,
  });
  final Folder folder;
  final bool isDemo;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _FolderTileState();
}

class _FolderTileState extends ConsumerState<FolderTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Color?> _colorAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _colorAnimation = ColorTween(
      begin: const Color(0xffD2D6DB).withAlpha((255.0 * 0.102).round()),
      end: Colors.deepPurpleAccent,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(2.0),
      child: AspectRatio(
        aspectRatio: 558 / 445,
        child: Draggable<GridItem>(
          feedback: _buildDragFeedback(),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          data: FolderItem(widget.folder),
          child: GestureDetector(
            onTap: () {
              if (widget.isDemo) return;
              ref.read(folderProvider.notifier).updateID(widget.folder.id);
            },
            child: MouseRegion(
              onEnter: (_) {
                _animationController.forward();
              },
              onExit: (_) {
                _animationController.reverse();
              },
              cursor: SystemMouseCursors.click,
              child: DragTarget<GridItem>(
                onWillAccept: (data) {
                  if (widget.isDemo) return false;

                  // Prevent self-drop and prevent dropping parent into child
                  if (data is FolderItem) {
                    return data.folder.id != widget.folder.id &&
                        !_isParentFolder(data.folder.id);
                  }
                  return true; // Allow strategies
                },
                builder: (context, candidateData, rejectedData) {
                  return AnimatedBuilder(
                    animation: _colorAnimation,
                    builder: (context, child) {
                      return Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: CustomFolderPainter(
                                strokeColor: _colorAnimation.value ??
                                    Settings.highlightColor,
                                backgroundColor: widget.folder.customColor ??
                                    Folder.folderColorMap[widget.folder.color]!,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                SizedBox(
                                  height: 102,
                                  width: 102,
                                  child: Icon(
                                    widget.folder.icon,
                                    size: 102,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Padding(
                                  padding: const EdgeInsets.all(14.0),
                                  child: Container(
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1A161A),
                                      borderRadius: const BorderRadius.all(
                                          Radius.circular(24)),
                                      border: Border.all(
                                          color: Settings.highlightColor,
                                          width: 1),
                                    ),
                                    child: Center(
                                      child: Text(
                                        widget.folder.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              ],
                            ),
                          ),
                          Positioned(
                            right: 0,
                            top: 36,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8.0),
                              child: MenuAnchor(
                                menuChildren: [
                                  MenuItemButton(
                                    onPressed: () async {
                                      if (widget.isDemo) return;

                                      await showDialog<String>(
                                        context: context,
                                        builder: (context) {
                                          return FolderEditDialog(
                                            folder: widget.folder,
                                          );
                                        },
                                      );
                                      // await showDialog(
                                      //   context: context,
                                      //   builder: (context) {
                                      //     return RenameStrategyDialog(
                                      //       strategyId: widget.strategyData.id,
                                      //       currentName: widget.strategyData.name,
                                      //     );
                                      //   },
                                      // );

                                      // await ref.read(strategyProvider.notifier).
                                    },
                                    child: const Row(
                                      children: [
                                        Icon(
                                          Icons.text_fields,
                                        ),
                                        SizedBox(
                                          width: 2,
                                        ),
                                        Text(
                                          "Edit",
                                        )
                                      ],
                                    ),
                                  ),
                                  MenuItemButton(
                                    onPressed: () async {
                                      ConfirmAlertDialog.show(
                                              context: context,
                                              title:
                                                  "Are you sure you want to delete '${widget.folder.name}' folder?",
                                              content:
                                                  "This will also delete all strategies and subfolders within it.",
                                              confirmText: "Delete",
                                              isDestructive: true)
                                          .then((confirmed) {
                                        if (confirmed) {
                                          if (widget.isDemo) return;

                                          ref
                                              .read(folderProvider.notifier)
                                              .deleteFolder(widget.folder.id);
                                        }
                                      });
                                    },
                                    child: const Row(
                                      children: [
                                        Icon(
                                          Icons.delete,
                                          color: Colors.redAccent,
                                        ),
                                        SizedBox(
                                          width: 2,
                                        ),
                                        Text(
                                          "Delete",
                                          style: TextStyle(
                                              color: Colors.redAccent),
                                        )
                                      ],
                                    ),
                                  ),
                                ],
                                builder: (context, controller, child) {
                                  return IconButton(
                                    onPressed: () {
                                      if (controller.isOpen) {
                                        controller.close();
                                      } else {
                                        controller.open();
                                      }
                                    },
                                    icon: const Icon(
                                      Icons.more_vert_outlined,
                                      shadows: [Shadow(blurRadius: 8)],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
                onAccept: (data) {
                  if (widget.isDemo) return;

                  if (data is StrategyItem) {
                    // Move strategy to this folder
                    ref.read(strategyProvider.notifier).moveToFolder(
                        strategyID: data.strategy.id,
                        parentID: widget.folder.id);
                  } else if (data is FolderItem) {
                    // Move folder to this folder

                    ref.read(folderProvider.notifier).moveToFolder(
                        folderID: data.folder.id, parentID: widget.folder.id);
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

// Add these helper methods:
  Widget _buildDragFeedback() {
    return Opacity(
      opacity: 0.8,
      child: Material(
        color: Colors.transparent,
        child: Container(
          height: 50,
          width: 220,
          decoration: BoxDecoration(
            color: Settings.sideBarColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.deepPurpleAccent, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: Row(
              children: [
                Icon(Icons.folder,
                    size: 36,
                    color: widget.folder.customColor ??
                        (widget.folder.color == FolderColor.generic
                            ? Colors.white
                            : Folder.folderColorMap[widget.folder.color])),
                const SizedBox(width: 14),
                Text(
                  widget.folder.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isParentFolder(String folderId) {
    // Check if the dragged folder is a parent of this folder
    // to prevent circular references
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
