import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/color_library_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/adjacent_page_copy_menu.dart';
import 'package:icarus/widgets/sidebar_widgets/color_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

List<ShadContextMenuItem> buildCustomShapeContextMenuItems(
  WidgetRef ref,
  PlacedUtility utility,
) {
  final currentColorValue = utility.customColorValue;

  return [
    ShadContextMenuItem(
      leading: _ColorSwatch(
        color: currentColorValue == null
            ? Colors.transparent
            : Color(currentColorValue),
      ),
      items: [_CustomShapeColorItems(utility: utility)],
      child: const Text('Color'),
    ),
    ...buildAdjacentPageCopyMenuItems(ref, utility.id),
  ];
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
            leading: _ColorSwatch(color: entry.color),
            trailing: currentColorValue == entry.color.toARGB32()
                ? const Icon(LucideIcons.check, size: 14)
                : null,
            onPressed: () {
              ref.read(utilityProvider.notifier).updateCustomShapeColor(
                    id: utility.id,
                    colorValue: entry.color.toARGB32(),
                  );
            },
            child: Text(_colorLabel(entry)),
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
              title: 'Custom color',
            );
            if (picked == null) return;
            utilityNotifier.updateCustomShapeColor(
              id: utility.id,
              colorValue: picked.toARGB32(),
            );
          },
          child: const Text('Custom color…'),
        ),
      ],
    );
  }
}

String _colorLabel(ColorLibraryEntry entry) {
  if (!entry.isCustom) {
    if (entry.color.toARGB32() == Colors.white.toARGB32()) return 'White';
    if (entry.color.toARGB32() == Colors.red.toARGB32()) return 'Red';
    if (entry.color.toARGB32() == Colors.blue.toARGB32()) return 'Blue';
    if (entry.color.toARGB32() == Colors.yellow.toARGB32()) return 'Yellow';
    if (entry.color.toARGB32() == Colors.green.toARGB32()) return 'Green';
  }

  final hex = (entry.color.toARGB32() & 0x00FFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();
  return entry.isCustom ? 'Saved #$hex' : '#$hex';
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color});

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
