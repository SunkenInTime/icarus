import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/dialogs/strategy/delete_strategy_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/rename_strategy_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class StrategyTile extends ConsumerStatefulWidget {
  const StrategyTile({super.key, required this.strategyData});

  final StrategyData strategyData;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _StrategyTileState();
}

class _StrategyTileState extends ConsumerState<StrategyTile> {
  Color _highlightColor = Settings.tacticalVioletTheme.border;
  bool _isLoading = false;

  final ShadPopoverController _menuController = ShadPopoverController();
  final ShadContextMenuController _contextMenuController =
      ShadContextMenuController();

  @override
  void dispose() {
    _menuController.dispose();
    _contextMenuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewData = StrategyTileViewData(widget.strategyData);

    return Draggable<GridItem>(
      data: StrategyItem(widget.strategyData),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Opacity(
        opacity: 0.95,
        child: Material(
          color: Colors.transparent,
          child: StrategyTileDragPreview(data: viewData),
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) =>
            setState(() => _highlightColor = Settings.tacticalVioletTheme.ring),
        onExit: (_) => setState(
            () => _highlightColor = Settings.tacticalVioletTheme.border),
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
                          assetPath: viewData.thumbnailAsset,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(child: StrategyTileDetails(data: viewData)),
                    ],
                  ),
                ),
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
                        icon: const Icon(
                          Icons.more_vert_outlined,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<ShadContextMenuItem> _buildMenuItems() {
    return [
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.pencil),
        child: const Text('Rename'),
        onPressed: () => _showRenameDialog(),
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.copy),
        child: const Text('Duplicate'),
        onPressed: () => _duplicateStrategy(),
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.upload),
        child: const Text('Export'),
        onPressed: () => _exportStrategy(),
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.trash2, color: Colors.redAccent),
        child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        onPressed: () => _showDeleteDialog(),
      ),
    ];
  }

  Future<void> _openStrategy(BuildContext context) async {
    log('StrategyTile: opening strategy');
    if (_isLoading) {
      log('StrategyTile: already loading');
      return;
    }

    setState(() => _isLoading = true);
    _showLoadingOverlay();

    try {
      await ref
          .read(strategyProvider.notifier)
          .loadFromHive(widget.strategyData.id);
      if (!mounted) return;
      Navigator.pop(context);
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
    } catch (error, stackTrace) {
      log('Error loading strategy: $error', stackTrace: stackTrace);
      if (mounted) {
        Navigator.pop(context);
      }
    } finally {
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
        .duplicateStrategy(widget.strategyData.id);
  }

  Future<void> _exportStrategy() async {
    await ref
        .read(strategyProvider.notifier)
        .loadFromHive(widget.strategyData.id);
    await ref
        .read(strategyProvider.notifier)
        .exportFile(widget.strategyData.id);
  }

  Future<void> _showRenameDialog() async {
    await showShadDialog<void>(
      context: context,
      builder: (_) => RenameStrategyDialog(
        strategyId: widget.strategyData.id,
        currentName: widget.strategyData.name,
      ),
    );
  }

  void _showDeleteDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => DeleteStrategyAlertDialog(
        strategyID: widget.strategyData.id,
        name: widget.strategyData.name,
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}
