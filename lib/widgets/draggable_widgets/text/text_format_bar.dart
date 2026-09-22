import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_markup.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ToggleBoldIntent extends Intent {
  const ToggleBoldIntent();
}

class ToggleItalicIntent extends Intent {
  const ToggleItalicIntent();
}

class TextFormatBar extends StatelessWidget {
  const TextFormatBar({
    super.key,
    required this.controller,
    required this.onApply,
    required this.tapRegionGroupId,
  });

  static const double _buttonSize = 28;
  static const double _padding = 3;

  static const double _gap = 2;

  // Five evenly spaced buttons inside the padding and the 1px border. The
  // overlay positions the bar from these.
  static const double width = 5 * _buttonSize + 4 * _gap + 2 * _padding + 2;
  static const double height = _buttonSize + 2 * _padding + 2;

  final TextEditingController controller;
  final ValueChanged<TextEditingValue> onApply;
  final Object tapRegionGroupId;

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      child: TapRegion(
        groupId: tapRegionGroupId,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final value = controller.value;
            const style =
                EditorToolbarButtonStyle(size: _buttonSize, iconSize: 16);
            return Container(
              width: width,
              height: height,
              padding: const EdgeInsets.all(_padding),
              decoration: BoxDecoration(
                color: Settings.tacticalVioletTheme.card,
                // Tighter than the docked toolbar: the bar sits against the
                // text card's near-square corners.
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Settings.tacticalVioletTheme.border),
                boxShadow: const [Settings.floatingMenuShadow],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: _gap,
                children: [
                  EditorToolbarButton(
                    style: style,
                    showTooltip: false,
                    tooltip: 'Bold (Ctrl+B)',
                    active: MarkupEditing.isInlineActive(value, '**'),
                    onPressed: () => onApply(
                      MarkupEditing.toggleInline(value, '**'),
                    ),
                    icon: const Icon(LucideIcons.bold200),
                  ),
                  EditorToolbarButton(
                    style: style,
                    showTooltip: false,
                    tooltip: 'Italic (Ctrl+I)',
                    active: MarkupEditing.isInlineActive(value, '*'),
                    onPressed: () => onApply(
                      MarkupEditing.toggleInline(value, '*'),
                    ),
                    icon: const Icon(LucideIcons.italic200),
                  ),
                  EditorToolbarButton(
                    style: style,
                    showTooltip: false,
                    tooltip: 'Bullet list',
                    active: MarkupEditing.lineKindAt(value) ==
                        MarkupLineKind.bullet,
                    onPressed: () => onApply(
                      MarkupEditing.toggleLineKind(
                          value, MarkupLineKind.bullet),
                    ),
                    icon: const Icon(LucideIcons.list200),
                  ),
                  EditorToolbarButton(
                    style: style,
                    showTooltip: false,
                    tooltip: 'Numbered list',
                    active: MarkupEditing.lineKindAt(value) ==
                        MarkupLineKind.numbered,
                    onPressed: () => onApply(
                      MarkupEditing.toggleLineKind(
                        value,
                        MarkupLineKind.numbered,
                      ),
                    ),
                    icon: const Icon(LucideIcons.listOrdered200),
                  ),
                  EditorToolbarButton(
                    style: style,
                    showTooltip: false,
                    tooltip: 'Heading',
                    active: MarkupEditing.lineKindAt(value) ==
                        MarkupLineKind.heading,
                    onPressed: () => onApply(
                      MarkupEditing.toggleLineKind(
                          value, MarkupLineKind.heading),
                    ),
                    icon: const Icon(LucideIcons.heading200),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
