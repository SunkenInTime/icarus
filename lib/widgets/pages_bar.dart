import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';

import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class PagesBar extends ConsumerStatefulWidget {
  const PagesBar({super.key});

  @override
  ConsumerState<PagesBar> createState() => _PagesBarState();
}

class _PagesBarState extends ConsumerState<PagesBar>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  StrategyData? _strategy(Box<StrategyData> box, String id) => box.get(id);

  Future<void> _addPage() async {
    await ref.read(strategyProvider.notifier).addPage();
  }

  Future<void> _selectPage(String id) async {
    if (id == ref.read(strategyProvider.notifier).activePageID) return;
    await ref.read(strategyProvider.notifier).setActivePageAnimated(id);
  }

  Future<void> _renamePage(StrategyData strat, StrategyPage page) async {
    final controller = TextEditingController(text: page.name);
    final newName = await showShadDialog<String>(
      context: context,
      builder: (ctx) => ShadDialog(
        title: const Text("Rename page"),
        description: const Text("Enter a new name for the page:"),
        actions: [
          ShadButton.secondary(
            onPressed: () => Navigator.of(ctx).pop(),
            backgroundColor: Settings.tacticalVioletTheme.border,
            child: const Text("Cancel"),
          ),
          ShadButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            leading: const Icon(Icons.text_fields),
            child: const Text("Rename"),
          ),
        ],
        child: CustomTextField(
          // autofocus: true,
          controller: controller,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
      ),
    );
    if (newName == null || newName.isEmpty || newName == page.name) return;

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final updatedPages = [
      for (final p in strat.pages)
        if (p.id == page.id) p.copyWith(name: newName) else p,
    ];
    final updated =
        strat.copyWith(pages: updatedPages, lastEdited: DateTime.now());
    await box.put(updated.id, updated);
    controller.dispose();
  }

  Future<void> _deletePage(StrategyData strat, StrategyPage page) async {
    if (strat.pages.length == 1) return; // cannot delete last

    final confirm = await ConfirmAlertDialog.show(
      context: context,
      title: "Delete '${page.name}'?",
      content:
          "Are you sure you want to delete this page? This action cannot be undone.",
      confirmText: "Delete",
      cancelText: "Cancel",
      isDestructive: true,
    );

    if (confirm != true) return;

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final remaining = [...strat.pages]..removeWhere((p) => p.id == page.id);
    // Reindex sortIndex to keep dense ordering
    final reindexed = [
      for (var i = 0; i < remaining.length; i++)
        remaining[i].copyWith(sortIndex: i),
    ];
    final activeId = ref.read(strategyProvider.notifier).activePageID;
    final newActive = (activeId == page.id) ? reindexed.first.id : activeId;

    final updated = strat.copyWith(
      pages: reindexed,
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
    if (newActive != activeId) {
      if (newActive != null)
        await ref
            .read(strategyProvider.notifier)
            .setActivePageAnimated(newActive);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCloud = ref.watch(isCloudCollabEnabledProvider);
    final activePageIdFromState =
        ref.watch(strategyProvider.select((state) => state.activePageId));

    if (isCloud) {
      final snapshot = ref.watch(remoteStrategySnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.pages.isEmpty) {
        return const SizedBox.shrink();
      }

      final pages = [...snapshot.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      final activePageId = activePageIdFromState ?? pages.first.publicId;
      final activeName = pages
          .firstWhere(
            (p) => p.publicId == activePageId,
            orElse: () => pages.first,
          )
          .name;

      return _CloudSimplePagesBar(
        pages: pages,
        activePageId: activePageId,
        activeName: activeName,
        expanded: _expanded,
        onAdd: _addPage,
        onSelect: (id) => ref.read(strategyProvider.notifier).switchPage(id),
        onToggle: () => setState(() => _expanded = !_expanded),
      );
    }

    final strategyId = ref.watch(strategyProvider).id;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    return ValueListenableBuilder(
      valueListenable: box.listenable(keys: [strategyId]),
      builder: (context, Box<StrategyData> b, _) {
        final strat = _strategy(b, strategyId);
        if (strat == null) return const SizedBox();

        final pages = [...strat.pages]
          ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
        final activePageId =
            activePageIdFromState ?? (pages.isNotEmpty ? pages.first.id : null);
        final activeName = pages
            .firstWhere(
              (p) => p.id == activePageId,
              orElse: () => pages.first,
            )
            .name;

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
          // Height grows when expanded
          padding: EdgeInsets.zero,
          child: _expanded
              ? _ExpandedPanel(
                  pages: pages,
                  strategy: strat,
                  activePageId: activePageId,
                  onSelect: _selectPage,
                  onRename: (p) => _renamePage(strat, p),
                  onDelete: (p) => _deletePage(strat, p),
                  onAdd: _addPage,
                  onCollapse: () => setState(() => _expanded = false),
                )
              : _CollapsedPill(
                  activeName: activeName,
                  onAdd: _addPage,
                  onToggle: () => setState(() => _expanded = true),
                ),
        );
      },
    );
  }
}

class _CloudSimplePagesBar extends StatelessWidget {
  const _CloudSimplePagesBar({
    required this.pages,
    required this.activePageId,
    required this.activeName,
    required this.expanded,
    required this.onAdd,
    required this.onSelect,
    required this.onToggle,
  });

  final List<RemotePage> pages;
  final String activePageId;
  final String activeName;
  final bool expanded;
  final Future<void> Function() onAdd;
  final ValueChanged<String> onSelect;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
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
      padding: EdgeInsets.zero,
      child: expanded
          ? Container(
              constraints: const BoxConstraints(maxHeight: 310),
              child: Column(
                children: [
                  Flexible(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                      itemCount: pages.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final page = pages[index];
                        final isActive = page.publicId == activePageId;
                        return OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: isActive
                                ? Settings.tacticalVioletTheme.primary
                                    .withValues(alpha: 0.18)
                                : Colors.transparent,
                            side: BorderSide(
                              color: isActive
                                  ? Settings.tacticalVioletTheme.primary
                                  : Settings.tacticalVioletTheme.border,
                            ),
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                          onPressed: () => onSelect(page.publicId),
                          child: Text(
                            page.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                        );
                      },
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
                          onTap: () => onAdd(),
                          tooltip: 'Add page',
                          color: Settings.tacticalVioletTheme.primary,
                          shortcutLabel: 'C',
                        ),
                        const Spacer(),
                        ShadIconButton.ghost(
                          foregroundColor: Colors.white,
                          onPressed: onToggle,
                          icon: const Icon(
                            Icons.keyboard_arrow_up,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ],
              ),
            )
          : _CollapsedPill(
              activeName: activeName,
              onAdd: () => onAdd(),
              onToggle: onToggle,
            ),
    );
  }
}

/* -------- Collapsed pill -------- */
class _CollapsedPill extends StatelessWidget {
  const _CollapsedPill({
    required this.activeName,
    required this.onAdd,
    required this.onToggle,
  });

  final String activeName;
  final VoidCallback onAdd;
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
            tooltip: "Add page",
            color: Settings.tacticalVioletTheme.primary,
            shortcutLabel: 'C',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              activeName,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14),
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

/* -------- Expanded panel -------- */
class _ExpandedPanel extends ConsumerWidget {
  const _ExpandedPanel({
    required this.pages,
    required this.strategy,
    required this.activePageId,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.onAdd,
    required this.onCollapse,
  });

  final List<StrategyPage> pages;
  final StrategyData strategy;
  final String? activePageId;
  final ValueChanged<String> onSelect;
  final ValueChanged<StrategyPage> onRename;
  final ValueChanged<StrategyPage> onDelete;
  final VoidCallback onAdd;
  final VoidCallback onCollapse;

  static const double _rowHeight = 40; // each page tile height
  static const double _verticalSpacing = 10; // separator height
  static const double _headerFooterHeight = 48 + 1; // bottom bar + divider
  static const double _topPadding = 8; // list top padding
  static const double _bottomPadding = 0; // list bottom padding inside Expanded
  static const double _maxPanelHeight = 310; // previous max constraint

  double _computeDesiredHeight(int count) {
    if (count == 0) return _headerFooterHeight + 56; // fallback
    final rowsHeight = count * _rowHeight;
    final spacersHeight = (count - 1) * _verticalSpacing;
    final listSection =
        _topPadding + rowsHeight + spacersHeight + _bottomPadding;
    final total =
        listSection + _headerFooterHeight; // include footer (add/collapse)
    return total.clamp(0, _maxPanelHeight);
  }

  Widget proxyDecorator(Widget child, int index, Animation<double> animation) {
    return child;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desiredHeight = _computeDesiredHeight(pages.length);
    final needsScroll = desiredHeight >= _maxPanelHeight - 0.5; // approximate
    final activeIndex = activePageId == null
        ? -1
        : pages.indexWhere((p) => p.id == activePageId);

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
        // Allow it to grow with content up to max
        maxHeight: _maxPanelHeight,
        minHeight: desiredHeight,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // List / content section
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(top: _topPadding),
              child: ReorderableListView.builder(
                onReorder: (oldIndex, newIndex) {
                  ref
                      .read(strategyProvider.notifier)
                      .reorderPage(oldIndex, newIndex);
                },
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                shrinkWrap: needsScroll ? false : true,
                physics:
                    needsScroll ? null : const NeverScrollableScrollPhysics(),
                itemCount: pages.length,
                buildDefaultDragHandles: false,
                proxyDecorator: proxyDecorator,
                itemBuilder: (ctx, i) {
                  bool showForwardIndicator = false;
                  bool showBackwardIndicator = false;
                  final p = pages[i];

                  if (pages.length != 1) {
                    if (pages.length == 2) {
                      if (activeIndex == 0 && activeIndex != i) {
                        showForwardIndicator = true;
                      } else if (activeIndex == 1 && activeIndex != i) {
                        showBackwardIndicator = true;
                      }
                    } else {
                      if (forwardIndex != null && i == forwardIndex) {
                        showForwardIndicator = true;
                      }
                      if (backwardIndex != null &&
                          i == backwardIndex &&
                          forwardIndex != backwardIndex) {
                        showBackwardIndicator = true;
                      }
                    }
                  }

                  return ReorderableDragStartListener(
                    key: ValueKey(p.id),
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _PageRow(
                        page: p,
                        active: p.id == activePageId,
                        showBackwardIndicator: showBackwardIndicator,
                        showForwardIndicator: showForwardIndicator,
                        onSelect: onSelect,
                        onRename: onRename,
                        onDelete: onDelete,
                        disableDelete: pages.length == 1,
                      ),
                    ),
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
                  onTap: onAdd,
                  tooltip: "Add page",
                  color: Settings.tacticalVioletTheme.primary,
                  shortcutLabel: 'C',
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
    required this.disableDelete,
  });

  final StrategyPage page;
  final bool active;
  final bool showBackwardIndicator;
  final bool showForwardIndicator;
  final ValueChanged<String> onSelect;
  final ValueChanged<StrategyPage> onRename;
  final ValueChanged<StrategyPage> onDelete;
  final bool disableDelete;

  static const double _rowHeight = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = active
        ? Settings.tacticalVioletTheme.primary
        : Settings.tacticalVioletTheme.card;
    return Material(
      // color: bg,
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
                  color:
                      Settings.tacticalVioletTheme.card.withValues(alpha: 0.2),
                  blurRadius: 12,
                  offset: const Offset(0, 4))
            ],
            color: bg,
          ),
          height: _rowHeight,
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
                  if (showBackwardIndicator) const _KeybindBadge(label: "A"),
                  if (showBackwardIndicator && showForwardIndicator)
                    const SizedBox(width: 4),
                  if (showForwardIndicator) const _KeybindBadge(label: "D"),
                  const SizedBox(width: 2),
                ],
                ShadTooltip(
                  builder: (context) => const Text("Rename"),
                  child: ShadIconButton.ghost(
                    hoverBackgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    icon: const Icon(Icons.edit, size: 18, color: Colors.white),
                    onPressed: () => onRename(page),
                  ),
                ),
                ShadTooltip(
                  builder: (context) => const Text("Delete"),
                  child: ShadIconButton.ghost(
                    hoverForegroundColor:
                        Settings.tacticalVioletTheme.destructive,
                    hoverBackgroundColor: Colors.transparent,
                    foregroundColor:
                        disableDelete ? Colors.white24 : Colors.white,
                    icon: const Icon(
                      Icons.delete,
                      size: 18,
                    ),
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
          textAlign: TextAlign.center,
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                height: 1.0,
              ),
        ),
      ),
    );
  }
}

/* -------- Square + button -------- */
class _SquareIconButton extends StatelessWidget {
  const _SquareIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    required this.color,
    this.shortcutLabel,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final Color color;
  final String? shortcutLabel;

  @override
  Widget build(BuildContext context) {
    final button = ShadTooltip(
      builder: (context) => Text(tooltip),
      child: ShadIconButton(
        backgroundColor: color,
        hoverBackgroundColor: color,
        foregroundColor: Colors.white,
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

    if (shortcutLabel == null || shortcutLabel!.isEmpty) {
      return button;
    }

    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: button),
          Positioned(
            right: 6,
            bottom: 5,
            child: Text(
              shortcutLabel!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 7,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.9),
                    height: 1.0,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
