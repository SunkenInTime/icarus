import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/settings.dart';
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

class _FolderPillState extends ConsumerState<FolderPill> {
  bool _isHovered = false;
  final ShadContextMenuController _contextMenuController =
      ShadContextMenuController();
  final ShadContextMenuController _rightClickMenuController =
      ShadContextMenuController();

  @override
  void dispose() {
    _contextMenuController.dispose();
    _rightClickMenuController.dispose();
    super.dispose();
  }

  Color get _folderColor =>
      widget.folder.customColor ??
      Folder.folderColorMap[widget.folder.color] ??
      Colors.grey;

  String get _metadataLabel {
    if (widget.isDemo) return 'Folder preview';

    final strategyCount = widget.strategyCount ?? 0;
    final folderCount = widget.folderCount ?? 0;

    if (strategyCount == 0 && folderCount == 0) return 'Empty';

    final parts = <String>[];
    if (strategyCount > 0) {
      parts.add(
        '$strategyCount ${strategyCount == 1 ? 'strat' : 'strats'}',
      );
    }
    if (folderCount > 0) {
      parts.add('$folderCount ${folderCount == 1 ? 'folder' : 'folders'}');
    }
    return parts.join(' / ');
  }

  String get _createdLabel {
    final difference = DateTime.now().difference(widget.folder.dateCreated);
    if (difference.inMinutes < 1) return 'Created now';
    if (difference.inHours < 1) return 'Created ${difference.inMinutes}m ago';
    if (difference.inDays < 1) return 'Created ${difference.inHours}h ago';
    if (difference.inDays < 30) return 'Created ${difference.inDays}d ago';
    final months = (difference.inDays / 30).floor();
    return 'Created ${months}mo ago';
  }

  Color _readableFolderColor() {
    if (widget.folder.color == FolderColor.generic &&
        widget.folder.customColor == null) {
      return Settings.tacticalVioletTheme.primary;
    }

    final hsl = HSLColor.fromColor(_folderColor);
    if (hsl.lightness < 0.34) {
      return hsl.withLightness(0.66).withSaturation(0.68).toColor();
    }
    if (hsl.lightness > 0.78) {
      return hsl.withLightness(0.62).withSaturation(0.72).toColor();
    }
    return _folderColor;
  }

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
                  strategyID: item.strategy.id,
                  parentID: widget.folder.id,
                );
          } else if (item is FolderItem) {
            ref.read(folderProvider.notifier).moveToFolder(
                  folderID: item.folder.id,
                  parentID: widget.folder.id,
                );
          }
        },
        builder: (context, candidateData, rejectedData) {
          final isDropTarget = candidateData.isNotEmpty;
          return MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            cursor: SystemMouseCursors.click,
            child: ShadContextMenuRegion(
              controller: _rightClickMenuController,
              items: _buildMenuItems(),
              child: GestureDetector(
                onTap: () {
                  if (widget.isDemo) return;
                  ref.read(folderProvider.notifier).updateID(widget.folder.id);
                },
                child: _buildFolderCard(
                  context: context,
                  isDropTarget: isDropTarget,
                  showMenu: true,
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
      child: ShadIconButton.secondary(
        width: 28,
        height: 28,
        onPressed: () {
          _contextMenuController.toggle();
        },
        icon: Icon(
          Icons.more_vert_outlined,
          color:
              Settings.tacticalVioletTheme.foreground.withValues(alpha: 0.82),
          size: 18,
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
          if (widget.isDemo) return;
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
        child: _buildFolderCard(
          context: context,
          isDropTarget: true,
          showMenu: false,
          isDragging: true,
        ),
      ),
    );
  }

  Widget _buildFolderCard({
    required BuildContext context,
    required bool isDropTarget,
    required bool showMenu,
    bool isDragging = false,
  }) {
    final colorScheme = ShadTheme.of(context).colorScheme;
    final folderAccent = _readableFolderColor();
    final borderColor = isDropTarget
        ? Settings.tacticalVioletTheme.primary
        : (_isHovered || isDragging
            ? Settings.tacticalVioletTheme.ring
            : Settings.tacticalVioletTheme.border);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      width: 196,
      height: 116,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _FolderObjectPainter(
                surfaceColor: isDropTarget
                    ? Color.alphaBlend(
                        Settings.tacticalVioletTheme.primary
                            .withValues(alpha: 0.08),
                        colorScheme.card,
                      )
                    : colorScheme.card,
                accentColor: folderAccent,
                borderColor: borderColor,
                borderWidth: isDropTarget ? 2 : 1,
                elevated: isDragging || _isHovered,
              ),
            ),
          ),
          Positioned(
            left: 16,
            top: 27,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: folderAccent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: folderAccent.withValues(alpha: 0.34),
                ),
              ),
              child: Center(
                child: FolderIconView(
                  iconId: widget.folder.iconId,
                  color: folderAccent,
                  size: 24,
                ),
              ),
            ),
          ),
          Positioned(
            left: 70,
            right: showMenu ? 42 : 16,
            top: 30,
            child: Text(
              widget.folder.name.isEmpty ? 'New Folder' : widget.folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Positioned(
            left: 70,
            right: 16,
            top: 54,
            child: Text(
              _metadataLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Settings.tacticalVioletTheme.mutedForeground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 15,
            child: Row(
              children: [
                Container(
                  constraints: const BoxConstraints(maxWidth: 112),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color:
                        Settings.tacticalVioletTheme.background.withValues(
                      alpha: 0.48,
                    ),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: Settings.tacticalVioletTheme.border,
                    ),
                  ),
                  child: Text(
                    _createdLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Settings.tacticalVioletTheme.mutedForeground,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: (_isHovered || isDropTarget || isDragging)
                      ? Settings.tacticalVioletTheme.primary
                      : Settings.tacticalVioletTheme.mutedForeground
                          .withValues(alpha: 0.62),
                  size: 17,
                ),
              ],
            ),
          ),
          if (showMenu)
            Positioned(
              top: 25,
              right: 12,
              child: _buildMenuButton(),
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

class _FolderObjectPainter extends CustomPainter {
  const _FolderObjectPainter({
    required this.surfaceColor,
    required this.accentColor,
    required this.borderColor,
    required this.borderWidth,
    required this.elevated,
  });

  final Color surfaceColor;
  final Color accentColor;
  final Color borderColor;
  final double borderWidth;
  final bool elevated;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _folderPath(size);

    if (elevated) {
      canvas.drawShadow(path, Colors.black.withValues(alpha: 0.54), 5, true);
    }

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = surfaceColor;
    canvas.drawPath(path, fillPaint);

    final accentPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = accentColor.withValues(alpha: 0.2);
    canvas.drawPath(_tabAccentPath(size), accentPaint);

    final bevelPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.05);
    canvas.drawPath(_innerBevelPath(size), bevelPaint);

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeJoin = StrokeJoin.round
      ..color = borderColor;
    canvas.drawPath(path, strokePaint);
  }

  Path _folderPath(Size size) {
    final width = size.width;
    final height = size.height;
    const top = 8.0;
    const bodyTop = 24.0;
    const radius = 14.0;
    const tabWidth = 86.0;

    return Path()
      ..moveTo(radius, top)
      ..quadraticBezierTo(0, top, 0, top + radius)
      ..lineTo(0, height - radius)
      ..quadraticBezierTo(0, height, radius, height)
      ..lineTo(width - radius, height)
      ..quadraticBezierTo(width, height, width, height - radius)
      ..lineTo(width, bodyTop + radius)
      ..quadraticBezierTo(width, bodyTop, width - radius, bodyTop)
      ..lineTo(tabWidth + 11, bodyTop)
      ..cubicTo(tabWidth + 2, bodyTop, tabWidth - 5, top, tabWidth - 18, top)
      ..close();
  }

  Path _tabAccentPath(Size size) {
    const top = 8.0;
    const bodyTop = 24.0;
    const radius = 14.0;
    const tabWidth = 86.0;

    return Path()
      ..moveTo(radius, top)
      ..quadraticBezierTo(0, top, 0, top + radius)
      ..lineTo(0, bodyTop + 8)
      ..lineTo(tabWidth + 10, bodyTop + 8)
      ..cubicTo(tabWidth + 4, bodyTop + 2, tabWidth - 4, top, tabWidth - 18, top)
      ..close();
  }

  Path _innerBevelPath(Size size) {
    const bodyTop = 24.0;
    return Path()
      ..moveTo(10, bodyTop + 10)
      ..lineTo(size.width - 10, bodyTop + 10);
  }

  @override
  bool shouldRepaint(covariant _FolderObjectPainter oldDelegate) {
    return oldDelegate.surfaceColor != surfaceColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.borderWidth != borderWidth ||
        oldDelegate.elevated != elevated;
  }
}
