import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class PagesBar extends ConsumerStatefulWidget {
  const PagesBar({super.key});

  @override
  ConsumerState<PagesBar> createState() => _PagesBarState();
}

class _PagesBarState extends ConsumerState<PagesBar> {
  bool _expanded = false;

  Future<void> _addPage() async {
    await ref.read(strategyProvider.notifier).addPage();
  }

  Future<void> _selectPage(String id) async {
    await ref.read(strategyProvider.notifier).switchPage(id);
  }

  Future<void> _renamePage(_PageBarItemData page) async {
    final controller = TextEditingController(text: page.name);
    final newName = await showShadDialog<String>(
      context: context,
      builder: (ctx) => ShadDialog(
        title: const Text('Rename page'),
        description: const Text('Enter a new name for the page:'),
        actions: [
          ShadButton.secondary(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            leading: const Icon(Icons.text_fields),
            child: const Text('Rename'),
          ),
        ],
        child: CustomTextField(
          controller: controller,
          onSubmitted: (value) => Navigator.of(ctx).pop(value.trim()),
        ),
      ),
    );

    controller.dispose();
    if (newName == null || newName.isEmpty || newName == page.name) {
      return;
    }

    await ref.read(strategyProvider.notifier).renamePage(page.id, newName);
  }

  Future<void> _deletePage(_PageBarItemData page, int totalPages) async {
    if (totalPages <= 1) {
      return;
    }

    final confirm = await ConfirmAlertDialog.show(
      context: context,
      title: "Delete '${page.name}'?",
      content:
          'Are you sure you want to delete this page? This action cannot be undone.',
      confirmText: 'Delete',
      cancelText: 'Cancel',
      isDestructive: true,
    );

    if (confirm != true) {
      return;
    }

    await ref.read(strategyProvider.notifier).deletePage(page.id);
  }

  @override
  Widget build(BuildContext context) {
    final isCloud = ref.watch(isCloudCollabEnabledProvider);
    final activePageId =
        ref.watch(strategyProvider.select((state) => state.activePageId));

    if (isCloud) {
      final snapshot = ref.watch(remoteStrategySnapshotProvider).valueOrNull;
      final canEdit = snapshot?.header.role != 'viewer';
      final pages = snapshot == null
          ? const <_PageBarItemData>[]
          : ([
              for (final page in [
                ...snapshot.pages
              ]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)))
                _PageBarItemData(
                  id: page.publicId,
                  name: page.name,
                ),
            ]);
      return _buildBar(
        pages: pages,
        activePageId: activePageId,
        canEdit: canEdit,
      );
    }

    final strategyId = ref.watch(strategyProvider).id;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    return ValueListenableBuilder<Box<StrategyData>>(
      valueListenable: box.listenable(keys: [strategyId]),
      builder: (context, strategyBox, _) {
        final strategy = strategyBox.get(strategyId);
        final pages = strategy == null
            ? const <_PageBarItemData>[]
            : ([
                for (final page in [
                  ...strategy.pages
                ]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)))
                  _PageBarItemData(
                    id: page.id,
                    name: page.name,
                  ),
              ]);

        return _buildBar(
          pages: pages,
          activePageId: activePageId,
          canEdit: true,
        );
      },
    );
  }

  Widget _buildBar({
    required List<_PageBarItemData> pages,
    required String? activePageId,
    required bool canEdit,
  }) {
    if (pages.isEmpty) {
      return const SizedBox.shrink();
    }

    final resolvedActivePageId = activePageId ?? pages.first.id;
    final activePage = pages.firstWhere(
      (page) => page.id == resolvedActivePageId,
      orElse: () => pages.first,
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Settings.tacticalVioletTheme.border,
          width: 2,
        ),
      ),
      width: 224,
      child: _expanded
          ? _ExpandedPanel(
              pages: pages,
              activePageId: resolvedActivePageId,
              canEdit: canEdit,
              onSelect: _selectPage,
              onRename: _renamePage,
              onDelete: (page) => _deletePage(page, pages.length),
              onAdd: _addPage,
              onCollapse: () => setState(() => _expanded = false),
            )
          : _CollapsedPill(
              activeName: activePage.name,
              onAdd: canEdit ? _addPage : null,
              onToggle: () => setState(() => _expanded = true),
            ),
    );
  }
}

class _CollapsedPill extends StatelessWidget {
  const _CollapsedPill({
    required this.activeName,
    required this.onAdd,
    required this.onToggle,
  });

  final String activeName;
  final VoidCallback? onAdd;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 8),
          _SquareIconButton(
            icon: Icons.add,
            onTap: onAdd,
            tooltip: 'Add page',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              activeName,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          ShadIconButton.ghost(
            foregroundColor: Colors.white,
            onPressed: onToggle,
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _ExpandedPanel extends ConsumerWidget {
  const _ExpandedPanel({
    required this.pages,
    required this.activePageId,
    required this.canEdit,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.onAdd,
    required this.onCollapse,
  });

  final List<_PageBarItemData> pages;
  final String activePageId;
  final bool canEdit;
  final ValueChanged<String> onSelect;
  final ValueChanged<_PageBarItemData> onRename;
  final ValueChanged<_PageBarItemData> onDelete;
  final VoidCallback onAdd;
  final VoidCallback onCollapse;

  static const double _rowHeight = 40;
  static const double _verticalSpacing = 10;
  static const double _headerFooterHeight = 49;
  static const double _topPadding = 8;
  static const double _bottomPadding = 0;
  static const double _maxPanelHeight = 310;

  double _computeDesiredHeight(int count) {
    if (count == 0) {
      return _headerFooterHeight + 56;
    }
    final rowsHeight = count * _rowHeight;
    final spacersHeight = (count - 1) * _verticalSpacing;
    final listSection =
        _topPadding + rowsHeight + spacersHeight + _bottomPadding;
    return (listSection + _headerFooterHeight).clamp(0, _maxPanelHeight);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desiredHeight = _computeDesiredHeight(pages.length);
    final needsScroll = desiredHeight >= _maxPanelHeight - 0.5;
    final activeIndex = pages.indexWhere((page) => page.id == activePageId);

    int? backwardIndex;
    int? forwardIndex;
    if (activeIndex >= 0 && pages.isNotEmpty) {
      backwardIndex = activeIndex - 1;
      if (backwardIndex < 0) backwardIndex = pages.length - 1;

      forwardIndex = activeIndex + 1;
      if (forwardIndex >= pages.length) forwardIndex = 0;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeInOut,
      constraints: BoxConstraints(
        maxHeight: _maxPanelHeight,
        minHeight: desiredHeight,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(top: _topPadding),
              child: ReorderableListView.builder(
                onReorder: canEdit
                    ? (oldIndex, newIndex) {
                        ref
                            .read(strategyProvider.notifier)
                            .reorderPage(oldIndex, newIndex);
                      }
                    : (_, __) {},
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                shrinkWrap: !needsScroll,
                physics:
                    needsScroll ? null : const NeverScrollableScrollPhysics(),
                itemCount: pages.length,
                buildDefaultDragHandles: false,
                proxyDecorator: (child, index, animation) => child,
                itemBuilder: (context, index) {
                  final page = pages[index];

                  var showForwardIndicator = false;
                  var showBackwardIndicator = false;
                  if (pages.length != 1) {
                    if (pages.length == 2) {
                      if (activeIndex == 0 && activeIndex != index) {
                        showForwardIndicator = true;
                      } else if (activeIndex == 1 && activeIndex != index) {
                        showBackwardIndicator = true;
                      }
                    } else {
                      if (forwardIndex != null && index == forwardIndex) {
                        showForwardIndicator = true;
                      }
                      if (backwardIndex != null &&
                          index == backwardIndex &&
                          forwardIndex != backwardIndex) {
                        showBackwardIndicator = true;
                      }
                    }
                  }

                  final row = Padding(
                    key: ValueKey(page.id),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _PageRow(
                      page: page,
                      active: page.id == activePageId,
                      showBackwardIndicator: showBackwardIndicator,
                      showForwardIndicator: showForwardIndicator,
                      onSelect: onSelect,
                      onRename: onRename,
                      onDelete: onDelete,
                      disableRename: !canEdit,
                      disableDelete: !canEdit || pages.length == 1,
                    ),
                  );

                  if (!canEdit) {
                    return row;
                  }

                  return ReorderableDragStartListener(
                    key: ValueKey(page.id),
                    index: index,
                    child: row,
                  );
                },
              ),
            ),
          ),
          Divider(height: 1, color: Settings.tacticalVioletTheme.border),
          SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 8),
                _SquareIconButton(
                  icon: Icons.add,
                  onTap: canEdit ? onAdd : null,
                  tooltip: 'Add page',
                ),
                const Spacer(),
                ShadIconButton.ghost(
                  foregroundColor: Colors.white,
                  onPressed: onCollapse,
                  icon:
                      const Icon(Icons.keyboard_arrow_up, color: Colors.white),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PageRow extends StatelessWidget {
  const _PageRow({
    required this.page,
    required this.active,
    required this.showBackwardIndicator,
    required this.showForwardIndicator,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.disableRename,
    required this.disableDelete,
  });

  final _PageBarItemData page;
  final bool active;
  final bool showBackwardIndicator;
  final bool showForwardIndicator;
  final ValueChanged<String> onSelect;
  final ValueChanged<_PageBarItemData> onRename;
  final ValueChanged<_PageBarItemData> onDelete;
  final bool disableRename;
  final bool disableDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final backgroundColor = active
        ? Settings.tacticalVioletTheme.primary
        : Settings.tacticalVioletTheme.card;

    return Material(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(14),
        onTap: () => onSelect(page.id),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Settings.tacticalVioletTheme.border,
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Settings.tacticalVioletTheme.card.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
            color: backgroundColor,
          ),
          height: 40,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    page.name,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (showBackwardIndicator || showForwardIndicator) ...[
                  const SizedBox(width: 6),
                  if (showBackwardIndicator) const _KeybindBadge(label: 'A'),
                  if (showBackwardIndicator && showForwardIndicator)
                    const SizedBox(width: 4),
                  if (showForwardIndicator) const _KeybindBadge(label: 'D'),
                  const SizedBox(width: 2),
                ],
                ShadTooltip(
                  builder: (context) => const Text('Rename'),
                  child: ShadIconButton.ghost(
                    hoverBackgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    icon: const Icon(Icons.edit, size: 18, color: Colors.white),
                    onPressed: disableRename ? null : () => onRename(page),
                  ),
                ),
                ShadTooltip(
                  builder: (context) => const Text('Delete'),
                  child: ShadIconButton.ghost(
                    hoverForegroundColor:
                        Settings.tacticalVioletTheme.destructive,
                    hoverBackgroundColor: Colors.transparent,
                    foregroundColor:
                        disableDelete ? Colors.white24 : Colors.white,
                    icon: const Icon(Icons.delete, size: 18),
                    onPressed: disableDelete ? null : () => onDelete(page),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KeybindBadge extends StatelessWidget {
  const _KeybindBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 20,
      width: 20,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                height: 1,
              ),
        ),
      ),
    );
  }
}

class _SquareIconButton extends StatelessWidget {
  const _SquareIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return ShadTooltip(
      builder: (context) => Text(tooltip),
      child: ShadIconButton(
        icon: Icon(icon),
        width: 36,
        height: 36,
        onPressed: onTap,
        decoration: ShadDecoration(
          border: ShadBorder(
            radius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class _PageBarItemData {
  const _PageBarItemData({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;
}
