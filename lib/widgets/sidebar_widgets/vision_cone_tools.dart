import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/default_placement.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/placement_center_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

class VisionConeTools extends ConsumerWidget {
  const VisionConeTools({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Vision Cones"),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Settings.tacticalVioletTheme.card,
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              border: Border.all(
                color: Settings.tacticalVioletTheme.border,
                width: 1,
              ),
              boxShadow: const [Settings.cardForegroundBackdrop],
            ),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _VisionConePresetTile(
                        type: UtilityType.viewCone180,
                        label: '180',
                        icon: LucideIcons.eye,
                      ),
                      SizedBox(width: 2),
                      _VisionConePresetTile(
                        type: UtilityType.viewCone90,
                        label: '90',
                        icon: LucideIcons.scanEye,
                      ),
                      SizedBox(width: 2),
                      _VisionConePresetTile(
                        type: UtilityType.viewCone40,
                        label: '40',
                        icon: LucideIcons.focus,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              "Drag to place",
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

class _VisionConePresetTile extends ConsumerWidget {
  const _VisionConePresetTile({
    required this.type,
    required this.label,
    required this.icon,
  });

  final UtilityType type;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewConeUtility = UtilityData.getViewConePreset(type);
    final data = VisionConeToolData.fromType(type);

    return Draggable<VisionConeToolData>(
      data: data,
      dragAnchorStrategy: (draggable, context, position) {
        return viewConeUtility.getScaledCenterPoint(
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
          child: viewConeUtility.createWidget(
            id: null,
            rotation: 0,
            length: viewConeUtility.defaultLength,
          ),
        ),
      ),
      child: ShadTooltip(
        builder: (context) => Text("View Cone $label°"),
        child: ShadIconButton.secondary(
          width: 46,
          height: 46,
          icon: Icon(icon, size: 20),
          onPressed: () {
            ref
                .read(interactionStateProvider.notifier)
                .update(InteractionState.navigation);
            const uuid = Uuid();
            final placementCenter = ref.read(placementCenterProvider);
            final centeredTopLeft = DefaultPlacement.topLeftFromVirtualAnchor(
              viewportCenter: placementCenter,
              anchorVirtual: data.centerPoint,
            );
            ref.read(utilityProvider.notifier).addUtility(
                  PlacedUtility(
                    position: centeredTopLeft,
                    id: uuid.v4(),
                    type: type,
                    angle: data.angle,
                  ),
                );
          },
        ),
      ),
    );
  }
}
