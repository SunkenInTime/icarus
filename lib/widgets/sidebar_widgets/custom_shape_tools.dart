import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:icarus/widgets/selectable_icon_button.dart';
import 'package:icarus/widgets/sidebar_widgets/color_buttons.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_rectangle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

enum _CustomShapeKind { circle, rectangle }

class CustomShapeTools extends ConsumerStatefulWidget {
  const CustomShapeTools({super.key});

  @override
  ConsumerState<CustomShapeTools> createState() => _CustomShapeToolsState();
}

class _CustomShapeToolsState extends ConsumerState<CustomShapeTools> {
  static const List<Color> _colorOptions = [
    Color(0xFF22C55E),
    Color(0xFF3B82F6),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFFA855F7),
  ];

  _CustomShapeKind _shape = _CustomShapeKind.circle;
  double _diameterMeters = CustomCircleUtility.defaultDiameterMeters;
  double _rectWidthMeters = CustomRectangleUtility.defaultWidthMeters;
  double _rectLengthMeters = CustomRectangleUtility.defaultLengthMeters;
  int _opacityPercent = CustomCircleUtility.defaultOpacityPercent;
  Color _selectedColor = const Color(CustomCircleUtility.defaultColorValue);

  @override
  Widget build(BuildContext context) {
    final draggableData = _buildToolData();

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Custom Shapes"),
          const SizedBox(height: 4),
          _buildShapeSelector(),
          const SizedBox(height: 4),
          _buildPanel(draggableData),
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

  Widget _buildShapeSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(
          color: Settings.tacticalVioletTheme.border,
          width: 1,
        ),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      child: Padding(
        padding: const EdgeInsets.all(2.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            SelectableIconButton(
              icon: const Icon(Icons.circle_outlined, size: 20),
              isSelected: _shape == _CustomShapeKind.circle,
              onPressed: () => setState(() => _shape = _CustomShapeKind.circle),
            ),
            SelectableIconButton(
              icon: const Icon(Icons.crop_square, size: 20),
              isSelected: _shape == _CustomShapeKind.rectangle,
              onPressed: () =>
                  setState(() => _shape = _CustomShapeKind.rectangle),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(CustomShapeToolData draggableData) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Color"),
        const SizedBox(height: 4),
        _buildColorPicker(),
        const SizedBox(height: 4),
        if (_shape == _CustomShapeKind.circle)
          _slider(
            label: "Diameter: ${_diameterMeters.toStringAsFixed(1)}m",
            value: _diameterMeters,
            min: 1.0,
            max: 40.0,
            onChanged: (value) => setState(() => _diameterMeters = value),
          )
        else ...[
          _slider(
            label: "Length: ${_rectLengthMeters.toStringAsFixed(1)}m",
            value: _rectLengthMeters,
            min: 1.0,
            max: 60.0,
            onChanged: (value) => setState(() => _rectLengthMeters = value),
          ),
          _slider(
            label: "Width: ${_rectWidthMeters.toStringAsFixed(1)}m",
            value: _rectWidthMeters,
            min: 0.5,
            max: 30.0,
            onChanged: (value) => setState(() => _rectWidthMeters = value),
          ),
        ],
        _slider(
          label: "Opacity: $_opacityPercent%",
          value: _opacityPercent.toDouble(),
          min: 5,
          max: 80,
          onChanged: (value) => setState(() => _opacityPercent = value.round()),
        ),
        const SizedBox(height: 4),
        Draggable<CustomShapeToolData>(
              data: draggableData,
              dragAnchorStrategy: (draggable, context, position) {
                final data = draggable.data as CustomShapeToolData;
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
                child: ZoomTransform(child: _buildPreview()),
              ),
              child: SizedBox(
                width: double.infinity,
                child: ShadButton(
                  backgroundColor: Settings.tacticalVioletTheme.primary,
                  onPressed: _placeAtCenter,
                  child: const Text("+ Place Shape"),
                ),
              ),
            ),
      ],
    );
  }

  Widget _buildColorPicker() {
    return Row(
      children: [
        for (final color in _colorOptions)
          Padding(
            padding: const EdgeInsets.all(4.0),
            child: ColorButtons(
              height: 26,
              width: 26,
              color: color,
              isSelected: _selectedColor == color,
              onTap: () => setState(() => _selectedColor = color),
            ),
          ),
      ],
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }

  CustomShapeToolData _buildToolData() {
    final mapScale = ref.read(mapProvider.notifier).mapScale;
    if (_shape == _CustomShapeKind.circle) {
      return CustomShapeToolData.circle(
        diameterMeters: _diameterMeters,
        mapScale: mapScale,
        colorValue: _selectedColor.toARGB32(),
        opacityPercent: _opacityPercent,
      );
    }
    return CustomShapeToolData.rectangle(
      widthMeters: _rectWidthMeters,
      rectLengthMeters: _rectLengthMeters,
      mapScale: mapScale,
      colorValue: _selectedColor.toARGB32(),
      opacityPercent: _opacityPercent,
    );
  }

  void _placeAtCenter() {
    const uuid = Uuid();
    final toolData = _buildToolData();

    ref.read(utilityProvider.notifier).addUtility(
          PlacedUtility(
            position: const Offset(500, 500),
            id: uuid.v4(),
            type: toolData.type,
            customDiameter:
                toolData.diameterMeters > 0 ? toolData.diameterMeters : null,
            customWidth: toolData.widthMeters > 0 ? toolData.widthMeters : null,
            customLength: toolData.rectLengthMeters > 0
                ? toolData.rectLengthMeters
                : null,
            customColorValue: toolData.colorValue,
            customOpacityPercent: toolData.opacityPercent,
          ),
        );
  }

  Widget _buildPreview() {
    if (_shape == _CustomShapeKind.circle) {
      return CustomCircleUtilityWidget(
        id: null,
        diameterMeters: _diameterMeters,
        colorValue: _selectedColor.toARGB32(),
        opacityPercent: _opacityPercent,
        mapScale: ref.read(mapProvider.notifier).mapScale,
      );
    }
    return CustomRectangleUtilityWidget(
      id: null,
      widthMeters: _rectWidthMeters,
      rectLengthMeters: _rectLengthMeters,
      colorValue: _selectedColor.toARGB32(),
      opacityPercent: _opacityPercent,
      mapScale: ref.read(mapProvider.notifier).mapScale,
    );
  }
}
