import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/placement_center_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/sidebar_widgets/color_buttons.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

class TextTools extends ConsumerStatefulWidget {
  const TextTools({super.key});

  @override
  ConsumerState<TextTools> createState() => _TextToolsState();
}

class _TextToolsState extends ConsumerState<TextTools> {
  static const List<Color> _colorOptions = [
    Color(0xFF22C55E),
    Color(0xFF3B82F6),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFFA855F7),
  ];

  int? _selectedTagColorValue;

  @override
  Widget build(BuildContext context) {
    final draggableData = TextToolData.defaults(
      tagColorValue: _selectedTagColorValue,
    );

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Tag Color"),
          const SizedBox(height: 4),
          _buildColorPicker(),
          const SizedBox(height: 4),
          Draggable<TextToolData>(
            data: draggableData,
            dragAnchorStrategy: (draggable, context, position) {
              final data = draggable.data as TextToolData;
              return data.getScaledCenterPoint(
                scaleFactor: CoordinateSystem.instance.scaleFactor,
                screenZoom: ref.read(screenZoomProvider),
              );
            },
            onDragStarted: () {
              final interactionState = ref.read(interactionStateProvider);
              if (interactionState == InteractionState.drawing ||
                  interactionState == InteractionState.erasing) {
                ref
                    .read(interactionStateProvider.notifier)
                    .update(InteractionState.navigation);
              }
            },
            feedback: Opacity(
              opacity: Settings.feedbackOpacity,
              child: ZoomTransform(
                child: TextWidget(
                  id: "text-tool-preview",
                  text: "Write here...",
                  size: draggableData.width,
                  fontSize: 16,
                  tagColorValue: draggableData.tagColorValue,
                  isFeedback: true,
                ),
              ),
            ),
            child: SizedBox(
              width: double.infinity,
              child: ShadButton(
                backgroundColor: Settings.tacticalVioletTheme.primary,
                onPressed: _placeAtCenter,
                child: const Text("+ Place Text"),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              "Drag or click to place",
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: Settings.tacticalVioletTheme.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorPicker() {
    return Wrap(
      children: [
        Padding(
          padding: const EdgeInsets.all(4.0),
          child: ColorButtons(
            height: 26,
            width: 26,
            color: const Color(0xFFC5C5C5),
            isSelected: _selectedTagColorValue == null,
            onTap: () => setState(() => _selectedTagColorValue = null),
          ),
        ),
        for (final color in _colorOptions)
          Padding(
            padding: const EdgeInsets.all(4.0),
            child: ColorButtons(
              height: 26,
              width: 26,
              color: color,
              isSelected: _selectedTagColorValue == color.toARGB32(),
              onTap: () =>
                  setState(() => _selectedTagColorValue = color.toARGB32()),
            ),
          ),
      ],
    );
  }

  void _placeAtCenter() {
    const uuid = Uuid();
    final toolData =
        TextToolData.defaults(tagColorValue: _selectedTagColorValue);
    final placementCenter = ref.read(placementCenterProvider);
    final centeredTopLeft =
        placementCenter - Offset(toolData.width / 2, toolData.height / 2);

    ref.read(textProvider.notifier).addText(
          PlacedText(
            position: centeredTopLeft,
            id: uuid.v4(),
            size: toolData.width,
            fontSize: 16,
            sizeVersion: worldSizedMediaVersion,
            tagColorValue: toolData.tagColorValue,
          ),
        );
  }
}
