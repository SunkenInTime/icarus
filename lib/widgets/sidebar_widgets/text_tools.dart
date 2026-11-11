import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/placement_center_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/sidebar_widgets/color_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

class TextTools extends ConsumerStatefulWidget {
  const TextTools({super.key});

  @override
  ConsumerState<TextTools> createState() => _TextToolsState();
}

class _TextToolsState extends ConsumerState<TextTools> {
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
          Text(context.l10n.sidebarTagColorLabel),
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
                  text: context.l10n.canvasItemTextPlaceholder,
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
                child: Text(context.l10n.sidebarPlaceTextButton),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              context.l10n.sidebarDragOrClickToPlace,
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
    return ColorLibrary(
      includeEmpty: true,
      selectedColorValue: _selectedTagColorValue,
      onSelected: (colorValue) => setState(
        () => _selectedTagColorValue = colorValue,
      ),
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
