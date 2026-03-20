import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/dialogs/strategy/delete_strategy_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/rename_strategy_dialog.dart';
import 'package:icarus/widgets/library_models.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class StrategyTile extends ConsumerStatefulWidget {
  const StrategyTile({
    super.key,
    required this.strategyId,
    required this.currentName,
    required this.data,
    this.canRename = true,
    this.canDuplicate = true,
    this.canExport = true,
    this.canDelete = true,
    this.enableDrag = true,
  });

  final String strategyId;
  final String currentName;
  final LibraryStrategyItemData data;
  final bool canRename;
  final bool canDuplicate;
  final bool canExport;
  final bool canDelete;
  final bool enableDrag;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _StrategyTileState();
}

class _StrategyTileState extends ConsumerState<StrategyTile> {
  Color _highlightColor = Settings.tacticalVioletTheme.border;
  bool _isLoading = false;

  final ShadContextMenuController _contextMenuController =
      ShadContextMenuController();

  @override
  void dispose() {
    _contextMenuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) =>
          setState(() => _highlightColor = Settings.tacticalVioletTheme.ring),
      onExit: (_) =>
          setState(() => _highlightColor = Settings.tacticalVioletTheme.border),
      child: AbsorbPointer(
        absorbing: _isLoading,
        child: GestureDetector(
          onTap: () => _openStrategy(context),
          child: Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                decoration: BoxDecoration(
                  color: ShadTheme.of(context).colorScheme.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _highlightColor, width: 2),
                ),
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    Expanded(
                      child: StrategyTileThumbnail(
                        assetPath: widget.data.thumbnailAsset,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(child: StrategyTileDetails(data: widget.data)),
                  ],
                ),
              ),
              if (_buildMenuItems().isNotEmpty)
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ShadContextMenuRegion(
                      controller: _contextMenuController,
                      items: _buildMenuItems(),
                      child: ShadIconButton.secondary(
                        width: 28,
                        height: 28,
                        onPressed: () {
                          _contextMenuController.toggle();
                        },
                        icon: const Icon(Icons.more_vert_outlined),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (!widget.enableDrag) {
      return child;
    }

    return Draggable<LibraryDragItem>(
      data: StrategyDragItem(widget.strategyId),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Opacity(
        opacity: 0.95,
        child: Material(
          color: Colors.transparent,
          child: StrategyTileDragPreview(data: widget.data),
        ),
      ),
      child: child,
    );
  }

  List<ShadContextMenuItem> _buildMenuItems() {
    final items = <ShadContextMenuItem>[];
    if (widget.canRename) {
      items.add(
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.pencil),
          child: const Text('Rename'),
          onPressed: () => _showRenameDialog(),
        ),
      );
    }
    if (widget.canDuplicate) {
      items.add(
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.copy),
          child: const Text('Duplicate'),
          onPressed: () => _duplicateStrategy(),
        ),
      );
    }
    if (widget.canExport) {
      items.add(
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.upload),
          child: const Text('Export'),
          onPressed: () => _exportStrategy(),
        ),
      );
    }
    if (widget.canDelete) {
      items.add(
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.trash2, color: Colors.redAccent),
          child:
              const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          onPressed: () => _showDeleteDialog(),
        ),
      );
    }
    return items;
  }

  Future<void> _openStrategy(BuildContext context) async {
    log('StrategyTile: opening strategy ${widget.strategyId}');
    if (_isLoading) {
      return;
    }

    setState(() => _isLoading = true);
    _showLoadingOverlay();
    var dismissedOverlay = false;

    try {
      await ref.read(strategyProvider.notifier).openStrategy(widget.strategyId);
      if (!context.mounted) {
        return;
      }
      Navigator.pop(context);
      dismissedOverlay = true;
      await Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (context, animation, _) => const StrategyView(),
          transitionsBuilder: (context, animation, _, child) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.9, end: 1.0)
                    .chain(CurveTween(curve: Curves.easeOut))
                    .animate(animation),
                child: child,
              ),
            );
          },
        ),
      );
    } finally {
      if (!dismissedOverlay && context.mounted) {
        Navigator.pop(context);
      }
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showLoadingOverlay() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
  }

  Future<void> _duplicateStrategy() async {
    await ref
        .read(strategyProvider.notifier)
        .duplicateStrategy(widget.strategyId);
  }

  Future<void> _exportStrategy() async {
    await ref.read(strategyProvider.notifier).exportStrategy(widget.strategyId);
  }

  Future<void> _showRenameDialog() async {
    await showShadDialog<void>(
      context: context,
      builder: (_) => RenameStrategyDialog(
        strategyId: widget.strategyId,
        currentName: widget.currentName,
      ),
    );
  }

  void _showDeleteDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => DeleteStrategyAlertDialog(
        strategyID: widget.strategyId,
        name: widget.currentName,
      ),
    );
  }
}
