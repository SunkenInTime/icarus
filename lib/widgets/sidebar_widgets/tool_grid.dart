import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/widgets/asset_svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/default_placement.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/placement_center_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/dialogs/upload_image_dialog.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/selectable_icon_button.dart';
import 'package:icarus/widgets/sidebar_widgets/agent_role_icon_tools.dart';
import 'package:icarus/widgets/sidebar_widgets/custom_shape_tools.dart';
import 'package:icarus/widgets/sidebar_widgets/drawing_tools.dart';
import 'package:icarus/widgets/sidebar_widgets/text_tools.dart';
import 'package:icarus/widgets/sidebar_widgets/vision_cone_tools.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/widgets/platform_feature_toast.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

enum _ContextBarMode {
  drawing,
  visionCone,
  customShapes,
  textTools,
  roleIcons,
  none
}

class BottomContextBar extends ConsumerWidget {
  const BottomContextBar({super.key});

  static const Duration _animationDuration = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interactionState = ref.watch(interactionStateProvider);

    final mode = switch (interactionState) {
      InteractionState.drawing => _ContextBarMode.drawing,
      InteractionState.visionCone => _ContextBarMode.visionCone,
      InteractionState.customShapes => _ContextBarMode.customShapes,
      InteractionState.textTools => _ContextBarMode.textTools,
      InteractionState.roleIcons => _ContextBarMode.roleIcons,
      _ => _ContextBarMode.none,
    };

    return ClipRect(
      child: AnimatedSize(
        duration: _animationDuration,
        curve: Settings.easeOut,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: _animationDuration,
          switchInCurve: Settings.easeOut,
          switchOutCurve: Settings.easeOut.flipped,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
          child: _buildContent(mode),
        ),
      ),
    );
  }

  Widget _buildContent(_ContextBarMode mode) {
    return switch (mode) {
      _ContextBarMode.drawing => const DrawingTools(key: ValueKey('drawing')),
      _ContextBarMode.visionCone =>
        const VisionConeTools(key: ValueKey('visionCone')),
      _ContextBarMode.customShapes =>
        const CustomShapeTools(key: ValueKey('customShapes')),
      _ContextBarMode.textTools => const TextTools(key: ValueKey('textTools')),
      _ContextBarMode.roleIcons =>
        const AgentRoleIconTools(key: ValueKey('roleIcons')),
      _ContextBarMode.none => const SizedBox.shrink(key: ValueKey('none')),
    };
  }
}

class ToolGrid extends ConsumerWidget {
  const ToolGrid({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final currentInteractionState = ref.watch(interactionStateProvider);
    final shortcutBindings =
        ref.watch(appPreferencesProvider).customShortcutBindings;
    String shortcutLabel(IcarusShortcutAction action) {
      return ShortcutInfo.displayLabelFor(action.name, shortcutBindings);
    }

    // void showImageDialog() {
    //   showDialog(
    //     context: context,
    //     builder: (dialogContext) {
    //       return const ImageSelector();
    //     },
    //   );
    // }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            l10n.sidebarToolsTitle,
            style: const TextStyle(fontSize: 20),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 5,
            mainAxisSpacing: 5,
            crossAxisSpacing: 5,
            children: [
              SelectableIconButton(
                icon: const Icon(LucideIcons.pencil, size: 22),
                tooltip: l10n.sidebarDrawTooltip,
                shortcutLabel: shortcutLabel(IcarusShortcutAction.draw),
                onPressed: () {
                  switch (currentInteractionState) {
                    case InteractionState.drawing:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                    default:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.drawing);
                  }
                },
                isSelected: currentInteractionState == InteractionState.drawing,
              ),
              SelectableIconButton(
                tooltip: l10n.sidebarEraserTooltip,
                shortcutLabel: shortcutLabel(IcarusShortcutAction.erase),
                onPressed: () async {
                  await ref.read(penProvider.notifier).buildCursors();
                  switch (currentInteractionState) {
                    case InteractionState.erasing:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                    default:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.erasing);
                  }
                },
                icon: const Icon(
                  CustomIcons.eraser,
                  size: 22,
                ),
                isSelected: currentInteractionState == InteractionState.erasing,
              ),
              SelectableIconButton(
                tooltip: l10n.sidebarAddTextTooltip,
                shortcutLabel: shortcutLabel(IcarusShortcutAction.addText),
                onPressed: () {
                  switch (currentInteractionState) {
                    case InteractionState.textTools:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                    default:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.textTools);
                  }
                },
                icon: const Icon(LucideIcons.type, size: 22),
                isSelected:
                    currentInteractionState == InteractionState.textTools,
              ),
              ShadTooltip(
                builder: (context) => Text(l10n.sidebarAddImageTooltip),
                child: ShadIconButton.secondary(
                  onPressed: () async {
                    if (!ensureFeatureAvailable(
                      ref,
                      PlatformFeature.addImages,
                    )) {
                      return;
                    }
                    ref
                        .read(interactionStateProvider.notifier)
                        .update(InteractionState.navigation);
                    final UploadImageResult? imageResult =
                        await showShadDialog<UploadImageResult?>(
                      context: context,
                      builder: (context) => const UploadImageDialog(),
                    );
                    if (imageResult == null) return;
                    final added = await ref
                        .read(placedImageProvider.notifier)
                        .addImageOnScreen(
                          imageResult.bytes,
                          tagColorValue: imageResult.tagColorValue,
                        );
                    if (!added) {
                      Settings.showToast(
                        message: l10n.sidebarImageUploadFailed,
                        backgroundColor:
                            Settings.tacticalVioletTheme.destructive,
                      );
                    }
                  },
                  icon: const Icon(LucideIcons.image, size: 22),
                ),
              ),
              SelectableIconButton(
                tooltip: l10n.sidebarAddLineupTooltip,
                shortcutLabel: shortcutLabel(IcarusShortcutAction.addLineup),
                onPressed: () async {
                  if (!ensureFeatureAvailable(
                    ref,
                    PlatformFeature.addLineups,
                  )) {
                    return;
                  }

                  if (ref.watch(interactionStateProvider) ==
                      InteractionState.lineUpPlacing) {
                    ref
                        .read(interactionStateProvider.notifier)
                        .update(InteractionState.navigation);
                  } else {
                    ref
                        .read(interactionStateProvider.notifier)
                        .update(InteractionState.lineUpPlacing);
                  }
                },
                icon: const Icon(LucideIcons.bookOpen400, size: 22),
                isSelected: ref.watch(interactionStateProvider) ==
                    InteractionState.lineUpPlacing,
              ),
              SelectableIconButton(
                tooltip: l10n.sidebarVisionConeToolsTooltip,
                onPressed: () {
                  switch (currentInteractionState) {
                    case InteractionState.visionCone:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                    default:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.visionCone);
                  }
                },
                icon: const Icon(LucideIcons.eye, size: 22),
                isSelected:
                    currentInteractionState == InteractionState.visionCone,
              ),
              SelectableIconButton(
                tooltip: l10n.sidebarCustomShapesTooltip,
                onPressed: () {
                  switch (currentInteractionState) {
                    case InteractionState.customShapes:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                    default:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.customShapes);
                  }
                },
                icon: const Icon(LucideIcons.square, size: 22),
                isSelected:
                    currentInteractionState == InteractionState.customShapes,
              ),
              SelectableIconButton(
                tooltip: l10n.sidebarAgentRolesTooltip,
                onPressed: () {
                  switch (currentInteractionState) {
                    case InteractionState.roleIcons:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                    default:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.roleIcons);
                  }
                },
                icon: Image.asset("assets/agents/duelist.webp",
                    width: 20, height: 20),
                isSelected:
                    currentInteractionState == InteractionState.roleIcons,
              ),
              ShadTooltip(
                builder: (context) => Text(context.l10n.gameSpike),
                child: Draggable<SpikeToolData>(
                  data: SpikeToolData.fromUtility(
                    UtilityData.utilityWidgets[UtilityType.spike]!
                        as ImageUtility,
                  ),
                  dragAnchorStrategy: (draggable, context, position) {
                    final data = draggable.data as SpikeToolData;
                    return data.getScaledCenterPoint(
                      scaleFactor: CoordinateSystem.instance.scaleFactor,
                      screenZoom: ref.read(screenZoomProvider),
                    );
                  },
                  onDragStarted: () {
                    if (ref.read(interactionStateProvider) ==
                            InteractionState.drawing ||
                        ref.read(interactionStateProvider) ==
                            InteractionState.erasing) {
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                    }
                  },
                  feedback: Opacity(
                    opacity: Settings.feedbackOpacity,
                    child: ZoomTransform(
                      child: UtilityData.utilityWidgets[UtilityType.spike]!
                          .createWidget(id: null),
                    ),
                  ),
                  child: ShadIconButton.secondary(
                    onPressed: () {
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                      const uuid = Uuid();
                      final placementCenter = ref.read(placementCenterProvider);
                      final spikeData = SpikeToolData.fromUtility(
                        UtilityData.utilityWidgets[UtilityType.spike]!
                            as ImageUtility,
                      );
                      final centeredTopLeft =
                          DefaultPlacement.topLeftFromVirtualAnchor(
                        viewportCenter: placementCenter,
                        anchorVirtual: spikeData.centerPoint,
                      );

                      ref.read(utilityProvider.notifier).addUtility(
                            PlacedUtility(
                              position: centeredTopLeft,
                              id: uuid.v4(),
                              type: UtilityType.spike,
                            ),
                          );
                    },
                    icon: const AssetSvg(
                      "assets/spike.svg",
                      width: 20,
                      height: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const BottomContextBar(),
      ],
    );
  }
}
