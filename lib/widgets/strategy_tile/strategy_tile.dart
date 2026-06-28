import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/dialogs/strategy/delete_strategy_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/rename_strategy_dialog.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class StrategyTile extends ConsumerStatefulWidget {
  const StrategyTile.local({
    super.key,
    required this.strategyData,
  })  : cloudStrategy = null,
        canRename = true,
        canDuplicate = true,
        canDelete = true,
        canMove = true;

  const StrategyTile.cloud({
    super.key,
    required this.cloudStrategy,
    required this.canRename,
    required this.canDuplicate,
    required this.canDelete,
    required this.canMove,
  }) : strategyData = null;

  final StrategyData? strategyData;
  final CloudStrategySummary? cloudStrategy;
  final bool canRename;
  final bool canDuplicate;
  final bool canDelete;
  final bool canMove;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _StrategyTileState();
}

class _StrategyTileState extends ConsumerState<StrategyTile> {
  Color _highlightColor = Settings.tacticalVioletTheme.border;
  bool _isLoading = false;

  final ShadContextMenuController _menuButtonController =
      ShadContextMenuController();
  final ShadContextMenuController _rightClickMenuController =
      ShadContextMenuController();

  bool get _isCloud => widget.cloudStrategy != null;
  bool get _canShare => _isCloud && widget.cloudStrategy?.role == 'owner';
  String get _strategyId =>
      widget.strategyData?.id ?? widget.cloudStrategy!.publicId;
  String get _strategyName =>
      widget.strategyData?.name ?? widget.cloudStrategy!.name;
  MapValue? get _mapValue {
    final strategy = widget.strategyData;
    if (strategy != null) return strategy.mapData;

    final mapData = widget.cloudStrategy?.mapData;
    if (mapData == null) return null;
    for (final entry in Maps.mapNames.entries) {
      if (entry.value == mapData) return entry.key;
    }
    return null;
  }

  bool get _isAttack {
    final strategy = widget.strategyData;
    if (strategy != null) {
      return strategy.pages.isEmpty ? true : strategy.pages.first.isAttack;
    }
    return widget.cloudStrategy?.attackLabel != 'Defend';
  }

  StrategyTileViewData get _viewData => widget.strategyData != null
      ? StrategyTileViewData.fromStrategy(widget.strategyData!)
      : StrategyTileViewData.fromCloudSummary(widget.cloudStrategy!);

  @override
  void dispose() {
    _menuButtonController.dispose();
    _rightClickMenuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewData = _viewData;

    return Draggable<GridItem>(
      data: _isCloud
          ? StrategyItem.cloud(_strategyId)
          : StrategyItem.local(widget.strategyData!),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: widget.canMove ? null : 0,
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
          child: ShadContextMenuRegion(
            controller: _rightClickMenuController,
            items: _buildMenuItems(),
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
                        controller: _menuButtonController,
                        items: _buildMenuItems(),
                        child: ShadIconButton.secondary(
                          width: 28,
                          height: 28,
                          onPressed: () {
                            _menuButtonController.toggle();
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
        ),
      ),
    );
  }

  List<ShadContextMenuItem> _buildMenuItems() {
    return [
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.pencil),
        onPressed: widget.canRename ? () => _showRenameDialog() : null,
        child: const Text('Rename'),
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.copy),
        onPressed: widget.canDuplicate ? () => _duplicateStrategy() : null,
        child: const Text('Duplicate'),
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.upload),
        onPressed: () => _exportStrategy(),
        child: const Text('Export'),
      ),
      if (_canShare)
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.link2),
          onPressed: _showShareDialog,
          child: const Text('Share'),
        ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.trash2, color: Colors.redAccent),
        onPressed: widget.canDelete ? () => _showDeleteDialog() : null,
        child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
      ),
    ];
  }

  Future<void> _openStrategy(BuildContext context) async {
    if (_isLoading) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (!context.mounted) return;
      await Navigator.push(
        context,
        StrategyView.route(
          initialStrategyId: _strategyId,
          initialStrategyName: _strategyName,
          initialStrategySource:
              _isCloud ? StrategySource.cloud : StrategySource.local,
          initialMapValue: _mapValue,
          initialIsAttack: _isAttack,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _duplicateStrategy() async {
    await ref.read(strategyProvider.notifier).duplicateStrategy(
          _strategyId,
          source: _isCloud ? StrategySource.cloud : StrategySource.local,
        );
  }

  Future<void> _exportStrategy() async {
    if (kIsWeb) {
      Settings.showToast(
        message: 'This feature is only supported in the Windows version.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    if (_isCloud) {
      await StrategyImportExportService(ref).exportCloudStrategy(_strategyId);
      return;
    }

    await ref.read(strategyProvider.notifier).loadFromHive(_strategyId);
    await StrategyImportExportService(ref).exportFile(_strategyId);
  }

  Future<void> _showRenameDialog() async {
    await showShadDialog<void>(
      context: context,
      builder: (_) => RenameStrategyDialog(
        strategyId: _strategyId,
        currentName: _strategyName,
        source: _isCloud ? StrategySource.cloud : StrategySource.local,
      ),
    );
  }

  Future<void> _showShareDialog() async {
    await showShadDialog<void>(
      context: context,
      builder: (_) => ShareLinksDialog(
        targetType: 'strategy',
        targetPublicId: _strategyId,
        title: _strategyName,
      ),
    );
  }

  void _showDeleteDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => DeleteStrategyAlertDialog(
        strategyID: _strategyId,
        name: _strategyName,
        source: _isCloud ? StrategySource.cloud : StrategySource.local,
      ),
    );
  }
}
