import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';

import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/custom_text_field.dart';

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
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Rename page"),
        content: CustomTextField(
          // autofocus: true,
          controller: controller,
          // onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          CustomButton(
            onPressed: () => Navigator.of(ctx).pop(),
            height: 40,
            label: "Cancel",
            backgroundColor: Settings.highlightColor,
          ),
          CustomButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            height: 40,
            icon: const Icon(Icons.edit),
            label: "Rename",
          ),
        ],
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Delete page"),
        content: Text("Delete '${page.name}'?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text("Cancel")),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.red, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(c, true),
              child: const Text("Delete")),
        ],
      ),
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
            color: Settings.sideBarColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Settings.highlightColor,
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
            color: Colors.deepPurple,
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
          IconButton(
            splashRadius: 20,
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
                            ? Colors.deepPurple
                            : const Color(0xFF231C21);
                        return Material(
                          color: bg,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: selected
                                  ? Settings.highlightColor
                                  : Settings.highlightColor.withOpacity(.4),
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
                                    IconButton(
                                      tooltip: "Rename",
                                      splashRadius: 18,
                                      icon: const Icon(Icons.edit,
                                          size: 18, color: Colors.white),
                                      onPressed: () => onRename(p),
                                    ),
                                    IconButton(
                                      tooltip: "Delete",
                                      splashRadius: 18,
                                      icon: Icon(
                                        Icons.delete,
                                        size: 18,
                                        color: pages.length == 1
                                            ? Colors.white24
                                            : Colors.white,
                                      ),
                                      onPressed: pages.length == 1
                                          ? null
                                          : () => onDelete(p),
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
                  color: Colors.deepPurple,
                ),
                const Spacer(),
                IconButton(
                  splashRadius: 20,
                  tooltip: "Collapse",
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
    final bg = active ? Colors.deepPurple : const Color(0xFF231C21);
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
                IconButton(
                  tooltip: "Rename",
                  splashRadius: 18,
                  icon: const Icon(Icons.edit, size: 18, color: Colors.white),
                  onPressed: () => onRename(page),
                ),
                IconButton(
                  tooltip: "Delete",
                  splashRadius: 18,
                  icon: Icon(
                    Icons.delete,
                    size: 18,
                    color: disableDelete ? Colors.white24 : Colors.white,
                  ),
                  onPressed: disableDelete ? null : () => onDelete(page),
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
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Settings.highlightColor, width: 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: const SizedBox(
            width: 36,
            height: 36,
            child: Icon(Icons.add, color: Colors.white, size: 18),
          ),
        ),
      ),
    );
  }
}
