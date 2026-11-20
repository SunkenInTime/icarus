import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/color_library_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/adjacent_page_copy_menu.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';
import 'package:icarus/widgets/sidebar_widgets/color_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

List<ShadContextMenuItem> buildCustomShapeContextMenuItems(
  BuildContext context,
  WidgetRef ref,
  PlacedUtility utility,
) {
  final currentColorValue = utility.customColorValue;

  return [
    ShadContextMenuItem(
      leading: MenuColorSwatch(
        color: currentColorValue == null
            ? Colors.transparent
            : Color(currentColorValue),
      ),
      items: [_CustomShapeColorItems(utility: utility)],
      child: Text(context.l10n.shapeToolsColorMenu),
    ),
    ShadContextMenuItem(
      leading: const Icon(LucideIcons.droplet, size: 16),
      items: [_CustomShapeOpacityItems(utility: utility)],
      child: Text(context.l10n.shapeToolsOpacityMenu),
    ),
    ...buildCaptionMenuItems(context, ref, utility.id),
    ...buildAdjacentPageCopyMenuItems(ref, utility.id),
  ];
}

/// The strengths a placed shape can be set to, in percent: the Shapes panel's
/// range in steps of ten.
const customShapeOpacitySteps = [10, 20, 30, 40, 50, 60, 70, 80];

class _CustomShapeOpacityItems extends ConsumerWidget {
  const _CustomShapeOpacityItems({required this.utility});

  final PlacedUtility utility;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = utility.customOpacityPercent;
    // A shape placed between two steps (35% from the panel) still finds its
    // own value in the list, ticked.
    final steps = {
      ...customShapeOpacitySteps,
      if (current != null) current,
    }.toList()
      ..sort();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final percent in steps)
          ShadContextMenuItem(
            trailing: percent == current
                ? const Icon(LucideIcons.check, size: 14)
                : null,
            onPressed: () {
              ref.read(utilityProvider.notifier).updateCustomShapeOpacity(
                    id: utility.id,
                    opacityPercent: percent,
                  );
            },
            child: Text(context.l10n.shapeToolsOpacityPercent(percent)),
          ),
      ],
    );
  }
}

class _CustomShapeColorItems extends ConsumerWidget {
  const _CustomShapeColorItems({required this.utility});

  final PlacedUtility utility;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentColorValue = utility.customColorValue;
    final colors = ref.watch(colorLibraryProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in colors)
          ShadContextMenuItem(
            leading: MenuColorSwatch(color: entry.color),
            trailing: currentColorValue == entry.color.toARGB32()
                ? const Icon(LucideIcons.check, size: 14)
                : null,
            onPressed: () {
              ref.read(utilityProvider.notifier).updateCustomShapeColor(
                    id: utility.id,
                    colorValue: entry.color.toARGB32(),
                  );
            },
            child: Text(colorLibraryEntryLabel(context.l10n, entry)),
          ),
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.palette, size: 14),
          onPressed: () async {
            final utilityNotifier = ref.read(utilityProvider.notifier);
            final picked = await showIcarusColorPickerDialog(
              context: context,
              initialColor: currentColorValue == null
                  ? Colors.white
                  : Color(currentColorValue),
              title: context.l10n.shapeToolsCustomColorTitle,
            );
            if (picked == null) return;
            utilityNotifier.updateCustomShapeColor(
              id: utility.id,
              colorValue: picked.toARGB32(),
            );
          },
          child: Text(context.l10n.shapeToolsCustomColorMenu),
        ),
      ],
    );
  }
}

String colorLibraryEntryLabel(AppLocalizations l10n, ColorLibraryEntry entry) {
  if (!entry.isCustom) {
    final color = entry.color.toARGB32();
    if (color == Colors.white.toARGB32()) return l10n.shapeToolsColorWhite;
    if (color == Colors.red.toARGB32()) return l10n.shapeToolsColorRed;
    if (color == Colors.blue.toARGB32()) return l10n.shapeToolsColorBlue;
    if (color == Colors.yellow.toARGB32()) return l10n.shapeToolsColorYellow;
    if (color == Colors.green.toARGB32()) return l10n.shapeToolsColorGreen;
  }

  final hex = (entry.color.toARGB32() & 0x00FFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();
  return entry.isCustom ? l10n.shapeToolsSavedColor(hex) : '#$hex';
}

class MenuColorSwatch extends StatelessWidget {
  const MenuColorSwatch({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white54),
      ),
    );
  }
}
