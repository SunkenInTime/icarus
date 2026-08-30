import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/library_context_menu_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/delete_strategy_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/rename_strategy_dialog.dart';
import 'package:icarus/widgets/drag_tilt_feedback.dart';
import 'package:icarus/widgets/drop_insertion_indicator.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double strategyTileGridSpacing = 20;
const double strategyTileGutterOutset = strategyTileGridSpacing / 2;
const double strategyTileMainAxisExtent = 250;
const double strategyTileGridMainAxisExtent =
    strategyTileMainAxisExtent + strategyTileGridSpacing;
const double strategyTileOuterRadius = 16;
const double strategyTileInnerPadding = 8;
const double strategyTileInnerRadius =
    strategyTileOuterRadius - strategyTileInnerPadding;

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
  final CloudStrategyEntry? cloudStrategy;
  final bool canRename;
  final bool canDuplicate;
  final bool canDelete;
  final bool canMove;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _StrategyTileState();
}

class StrategyTileActionsButton extends StatelessWidget {
  const StrategyTileActionsButton({
    super.key,
    required this.strategyName,
    required this.onPressed,
  });

  final String strategyName;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = 'More actions for $strategyName';
    return Semantics(
      label: label,
      button: true,
      onTap: onPressed,
      excludeSemantics: true,
      child: ShadIconButton.secondary(
        width: 28,
        height: 28,
        onPressed: onPressed,
        icon: const Icon(Icons.more_vert_outlined),
      ),
    );
  }
}

class StrategyTileMenuActionSemantics extends StatelessWidget {
  const StrategyTileMenuActionSemantics({
    super.key,
    required this.label,
    required this.enabled,
    required this.onPressed,
    required this.child,
  });

  final String label;
  final bool enabled;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      enabled: enabled,
      onTap: onPressed,
      excludeSemantics: true,
      child: child,
    );
  }
}

class _StrategyTileState extends ConsumerState<StrategyTile> {
  Color _highlightColor = Settings.tacticalVioletTheme.border;
  bool _isLoading = false;
  bool _menuButtonWasOpenOnPointerDown = false;
  DropInsertionSide? _pinnedDropSide;

  final ShadContextMenuController _menuButtonController =
      ShadContextMenuController();
  final ShadContextMenuController _rightClickMenuController =
      ShadContextMenuController();
  final DragTiltController _dragTiltController = DragTiltController();

  bool get _isCloud => widget.cloudStrategy != null;
  bool get _canShare => _isCloud && widget.cloudStrategy?.role == 'owner';
  String get _strategyId =>
      widget.strategyData?.id ?? widget.cloudStrategy!.strategy.id;
  String get _strategyName =>
      widget.strategyData?.name ?? widget.cloudStrategy!.strategy.name;
  MapValue? get _mapValue =>
      widget.strategyData?.mapData ?? widget.cloudStrategy?.strategy.mapData;
  bool get _isAttack {
    final strategy = widget.strategyData;
    if (strategy != null) {
      return strategy.pages.isEmpty ? true : strategy.pages.first.isAttack;
    }
    return widget.cloudStrategy?.attackLabel != 'Defend';
  }

  StrategyTileViewData get _viewData => widget.strategyData != null
      ? StrategyTileViewData.fromStrategy(widget.strategyData!)
      : StrategyTileViewData.fromCloudEntry(widget.cloudStrategy!);

  @override
  void dispose() {
    _menuButtonController.dispose();
    _rightClickMenuController.dispose();
    super.dispose();
  }

  void _closeMenus() {
    _menuButtonController.hide();
    _rightClickMenuController.hide();
  }

  void _handleMenuButtonPressed() {
    if (_menuButtonWasOpenOnPointerDown) {
      _menuButtonWasOpenOnPointerDown = false;
      _closeMenus();
      return;
    }

    dismissLibraryContextMenus(ref);
    _menuButtonController.show();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      libraryContextMenuDismissalProvider,
      (_, __) => _closeMenus(),
    );

    final viewData = _viewData;
    final pinned = ref.watch(pinnedItemsProvider);
    final id = _strategyId;
    final isPinned = pinned.containsKey(id);

    return DragTarget<GridItem>(
      onWillAcceptWithDetails: (details) {
        final item = details.data;
        return item is StrategyItem &&
            item.strategyId != id &&
            isPinned &&
            pinned.containsKey(item.strategyId);
      },
      onMove: (details) {
        final item = details.data;
        final nextSide = item is StrategyItem &&
                item.strategyId != id &&
                isPinned &&
                pinned.containsKey(item.strategyId)
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
        final item = details.data;
        if (item is! StrategyItem) return;

        // Commit whatever the indicator was showing so the drop always
        // matches what the user saw.
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
              id: item.strategyId,
              targetId: id,
              insertAfterTarget: insertionSide == DropInsertionSide.after,
            );
      },
      builder: (context, candidateData, rejectedData) {
        final isPinDropTarget = candidateData.any(
          (item) =>
              item is StrategyItem &&
              item.strategyId != id &&
              isPinned &&
              pinned.containsKey(item.strategyId),
        );

        return Padding(
          padding: const EdgeInsets.all(strategyTileGutterOutset),
          child: Draggable<GridItem>(
            data: _isCloud
                ? StrategyItem.cloud(_strategyId)
                : StrategyItem.local(widget.strategyData!),
            maxSimultaneousDrags: widget.canMove ? null : 0,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            onDragUpdate: (details) =>
                _dragTiltController.addDelta(details.delta.dx),
            feedback: TiltDragFeedback(
              controller: _dragTiltController,
              child: StrategyTileDragPreview(data: viewData),
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(
                  () => _highlightColor = Settings.tacticalVioletTheme.ring),
              onExit: (_) => setState(
                  () => _highlightColor = Settings.tacticalVioletTheme.border),
              child: AbsorbPointer(
                absorbing: _isLoading,
                child: ShadContextMenuRegion(
                  controller: _rightClickMenuController,
                  items: _buildMenuItems(),
                  child: GestureDetector(
                    onTap: () => _openStrategy(context),
                    child: Builder(
                      builder: (context) {
                        final dropSide = _pinnedDropSide;
                        final slotKey = dropSide == null
                            ? null
                            : dropInsertionSlotKey(
                                itemId: id,
                                side: dropSide,
                                pinnedOrder: pinnedIdsInManualOrder(pinned),
                              );
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              decoration: BoxDecoration(
                                color: ShadTheme.of(context).colorScheme.card,
                                borderRadius: BorderRadius.circular(
                                    strategyTileOuterRadius),
                                border: Border.all(
                                  color: isPinDropTarget
                                      ? Settings.tacticalVioletTheme.border
                                      : _highlightColor,
                                  width: 2,
                                ),
                              ),
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: StrategyTileThumbnail(
                                      assetPath: viewData.thumbnailAsset,
                                      borderRadius: strategyTileInnerRadius,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Expanded(
                                    child: StrategyTileDetails(
                                      data: viewData,
                                      borderRadius: strategyTileInnerRadius,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isPinned)
                              Align(
                                alignment: Alignment.topLeft,
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Settings
                                          .tacticalVioletTheme.background
                                          .withValues(alpha: 0.78),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color:
                                            Settings.tacticalVioletTheme.border,
                                      ),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.all(5),
                                      child: Icon(Icons.push_pin, size: 15),
                                    ),
                                  ),
                                ),
                              ),
                            Align(
                              alignment: Alignment.topRight,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: ShadContextMenuRegion(
                                  controller: _menuButtonController,
                                  items: _buildMenuItems(),
                                  child: Listener(
                                    onPointerDown: (_) {
                                      _menuButtonWasOpenOnPointerDown =
                                          _menuButtonController.isOpen;
                                    },
                                    child: ShadIconButton.secondary(
                                      width: 28,
                                      height: 28,
                                      onPressed: _handleMenuButtonPressed,
                                      icon:
                                          const Icon(Icons.more_vert_outlined),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (dropSide != null && slotKey != null)
                              Positioned.fill(
                                child: DropInsertionIndicator(
                                  key: ValueKey(slotKey),
                                  slotKey: slotKey,
                                  side: dropSide,
                                  // Matches the grid spacing in FolderContent
                                  // so the caret sits centered in the gutter.
                                  gap: strategyTileGridSpacing,
                                  topInset: 6,
                                  bottomInset: 6,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<ShadContextMenuItem> _buildMenuItems() {
    final pinned = ref.watch(pinnedItemsProvider);
    final id = _strategyId;
    final isPinned = pinned.containsKey(id);
    return [
      ShadContextMenuItem(
        leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined),
        child: Text(isPinned ? 'Unpin' : 'Pin'),
        onPressed: () {
          _closeMenus();
          ref.read(pinnedItemsProvider.notifier).togglePin(id);
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.pencil),
        child: const Text('Rename'),
        enabled: widget.canRename,
        onPressed: widget.canRename
            ? () {
                _closeMenus();
                _showRenameDialog();
              }
            : null,
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.copy),
        child: const Text('Duplicate'),
        enabled: widget.canDuplicate,
        onPressed: widget.canDuplicate
            ? () {
                _closeMenus();
                _duplicateStrategy();
              }
            : null,
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.upload),
        child: const Text('Export'),
        onPressed: () {
          _closeMenus();
          _exportStrategy();
        },
      ),
      if (_canShare)
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.link2),
          child: const Text('Share'),
          onPressed: () {
            _closeMenus();
            _showShareDialog();
          },
        ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.trash2, color: Colors.redAccent),
        child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        enabled: widget.canDelete,
        onPressed: widget.canDelete
            ? () {
                _closeMenus();
                _showDeleteDialog();
              }
            : null,
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
