import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/color_library_provider.dart';
import 'package:icarus/widgets/better_color_picker.dart';
import 'package:icarus/widgets/icarus_color_picker_style.dart';
import 'package:icarus/widgets/sidebar_widgets/color_buttons.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ColorLibrary extends ConsumerWidget {
  const ColorLibrary({
    super.key,
    required this.selectedColorValue,
    required this.onSelected,
    this.includeEmpty = false,
    this.emptyColor = const Color(0xFFC5C5C5),
  });

  final int? selectedColorValue;
  final ValueChanged<int?> onSelected;
  final bool includeEmpty;
  final Color emptyColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(colorLibraryProvider);
    final canAdd = ref.watch(
      colorLibraryControllerProvider.select(
        (colors) => colors.length < ColorLibraryController.customColorLimit,
      ),
    );

    return Wrap(
      children: [
        if (includeEmpty)
          _SwatchPadding(
            child: ColorButtons(
              height: 26,
              width: 26,
              color: emptyColor,
              isSelected: selectedColorValue == null,
              onTap: () => onSelected(null),
            ),
          ),
        for (final entry in entries)
          _SwatchPadding(
            child: entry.isCustom
                ? ShadContextMenuRegion(
                    items: [
                      ShadContextMenuItem(
                        leading: const Icon(LucideIcons.pencil, size: 14),
                        child: const Text('Edit'),
                        onPressed: () => _editColor(context, ref, entry),
                      ),
                      ShadContextMenuItem(
                        leading: Icon(
                          LucideIcons.trash2,
                          size: 14,
                          color: Settings.tacticalVioletTheme.destructive,
                        ),
                        child: Text(
                          'Delete',
                          style: TextStyle(
                            color: Settings.tacticalVioletTheme.destructive,
                          ),
                        ),
                        onPressed: () => ref
                            .read(colorLibraryControllerProvider.notifier)
                            .deleteColor(entry.customIndex!),
                      ),
                    ],
                    child: ColorButtons(
                      height: 26,
                      width: 26,
                      color: entry.color,
                      isSelected: selectedColorValue == entry.color.toARGB32(),
                      onTap: () => onSelected(entry.color.toARGB32()),
                    ),
                  )
                : ColorButtons(
                    height: 26,
                    width: 26,
                    color: entry.color,
                    isSelected: selectedColorValue == entry.color.toARGB32(),
                    onTap: () => onSelected(entry.color.toARGB32()),
                  ),
          ),
        if (canAdd)
          _SwatchPadding(
            child: ColorPickerButton(
              onTap: () => _addColor(context, ref),
            ),
          ),
      ],
    );
  }

  Future<void> _addColor(BuildContext context, WidgetRef ref) async {
    final picked = await _showColorLibraryDialog(
      context: context,
      initialColor: Colors.white,
      title: 'Add color',
    );
    if (picked == null) return;
    await ref.read(colorLibraryControllerProvider.notifier).addColor(picked);
    onSelected(picked.toARGB32());
  }

  Future<void> _editColor(
    BuildContext context,
    WidgetRef ref,
    ColorLibraryEntry entry,
  ) async {
    final picked = await _showColorLibraryDialog(
      context: context,
      initialColor: entry.color,
      title: 'Edit color',
    );
    if (picked == null) return;
    await ref
        .read(colorLibraryControllerProvider.notifier)
        .updateColor(entry.customIndex!, picked);
    onSelected(picked.toARGB32());
  }
}

Future<Color?> _showColorLibraryDialog({
  required BuildContext context,
  required Color initialColor,
  required String title,
}) async {
  var workingColor = initialColor;
  return showShadDialog<Color>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ShadDialog(
            title: Text(title),
            actions: [
              ShadButton.secondary(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              ShadButton(
                onPressed: () => Navigator.of(context).pop(workingColor),
                child: const Text('Apply'),
              ),
            ],
            child: Material(
              color: Colors.transparent,
              child: SizedBox(
                width: 320,
                child: BetterColorPicker(
                  value: workingColor,
                  initialMode: BetterColorPickerMode.hsv,
                  style: icarusColorPickerStyle,
                  onChanging: (color) {
                    setState(() {
                      workingColor = color;
                    });
                  },
                  onChanged: (color) {
                    setState(() {
                      workingColor = color;
                    });
                  },
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class _SwatchPadding extends StatelessWidget {
  const _SwatchPadding({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: child,
    );
  }
}

class ColorPickerButton extends StatefulWidget {
  const ColorPickerButton({
    super.key,
    required this.onTap,
  });

  final VoidCallback onTap;

  @override
  State<ColorPickerButton> createState() => _ColorPickerButtonState();
}

class _ColorPickerButtonState extends State<ColorPickerButton> {
  Color _borderColor = Colors.transparent;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 26,
      width: 26,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        border: Border.all(
          color: _borderColor,
          width: 3,
          strokeAlign: BorderSide.strokeAlignCenter,
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _borderColor = Colors.white),
        onExit: (_) => setState(() => _borderColor = Colors.transparent),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Center(
            child: Container(
              height: 24,
              width: 24,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(Radius.circular(4)),
                border: Border.all(
                  color: const Color(0xFF272727),
                  width: 1,
                  strokeAlign: BorderSide.strokeAlignCenter,
                ),
              ),
              child: Icon(
                LucideIcons.plus,
                size: 16,
                color: Settings.tacticalVioletTheme.foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
