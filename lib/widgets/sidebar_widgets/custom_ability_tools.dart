import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_shape_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/selectable_icon_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

final _selectedShapeProvider =
    StateProvider<CustomShapeType>((ref) => CustomShapeType.circle);
final _shapeWidthProvider = StateProvider<double>((ref) => 5.0);
final _shapeHeightProvider = StateProvider<double>((ref) => 10.0);
final _shapeColorIndexProvider = StateProvider<int>((ref) => 0);

const List<Color> _shapeColors = [
  Colors.white,
  Colors.red,
  Colors.blue,
  Colors.yellow,
  Colors.green,
  Colors.orange,
  Colors.purple,
];

class CustomAbilityTools extends ConsumerWidget {
  const CustomAbilityTools({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedShape = ref.watch(_selectedShapeProvider);
    final widthMeters = ref.watch(_shapeWidthProvider);
    final heightMeters = ref.watch(_shapeHeightProvider);
    final colorIndex = ref.watch(_shapeColorIndexProvider);
    final color = _shapeColors[colorIndex];

    final utilityType = selectedShape == CustomShapeType.circle
        ? UtilityType.customCircle
        : UtilityType.customRectangle;

    final toolData = CustomAbilityToolData(
      type: utilityType,
      shape: selectedShape,
      widthMeters: widthMeters,
      heightMeters: selectedShape == CustomShapeType.circle
          ? widthMeters
          : heightMeters,
      color: color,
    );

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Custom Shapes"),
          const SizedBox(height: 8),
          _ShapeSelector(selectedShape: selectedShape),
          const SizedBox(height: 8),
          _ColorSelector(colorIndex: colorIndex),
          const SizedBox(height: 8),
          _SizeSlider(
            label: selectedShape == CustomShapeType.circle
                ? 'Diameter'
                : 'Width',
            value: widthMeters,
            onChanged: (v) =>
                ref.read(_shapeWidthProvider.notifier).state = v,
          ),
          if (selectedShape == CustomShapeType.rectangle) ...[
            const SizedBox(height: 4),
            _SizeSlider(
              label: 'Height',
              value: heightMeters,
              onChanged: (v) =>
                  ref.read(_shapeHeightProvider.notifier).state = v,
            ),
          ],
          const SizedBox(height: 8),
          _PlaceButton(toolData: toolData),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              "Drag or click to place",
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: Settings.tacticalVioletTheme.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShapeSelector extends ConsumerWidget {
  const _ShapeSelector({required this.selectedShape});

  final CustomShapeType selectedShape;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableIconButton(
              icon: const Icon(Icons.circle_outlined, size: 20),
              isSelected: selectedShape == CustomShapeType.circle,
              onPressed: () => ref.read(_selectedShapeProvider.notifier).state =
                  CustomShapeType.circle,
              tooltip: "Circle",
            ),
            const SizedBox(width: 2),
            SelectableIconButton(
              icon: const Icon(Icons.rectangle_outlined, size: 20),
              isSelected: selectedShape == CustomShapeType.rectangle,
              onPressed: () => ref.read(_selectedShapeProvider.notifier).state =
                  CustomShapeType.rectangle,
              tooltip: "Rectangle",
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorSelector extends ConsumerWidget {
  const _ColorSelector({required this.colorIndex});

  final int colorIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Color", style: TextStyle(fontSize: 13)),
        const SizedBox(height: 4),
        Row(
          children: [
            for (int i = 0; i < _shapeColors.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: GestureDetector(
                  onTap: () =>
                      ref.read(_shapeColorIndexProvider.notifier).state = i,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: _shapeColors[i],
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: i == colorIndex
                            ? Settings.tacticalVioletTheme.primary
                            : Settings.tacticalVioletTheme.border,
                        width: i == colorIndex ? 2.5 : 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _SizeSlider extends StatelessWidget {
  const _SizeSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ${value.toStringAsFixed(1)}m',
          style: const TextStyle(fontSize: 13),
        ),
        SizedBox(
          height: 28,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: Settings.tacticalVioletTheme.primary,
              thumbColor: Settings.tacticalVioletTheme.primary,
              inactiveTrackColor: Settings.tacticalVioletTheme.muted,
            ),
            child: Slider(
              value: value,
              min: 1.0,
              max: 50.0,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaceButton extends ConsumerWidget {
  const _PlaceButton({required this.toolData});

  final CustomAbilityToolData toolData;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Draggable<CustomAbilityToolData>(
      data: toolData,
      dragAnchorStrategy: (draggable, context, position) {
        final data = draggable.data as CustomAbilityToolData;
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
              .update(InteractionState.customAbility);
        }
      },
      feedback: Opacity(
        opacity: Settings.feedbackOpacity,
        child: ZoomTransform(
          child: CustomShapeWidget(
            shape: toolData.shape,
            widthMeters: toolData.widthMeters,
            heightMeters: toolData.heightMeters,
            id: null,
            color: toolData.color,
          ),
        ),
      ),
      child: ShadButton(
        width: double.infinity,
        onPressed: () {
          ref
              .read(interactionStateProvider.notifier)
              .update(InteractionState.navigation);
          const uuid = Uuid();
          ref.read(utilityProvider.notifier).addUtility(
                PlacedUtility(
                  position: const Offset(500, 500),
                  id: uuid.v4(),
                  type: toolData.type,
                  angle: _encodeCustomShapeData(toolData),
                ),
                customWidthMeters: toolData.widthMeters,
                customHeightMeters: toolData.heightMeters,
                customColor: toolData.color,
              );
        },
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 16),
            SizedBox(width: 4),
            Text('Place Shape'),
          ],
        ),
      ),
    );
  }
}

double _encodeCustomShapeData(CustomAbilityToolData data) {
  return data.widthMeters;
}
