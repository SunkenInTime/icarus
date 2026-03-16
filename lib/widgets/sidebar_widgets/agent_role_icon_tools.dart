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
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/team_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

class AgentRoleIconTools extends ConsumerWidget {
  const AgentRoleIconTools({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Agent Role Icons"),
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
              padding: EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RoleIconTile(
                    type: UtilityType.controller,
                    label: 'Controller',
                  ),
                  SizedBox(width: 8),
                  _RoleIconTile(
                    type: UtilityType.duelist,
                    label: 'Duelist',
                  ),
                  SizedBox(width: 8),
                  _RoleIconTile(
                    type: UtilityType.initiator,
                    label: 'Initiator',
                  ),
                  SizedBox(width: 8),
                  _RoleIconTile(
                    type: UtilityType.sentinel,
                    label: 'Sentinel',
                  ),
                ],
              ),
            ),
          ),
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

class _RoleIconTile extends ConsumerWidget {
  const _RoleIconTile({
    required this.type,
    required this.label,
  });

  final UtilityType type;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final abilitySize =
        ref.watch(strategySettingsProvider.select((state) => state.abilitySize));
    final toolData = RoleIconToolData.fromType(
      type: type,
      abilitySize: abilitySize,
    );
    final isAlly = ref.watch(teamProvider);
    final utility = UtilityData.utilityWidgets[type]!;

    return Draggable<RoleIconToolData>(
      data: toolData,
      dragAnchorStrategy: (draggable, context, position) {
        final data = draggable.data as RoleIconToolData;
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
          child: utility.createWidget(
            id: null,
            isAlly: isAlly,
            abilitySize: abilitySize,
          ),
        ),
      ),
      child: ShadTooltip(
        builder: (context) => Text(label),
        child: GestureDetector(
          onTap: () => _placeAtCenter(ref, toolData),
          child: utility.createWidget(
            id: null,
            isAlly: isAlly,
            abilitySize: abilitySize,
          ),
        ),
      ),
    );
  }

  void _placeAtCenter(WidgetRef ref, RoleIconToolData toolData) {
    ref
        .read(interactionStateProvider.notifier)
        .update(InteractionState.navigation);

    const uuid = Uuid();
    final placementCenter = ref.read(placementCenterProvider);
    final centeredTopLeft = DefaultPlacement.topLeftFromVirtualAnchor(
      viewportCenter: placementCenter,
      anchorVirtual: toolData.centerPoint,
    );

    ref.read(utilityProvider.notifier).addUtility(
          PlacedUtility(
            position: centeredTopLeft,
            id: uuid.v4(),
            type: type,
            isAlly: ref.read(teamProvider),
          ),
        );
  }
}
