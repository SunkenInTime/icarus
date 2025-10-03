import 'package:flutter/material.dart';
import 'package:icarus/providers/strategy_page.dart';

/// A horizontal, floating set of page chips with a leading Add button.
/// - Each page is rendered as an InputChip with the page name and an `x` delete affordance.
/// - Tapping a chip selects/switches to that page via [onSelect].
/// - Tapping the delete on a chip calls [onDelete] (parent can confirm and/or prevent when last page).
/// - The Add button at the start calls [onAdd].
/// - No container background is used so the chips appear to “float”.
class PageChipsBar extends StatelessWidget {
  const PageChipsBar({
    super.key,
    required this.pages,
    required this.activePageId,
    required this.onSelect,
    required this.onDelete,
    required this.onAdd,
    this.maxChipWidth = 160,
    this.spacing = 8,
    this.runSpacing = 8,
    this.padding,
  });

  final List<StrategyPage> pages;
  final String? activePageId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onDelete;
  final VoidCallback onAdd;

  /// Constrain chip label width to keep the row tidy
  final double maxChipWidth;

  /// Horizontal spacing between chips
  final double spacing;

  /// Vertical spacing when chips wrap (if used in a Wrap)
  final double runSpacing;

  /// Optional outer padding for the whole bar
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final children = <Widget>[
      // Leading add button as an InputChip for visual consistency
      InputChip(
        avatar: Icon(Icons.add, color: colorScheme.onSecondaryContainer),
        label: const Text('Add'),
        onPressed: onAdd,
        backgroundColor: colorScheme.secondaryContainer,
        selectedColor: colorScheme.secondaryContainer,
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          color: colorScheme.onSecondaryContainer,
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

        return InputChip(
          label: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxChipWidth),
            child: Text(
              p.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          tooltip: p.name,
          onPressed: () => onSelect(p.id),
          onDeleted: () => onDelete(p.id),
          deleteIcon: const Icon(Icons.close, size: 18),
          selected: isSelected,
          backgroundColor: chipBg,
          selectedColor: chipBg,
          labelStyle: theme.textTheme.labelLarge?.copyWith(color: chipFg),
          side: isSelected
              ? BorderSide(color: colorScheme.primary, width: 1.2)
              : BorderSide(color: colorScheme.outlineVariant),
          shape: const StadiumBorder(),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
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

extension _ListUtils<T> on List<T> {
  List<T> intersperse(T separator) {
    if (isEmpty) return this;
    return [
      for (var i = 0; i < length; i++) ...[if (i != 0) separator, this[i]],
    ];
  }
}
