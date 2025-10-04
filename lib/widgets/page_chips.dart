import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';

/// A horizontal, floating set of page chips with a leading Add button.
/// - Each page is rendered as an InputChip with the page name and an `x` delete affordance.
/// - Tapping a chip selects/switches to that page via [onSelect].
/// - Tapping the delete on a chip calls [onDelete] (parent can confirm and/or prevent when last page).
/// - The Add button at the start calls [onAdd].
/// - No container background is used so the chips appear to “float”.
class PageChipsBar extends ConsumerWidget {
  const PageChipsBar({
    super.key,
    required this.onSelect,
    required this.onDelete,
    this.maxChipWidth = 160,
    this.spacing = 8,
    this.runSpacing = 8,
    this.padding,
  });

  // final List<StrategyPage> pages;
  // final String? activePageId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onDelete;

  /// Constrain chip label width to keep the row tidy
  final double maxChipWidth;

  /// Horizontal spacing between chips
  final double spacing;

  /// Vertical spacing when chips wrap (if used in a Wrap)
  final double runSpacing;

  /// Optional outer padding for the whole bar
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final strat = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .get(ref.watch(strategyProvider).id);

    if (strat == null) {
      return const SizedBox();
    }
    final pages = [
      ...strat.pages,
      StrategyPage(
        id: "new_page",
        name: "New Page",
        drawingData: [],
        agentData: [],
        abilityData: [],
        textData: [],
        imageData: [],
        utilityData: [],
        sortIndex: 1,
      ),
    ];

    final activePageId = ref.watch(strategyProvider.notifier).activePageID;
    final children = <Widget>[
      // Leading add button as an InputChip for visual consistency
      IconButton.filled(
        color: Colors.deepPurple,
        onPressed: () {},
        icon: const Icon(
          Icons.add,
          color: Colors.white,
        ),
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              side: const BorderSide(color: Settings.highlightColor, width: 1),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),

      ...pages.map((p) {
        final isSelected = p.id == activePageId;
        final chipBg = isSelected
            ? colorScheme.primaryContainer
            : theme.chipTheme.backgroundColor ??
                colorScheme.surfaceContainerHighest;
        final chipFg = isSelected
            ? colorScheme.onPrimaryContainer
            : theme.chipTheme.labelStyle?.color ??
                theme.colorScheme.onSurfaceVariant;

        // return SizedBox(
        //   height: 40,
        //   child: InputChip(
        //     label: ConstrainedBox(
        //       constraints:
        //           BoxConstraints(maxWidth: maxChipWidth, minHeight: 40),
        //       child: Text(
        //         p.name,
        //         overflow: TextOverflow.ellipsis,
        //       ),
        //     ),
        //     tooltip: p.name,
        //     onPressed: () => onSelect(p.id),
        //     onDeleted: () => onDelete(p.id),
        //     deleteIcon: const Icon(Icons.close, size: 18),
        //     selected: isSelected,
        //     backgroundColor: Settings.sideBarColor,
        //     selectedColor: Colors.deepPurple,
        //     labelStyle: theme.textTheme.labelLarge?.copyWith(color: chipFg),
        //     side: const BorderSide(color: Settings.highlightColor, width: 1.2),
        //     shape: RoundedRectangleBorder(
        //       borderRadius: BorderRadius.circular(8),
        //     ),
        //     materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        //     visualDensity: VisualDensity.compact,
        //   ),
        // );

        return PageTab(
          label: p.name,
          selected: isSelected,
          onTap: () => onSelect(p.id),
          onDelete: () => onDelete(p.id),
          maxWidth: maxChipWidth,
          height: 40,
        );
      })
    ].intersperse(SizedBox(width: spacing)).toList();

    // Use SingleChildScrollView + Row to make the chips feel "floating" horizontally.
    return Padding(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(children: children),
      ),
    );
  }
}

class PageTab extends StatelessWidget {
  const PageTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    required this.maxWidth,
    required this.height,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final double maxWidth;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg =
        selected ? theme.colorScheme.primaryContainer : Settings.sideBarColor;
    final fg = selected
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;

    return Material(
      color: bg,
      elevation: selected ? 2 : 0,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Settings.highlightColor, width: 1.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 56,
            maxWidth: maxWidth,
            minHeight: height,
            maxHeight: height,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(color: fg),
                  ),
                ),
                const SizedBox(width: 6),
                // _DeleteIconButton(onPressed: onDelete, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

extension _ListUtils<T> on List<T> {
  List<T> intersperse(T separator) {
    if (isEmpty) return this;
    return [
      for (var i = 0; i < length; i++) ...[if (i != 0) separator, this[i]],
    ];
  }
}
