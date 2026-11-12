import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/default_placement.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/placement_center_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:icarus/widgets/numeric_drag_input.dart';
import 'package:icarus/widgets/press_scale.dart';
import 'package:icarus/widgets/sidebar_widgets/color_library.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_rectangle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

enum _CustomShapeKind { circle, rectangle, zone }

class CustomShapeTools extends ConsumerStatefulWidget {
  const CustomShapeTools({super.key});

  @override
  ConsumerState<CustomShapeTools> createState() => _CustomShapeToolsState();
}

class _CustomShapeToolsState extends ConsumerState<CustomShapeTools> {
  static const double _defaultCircleDiameterMeters = 10;
  static const double _defaultRectangleWidthMeters = 6;
  static const double _defaultRectangleLengthMeters = 12;
  static const int _defaultOpacityPercent = 30;
  static const int _defaultColorValue = 0xFF22C55E;

  _CustomShapeKind _shape = _CustomShapeKind.circle;
  double _diameterMeters = _defaultCircleDiameterMeters;
  double _rectWidthMeters = _defaultRectangleWidthMeters;
  double _rectLengthMeters = _defaultRectangleLengthMeters;
  int _opacityPercent = _defaultOpacityPercent;
  Color _selectedColor = const Color(_defaultColorValue);

  @override
  Widget build(BuildContext context) {
    final currentMap =
        ref.watch(mapProvider.select((state) => state.currentMap));
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final draggableData = _buildToolData(mapScale);

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.shapeToolsTitle),
          const SizedBox(height: 4),
          _buildShapeSelector(),
          const SizedBox(height: 4),
          _buildPanel(draggableData, mapScale),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              // A zone colours the map itself, where a circle or a rectangle
              // is drawn over everything.
              _shape == _CustomShapeKind.zone
                  ? context.l10n.shapeToolsZoneHint
                  : context.l10n.sidebarDragOrClickToPlace,
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
            _kindButton(
              _CustomShapeKind.circle,
              LucideIcons.circle,
              context.l10n.shapeToolsCircle,
            ),
            _kindButton(
              _CustomShapeKind.rectangle,
              LucideIcons.square,
              context.l10n.shapeToolsRectangle,
            ),
            _kindButton(
              _CustomShapeKind.zone,
              LucideIcons.squareDashed,
              context.l10n.shapeToolsZone,
            ),
          ],
        ),
      ),
    );
  }

  /// One of the kinds, named: an icon alone does not say that a zone colours
  /// the map where the others are drawn over it.
  Widget _kindButton(_CustomShapeKind kind, IconData icon, String label) {
    final selected = _shape == kind;
    // The raised fill sits outside the Shad button, so the press goes around
    // both and the Shad button's own press is turned off.
    Widget button = ShadButtonWrapper(
      wrap: (context, {required pressable, required child}) => child,
      child: ShadButton.secondary(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(icon, size: 20),
        backgroundColor: selected ? Colors.transparent : null,
        hoverBackgroundColor: selected ? Colors.transparent : null,
        onPressed: () => setState(() => _shape = kind),
        child: Text(label),
      ),
    );
    if (selected) {
      button = DecoratedBox(
        decoration: Settings.raised(Settings.tacticalVioletTheme.primary, 6),
        child: button,
      );
    }
    return PressScale(child: button);
  }

  Widget _buildPanel(CustomShapeToolData draggableData, double mapScale) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_shape == _CustomShapeKind.circle) ...[
          Text(l10n.shapeToolsDiameterLabel),
          const SizedBox(height: 4),
          SizedBox(
            height: 40,
            // width: 100,
            child: NumericDragInput(
              value: _diameterMeters,
              onChanged: (v) => setState(() => _diameterMeters = v),
              min: 1.0,
              max: CustomCircleUtility.maxDiameterMeters,
              label: l10n.shapeToolsDiameterShortLabel,
              hintText: l10n.shapeToolsDiameterHint,
              suffix: 'm',
            ),
          ),
          const SizedBox(height: 4),
        ] else ...[
          Text(l10n.shapeToolsDimensionsLabel),
          const SizedBox(height: 4),
          Row(spacing: 4, children: [
            Flexible(
              child: SizedBox(
                height: 40,
                // width: 100,
                child: NumericDragInput(
                  value: _rectLengthMeters,
                  onChanged: (v) => setState(() => _rectLengthMeters = v),
                  min: 1,
                  max: CustomRectangleUtility.maxSideMeters,
                  label: l10n.shapeToolsLengthShortLabel,
                  hintText: l10n.shapeToolsLengthHint,
                  suffix: 'm',
                ),
              ),
            ),
            Flexible(
              child: SizedBox(
                height: 40,
                // width: 100,
                child: NumericDragInput(
                  value: _rectWidthMeters,
                  onChanged: (v) => setState(() => _rectWidthMeters = v),
                  min: 0.5,
                  max: CustomRectangleUtility.maxSideMeters,
                  label: l10n.shapeToolsWidthShortLabel,
                  hintText: l10n.shapeToolsWidthHint,
                  suffix: 'm',
                ),
              ),
            ),
          ]),
          const SizedBox(height: 4),
        ],
        Text(l10n.shapeToolsOpacityLabel),
        const SizedBox(height: 4),
        SizedBox(
          height: 40,
          // width: 100,
          child: NumericDragInput(
            value: _opacityPercent.toDouble(),
            onChanged: (v) => setState(() => _opacityPercent = v.round()),
            min: 5,
            max: 80,
            leading: Icon(LucideIcons.droplet,
                size: 16, color: Settings.tacticalVioletTheme.mutedForeground),
            // label: 'O',
            hintText: l10n.shapeToolsOpacityHint,
            suffix: '%',
          ),
        ),
        const SizedBox(height: 4),
        Text(l10n.shapeToolsColorLabel),
        const SizedBox(height: 4),
        _buildColorPicker(),
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
            child: ZoomTransform(child: _buildPreview(mapScale)),
          ),
          child: SizedBox(
            width: double.infinity,
            child: ShadButton(
              backgroundColor: Settings.tacticalVioletTheme.primary,
              onPressed: () => _placeAtCenter(mapScale),
              child: Text(switch (_shape) {
                _CustomShapeKind.circle => l10n.shapeToolsPlaceCircleButton,
                _CustomShapeKind.rectangle =>
                  l10n.shapeToolsPlaceRectangleButton,
                _CustomShapeKind.zone => l10n.shapeToolsPlaceZoneButton,
              }),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildColorPicker() {
    return ColorLibrary(
      selectedColorValue: _selectedColor.toARGB32(),
      onSelected: (colorValue) {
        if (colorValue == null) return;
        setState(() => _selectedColor = Color(colorValue));
      },
    );
  }

  CustomShapeToolData _buildToolData(double mapScale) {
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
      isZone: _shape == _CustomShapeKind.zone,
    );
  }

  void _placeAtCenter(double mapScale) {
    const uuid = Uuid();
    final toolData = _buildToolData(mapScale);
    final placementCenter = ref.read(placementCenterProvider);
    final centeredTopLeft = DefaultPlacement.topLeftFromVirtualAnchor(
      viewportCenter: placementCenter,
      anchorVirtual: toolData.centerPoint,
    );

    final placedUtility = toolData.type == UtilityType.customCircle
        ? PlacedUtility(
            position: centeredTopLeft,
            id: uuid.v4(),
            type: toolData.type,
            customDiameter: toolData.diameterMeters,
            customColorValue: toolData.colorValue,
            customOpacityPercent: toolData.opacityPercent,
          )
        : PlacedUtility(
            position: centeredTopLeft,
            id: uuid.v4(),
            type: toolData.type,
            customWidth: toolData.widthMeters,
            customLength: toolData.rectLengthMeters,
            customColorValue: toolData.colorValue,
            customOpacityPercent: toolData.opacityPercent,
            isZone: toolData.isZone,
          );
    ref.read(utilityProvider.notifier).addUtility(placedUtility);
  }

  Widget _buildPreview(double mapScale) {
    if (_shape == _CustomShapeKind.circle) {
      return CustomCircleUtilityWidget(
        id: null,
        diameterMeters: _diameterMeters,
        colorValue: _selectedColor.toARGB32(),
        opacityPercent: _opacityPercent,
        mapScale: mapScale,
      );
    }
    return CustomRectangleUtilityWidget(
      id: null,
      widthMeters: _rectWidthMeters,
      rectLengthMeters: _rectLengthMeters,
      colorValue: _selectedColor.toARGB32(),
      opacityPercent: _opacityPercent,
      mapScale: mapScale,
      isZone: _shape == _CustomShapeKind.zone,
    );
  }
}
