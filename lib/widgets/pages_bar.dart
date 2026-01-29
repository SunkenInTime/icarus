import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/active_page_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/valorant_round_provider.dart';

import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/valorant/valorant_match_strategy_data.dart';
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
    if (id == ref.read(activePageProvider)) return;
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

    final match = strat.valorantMatch;
    String? updatedMatchJson;
    if (match != null) {
      final updatedMeta =
          match.pageMeta.where((m) => m.pageId != page.id).toList();
      updatedMatchJson = ValorantMatchStrategyData(
        schemaVersion: match.schemaVersion,
        matchId: match.matchId,
        riotMapId: match.riotMapId,
        allyTeamId: match.allyTeamId,
        povSubject: match.povSubject,
        players: match.players,
        rounds: match.rounds,
        pageMeta: updatedMeta,
      ).toJsonString();
    }

    // Reindex sortIndex to keep dense ordering
    final reindexed = [
      for (var i = 0; i < remaining.length; i++)
        remaining[i].copyWith(sortIndex: i),
    ];
    final activeId = ref.read(activePageProvider);
    final newActive = (activeId == page.id) ? reindexed.first.id : activeId;

    final updated = strat.copyWith(
      pages: reindexed,
      lastEdited: DateTime.now(),
      valorantMatchJson: updatedMatchJson ?? strat.valorantMatchJson,
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

        final match = strat.valorantMatch;
        final selectedRound = ref.watch(valorantRoundProvider);

        final pages = _pagesForUi(
          strat: strat,
          match: match,
          selectedRound: selectedRound,
        );

        final activeFromState = ref.watch(activePageProvider);
        final activePageId =
            activeFromState ?? (pages.isNotEmpty ? pages.first.id : null);

        final String activeName;
        if (pages.isEmpty) {
          if (match != null) {
            activeName = 'Round ${(selectedRound ?? 0) + 1}';
          } else {
            activeName = 'No pages';
          }
        } else {
          activeName = pages
              .firstWhere(
                (p) => p.id == activePageId,
                orElse: () => pages.first,
              )
              .name;
        }

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
                  match: match,
                  selectedRound: selectedRound,
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

List<StrategyPage> _pagesForUi({
  required StrategyData strat,
  required ValorantMatchStrategyData? match,
  required int? selectedRound,
}) {
  if (match == null) {
    final pages = [...strat.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return pages;
  }

  final roundIndex = selectedRound ?? 0;
  final meta = match.pageMeta.where((m) => m.roundIndex == roundIndex).toList()
    ..sort((a, b) => a.orderInRound.compareTo(b.orderInRound));

  final pagesById = {for (final p in strat.pages) p.id: p};
  final pages = <StrategyPage>[];
  for (final m in meta) {
    final p = pagesById[m.pageId];
    if (p != null) pages.add(p);
  }
  return pages;
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
class _ExpandedPanel extends ConsumerWidget {
  const _ExpandedPanel({
    required this.pages,
    required this.strategy,
    required this.match,
    required this.selectedRound,
    required this.activePageId,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.onAdd,
    required this.onCollapse,
  });

  final List<StrategyPage> pages;
  final StrategyData strategy;
  final ValorantMatchStrategyData? match;
  final int? selectedRound;
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
    final showRoundHeader = match != null;

    const roundHeaderHeight = 44.0;

    final desiredHeightUnclamped = _computeDesiredHeight(pages.length) +
        (showRoundHeader ? roundHeaderHeight : 0);
    final desiredHeight =
        desiredHeightUnclamped.clamp(0, _maxPanelHeight).toDouble();
    final needsScroll =
        desiredHeightUnclamped >= _maxPanelHeight - 0.5; // approximate

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
          if (showRoundHeader)
            SizedBox(
              height: roundHeaderHeight,
              child: _RoundHeader(
                match: match!,
                selectedRound: selectedRound ?? 0,
              ),
            ),
          // List / content section
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(top: _topPadding),
              child: ReorderableListView.builder(
                onReorder: (oldIndex, newIndex) {
                  // Reordering is not supported in match mode yet.
                  if (match == null) {
                    ref
                        .read(strategyProvider.notifier)
                        .reorderPage(oldIndex, newIndex);
                  }
                },
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                shrinkWrap: needsScroll ? false : true,
                physics:
                    needsScroll ? null : const NeverScrollableScrollPhysics(),
                itemCount: pages.length,
                buildDefaultDragHandles: match == null ? false : true,
                proxyDecorator: proxyDecorator,
                itemBuilder: (ctx, i) {
                  final p = pages[i];

                  final row = Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _PageRow(
                      page: p,
                      active: p.id == activePageId,
                      onSelect: onSelect,
                      onRename: onRename,
                      onDelete: onDelete,
                      disableDelete: pages.length == 1,
                    ),
                  );

                  if (match != null)
                    return KeyedSubtree(key: ValueKey(p.id), child: row);

                  return ReorderableDragStartListener(
                    key: ValueKey(p.id),
                    index: i,
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
        side: BorderSide(
          color: Settings.tacticalVioletTheme.border,
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

class _RoundHeader extends ConsumerWidget {
  const _RoundHeader({
    required this.match,
    required this.selectedRound,
  });

  final ValorantMatchStrategyData match;
  final int selectedRound;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totalRounds = match.rounds.length;
    if (totalRounds == 0) return const SizedBox.shrink();

    final current = selectedRound.clamp(0, totalRounds - 1);

    Future<void> setRound(int index) async {
      final clamped = index.clamp(0, totalRounds - 1);
      ref.read(valorantRoundProvider.notifier).setRound(clamped);

      final strategyId = ref.read(strategyProvider).id;
      final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      final strat = box.get(strategyId);
      if (strat == null) return;

      final updatedMatch = strat.valorantMatch;
      if (updatedMatch == null) return;

      final meta = updatedMatch.pageMeta
          .where((m) => m.roundIndex == clamped)
          .toList()
        ..sort((a, b) => a.orderInRound.compareTo(b.orderInRound));
      if (meta.isEmpty) return;

      await ref
          .read(strategyProvider.notifier)
          .setActivePageAnimated(meta.first.pageId);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Settings.tacticalVioletTheme.border,
            width: 1,
          ),
        ),
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: 4),
              ShadIconButton.ghost(
                onPressed: current <= 0 ? null : () => setRound(current - 1),
                icon: const Icon(
                  Icons.chevron_left,
                  color: Colors.white,
                ),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    'Round ${current + 1} / $totalRounds',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
              ShadIconButton.ghost(
                onPressed: current >= totalRounds - 1
                    ? null
                    : () => setRound(current + 1),
                icon: const Icon(
                  Icons.chevron_right,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 4),
            ],
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
