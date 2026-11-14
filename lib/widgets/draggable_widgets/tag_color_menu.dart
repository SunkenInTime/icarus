import 'package:flutter/material.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_shape_context_menu.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The gray a text box or picture's tag is drawn in while it has no color
/// (`tagColorValue` null).
const untaggedColor = Color(0xFFC5C5C5);

/// A color a tag can be given, under the name the menu lists it by.
typedef TagColorChoice = ({Color color, String label});

/// "Tag color" on a text box or picture's right-click menu: gray, then
/// [choices], in a submenu with the tag's own color ticked.
///
/// [current] is the stored `tagColorValue` and [onPicked] gets the next one;
/// gray is null in both, as an item that was never tagged has it.
ShadContextMenuItem buildTagColorMenuItem(
  BuildContext context, {
  required int? current,
  required List<TagColorChoice> choices,
  required ValueChanged<int?> onPicked,
}) {
  final l10n = context.l10n;
  final entries = <({int? value, Color color, String label})>[
    (value: null, color: untaggedColor, label: l10n.canvasItemTagColorGray),
    for (final choice in choices)
      (
        value: choice.color.toARGB32(),
        color: choice.color,
        label: choice.label,
      ),
  ];
  // A tag keeps a saved color after the color leaves the library, so it
  // still finds its own color in the list, ticked.
  if (current != null && entries.every((entry) => entry.value != current)) {
    final hex =
        (current & 0x00FFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
    entries.add((value: current, color: Color(current), label: '#$hex'));
  }

  return ShadContextMenuItem(
    leading: MenuColorSwatch(
      color: current == null ? untaggedColor : Color(current),
    ),
    items: [
      for (final entry in entries)
        ShadContextMenuItem(
          leading: MenuColorSwatch(color: entry.color),
          trailing: entry.value == current
              ? const Icon(LucideIcons.check, size: 14)
              : null,
          onPressed: () => onPicked(entry.value),
          child: Text(entry.label),
        ),
    ],
    child: Text(l10n.canvasItemTagColorMenu),
  );
}
