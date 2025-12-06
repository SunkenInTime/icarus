import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
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
            backgroundColor: Settings.highlightColor,
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
          // onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
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
        await ref.read(strategyProvider.notifier).setActivePage(newActive);
    }
  }

  @override
  Widget build(BuildContext context) {
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
            ref.watch(strategyProvider.notifier).activePageID ??
                (pages.isNotEmpty ? pages.first.id : null);
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
class _ExpandedPanel extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desiredHeight = _computeDesiredHeight(pages.length);
    final needsScroll = desiredHeight >= _maxPanelHeight - 0.5; // approximate

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
              child: needsScroll
                  ? ListView.separated(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                      itemCount: pages.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: _verticalSpacing),
                      itemBuilder: (ctx, i) {
                        final p = pages[i];
                        final selected = p.id == activePageId;
                        final bg = selected
                            ? Settings.tacticalVioletTheme.primary
                            : Settings.tacticalVioletTheme.card;
                        return Material(
                          color: bg,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: Settings.tacticalVioletTheme.border,
                              width: 1,
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => onSelect(p.id),
                            child: SizedBox(
                              height: _rowHeight,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 12),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        p.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                          color: Colors.white,
                                          fontWeight: selected
                                              ? FontWeight.w600
                                              : FontWeight.w500,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    ShadTooltip(
                                      builder: (context) =>
                                          const Text("Rename"),
                                      child: ShadIconButton.ghost(
                                        hoverForegroundColor: Settings
                                            .tacticalVioletTheme.primary,
                                        hoverBackgroundColor:
                                            Colors.transparent,
                                        icon: const Icon(Icons.edit,
                                            size: 18, color: Colors.white),
                                        onPressed: () => onRename(p),
                                      ),
                                    ),
                                    ShadTooltip(
                                      builder: (context) =>
                                          const Text("Delete"),
                                      child: ShadIconButton.ghost(
                                        // splashRadius: 18,
                                        hoverBackgroundColor:
                                            Colors.transparent,

                                        hoverForegroundColor: Settings
                                            .tacticalVioletTheme.destructive,
                                        foregroundColor: pages.length == 1
                                            ? Colors.white24
                                            : Colors.white,
                                        icon: const Icon(
                                          Icons.delete,
                                          size: 18,
                                        ),
                                        onPressed: pages.length == 1
                                            ? null
                                            : () => onDelete(p),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < pages.length; i++) ...[
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8.0),
                            child: _PageRow(
                              page: pages[i],
                              active: pages[i].id == activePageId,
                              onSelect: onSelect,
                              onRename: onRename,
                              onDelete: onDelete,
                              disableDelete: pages.length == 1,
                            ),
                          ),
                          // if (i != pages.length - 1)
                          const SizedBox(height: _verticalSpacing),
                        ]
                      ],
                    ),
            ),
          ),
          const Divider(height: 1, color: Settings.highlightColor),
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
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.disableDelete,
  });

  final StrategyPage page;
  final bool active;
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
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(
          color: Settings.highlightColor,
          width: 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onSelect(page.id),
        child: SizedBox(
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

/* -------- Square + button -------- */
class _SquareIconButton extends StatelessWidget {
  const _SquareIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    required this.color,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ShadTooltip(
      builder: (context) => Text(tooltip),
      child: ShadIconButton(
        icon: const Icon(Icons.add),
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
