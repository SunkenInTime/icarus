import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/library_context_menu_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
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
  const StrategyTile({super.key, required this.strategyData});

  final StrategyData strategyData;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _StrategyTileState();
}

const double _ringWidth = 2;

class _StrategyTileState extends ConsumerState<StrategyTile> {
  bool _isHovered = false;
  bool _isLoading = false;
  bool _menuButtonWasOpenOnPointerDown = false;
  DropInsertionSide? _pinnedDropSide;

  final ShadContextMenuController _menuButtonController =
      ShadContextMenuController();
  final ShadContextMenuController _rightClickMenuController =
      ShadContextMenuController();
  final DragTiltController _dragTiltController = DragTiltController();

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

    final viewData = StrategyTileViewData(widget.strategyData);
    final pinned = ref.watch(pinnedItemsProvider);
    final id = widget.strategyData.id;
    final isPinned = pinned.containsKey(id);

    return DragTarget<GridItem>(
      onWillAcceptWithDetails: (details) {
        final item = details.data;
        return item is StrategyItem &&
            item.strategy.id != id &&
            isPinned &&
            pinned.containsKey(item.strategy.id);
      },
      onMove: (details) {
        final item = details.data;
        final nextSide = item is StrategyItem &&
                item.strategy.id != id &&
                isPinned &&
                pinned.containsKey(item.strategy.id)
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
              id: item.strategy.id,
              targetId: id,
              insertAfterTarget: insertionSide == DropInsertionSide.after,
            );
      },
      builder: (context, candidateData, rejectedData) {
        final isPinDropTarget = candidateData.any(
          (item) =>
              item is StrategyItem &&
              item.strategy.id != id &&
              isPinned &&
              pinned.containsKey(item.strategy.id),
        );

        return Padding(
          padding: const EdgeInsets.all(strategyTileGutterOutset),
          child: Draggable<GridItem>(
            data: StrategyItem(widget.strategyData),
            dragAnchorStrategy: pointerDragAnchorStrategy,
            onDragUpdate: (details) =>
                _dragTiltController.addDelta(details.delta.dx),
            feedback: TiltDragFeedback(
              controller: _dragTiltController,
              child: StrategyTileDragPreview(data: viewData),
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _isHovered = true),
              onExit: (_) => setState(() => _isHovered = false),
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
                            // The ring is the outer box showing through a
                            // 2px inset: flat zinc at rest, and on hover the
                            // lit violet gradient, since a Border cannot
                            // take a gradient.
                            AnimatedContainer(
                                duration: const Duration(milliseconds: 100),
                                decoration: BoxDecoration(
                                  color: Settings.tacticalVioletTheme.border,
                                  gradient: !isPinDropTarget && _isHovered
                                      ? Settings.raisedPrimaryFill
                                      : null,
                                  borderRadius: BorderRadius.circular(
                                      strategyTileOuterRadius),
                                ),
                                padding: const EdgeInsets.all(_ringWidth),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color:
                                        ShadTheme.of(context).colorScheme.card,
                                    borderRadius: BorderRadius.circular(
                                        strategyTileOuterRadius - _ringWidth),
                                  ),
                                  padding: const EdgeInsets.all(8 - _ringWidth),
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
                                )),
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
                                      child: Icon(LucideIcons.pin, size: 15),
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
                                      icon: const Icon(
                                          LucideIcons.ellipsisVertical),
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
    final id = widget.strategyData.id;
    final isPinned = pinned.containsKey(id);
    return [
      ShadContextMenuItem(
        leading: Icon(isPinned ? LucideIcons.pinOff : LucideIcons.pin),
        child: Text(isPinned ? 'Unpin' : 'Pin'),
        onPressed: () {
          _closeMenus();
          ref.read(pinnedItemsProvider.notifier).togglePin(id);
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.pencil),
        child: const Text('Rename'),
        onPressed: () {
          _closeMenus();
          _showRenameDialog();
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.copy),
        child: const Text('Duplicate'),
        onPressed: () {
          _closeMenus();
          _duplicateStrategy();
        },
      ),
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.upload),
        child: const Text('Export'),
        onPressed: () {
          _closeMenus();
          _exportStrategy();
        },
      ),
      ShadContextMenuItem(
        leading: Icon(LucideIcons.trash2,
            color: Settings.tacticalVioletTheme.destructive),
        child: Text('Delete',
            style: TextStyle(color: Settings.tacticalVioletTheme.destructive)),
        onPressed: () {
          _closeMenus();
          _showDeleteDialog();
        },
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
          initialStrategyId: widget.strategyData.id,
          initialStrategyName: widget.strategyData.name,
          initialMapValue: widget.strategyData.mapData,
          initialIsAttack: _initialIsAttack(widget.strategyData),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool _initialIsAttack(StrategyData strategy) {
    return strategy.pages.isEmpty ? true : strategy.pages.first.isAttack;
  }

  Future<void> _duplicateStrategy() async {
    await ref
        .read(strategyProvider.notifier)
        .duplicateStrategy(widget.strategyData.id);
  }

  Future<void> _exportStrategy() async {
    if (kIsWeb) {
      Settings.showToast(
        message: 'This feature is only supported in the Windows version.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

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
