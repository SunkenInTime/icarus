import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/default_placement.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/placement_center_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/dialogs/upload_image_dialog.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/selectable_icon_button.dart';
import 'package:icarus/widgets/sidebar_widgets/custom_shape_tools.dart';
import 'package:icarus/widgets/sidebar_widgets/delete_options.dart';
import 'package:icarus/widgets/sidebar_widgets/drawing_tools.dart';
import 'package:icarus/widgets/sidebar_widgets/vision_cone_tools.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

enum _ContextBarMode { drawing, deleting, visionCone, customShapes, none }

class BottomContextBar extends ConsumerWidget {
  const BottomContextBar({super.key});

  static const Duration _animationDuration = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interactionState = ref.watch(interactionStateProvider);

    final mode = switch (interactionState) {
      InteractionState.drawing => _ContextBarMode.drawing,
      InteractionState.deleting => _ContextBarMode.deleting,
      InteractionState.visionCone => _ContextBarMode.visionCone,
      InteractionState.customShapes => _ContextBarMode.customShapes,
      _ => _ContextBarMode.none,
    };

    return ClipRect(
      child: AnimatedSize(
        duration: _animationDuration,
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: _animationDuration,
          switchInCurve: Curves.easeIn,
          switchOutCurve: Curves.easeOut,
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
      _ContextBarMode.deleting =>
        const DeleteOptions(key: ValueKey('deleting')),
      _ContextBarMode.none => const SizedBox.shrink(key: ValueKey('none')),
    };
  }
}

class ToolGrid extends ConsumerWidget {
  const ToolGrid({super.key});
  static const double _defaultTextSpawnWidth = 200;
  static const double _defaultTextSpawnHeight = 40;
  static const double _defaultImageSpawnWidth = 200;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentInteractionState = ref.watch(interactionStateProvider);

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
        const Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            "Tools",
            style: TextStyle(fontSize: 20),
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
                icon: const Icon(Icons.draw),
                tooltip: "Draw Q",
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
                tooltip: "Eraser W",
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
                  size: 20,
                ),
                isSelected: currentInteractionState == InteractionState.erasing,
              ),
              SelectableIconButton(
                tooltip: "Delete E",
                onPressed: () {
                  switch (currentInteractionState) {
                    case InteractionState.deleting:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                    default:
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.deleting);
                  }
                },
                isSelected:
                    currentInteractionState == InteractionState.deleting,
                icon: const Icon(
                  Icons.delete,
                ),
              ),
              ShadTooltip(
                builder: (context) => const Text("Add Text T"),
                child: ShadIconButton.secondary(
                  onPressed: () {
                    ref
                        .read(interactionStateProvider.notifier)
                        .update(InteractionState.navigation);
                    const uuid = Uuid();
                    final placementCenter = ref.read(placementCenterProvider);
                    final centeredTopLeft =
                        DefaultPlacement.topLeftFromVirtualAnchor(
                      viewportCenter: placementCenter,
                      anchorVirtual: const Offset(
                        _defaultTextSpawnWidth / 2,
                        _defaultTextSpawnHeight / 2,
                      ),
                    );
                    ref.read(textProvider.notifier).addText(
                          PlacedText(position: centeredTopLeft, id: uuid.v4()),
                        );
                  },
                  icon: const Icon(Icons.text_fields),
                ),
              ),
              ShadTooltip(
                builder: (context) => const Text("Add Image"),
                child: ShadIconButton.secondary(
                  onPressed: () async {
                    ref
                        .read(interactionStateProvider.notifier)
                        .update(InteractionState.navigation);
                    final Uint8List? imageBytes =
                        await showShadDialog<Uint8List?>(
                      context: context,
                      builder: (context) => const UploadImageDialog(),
                    );
                    if (imageBytes == null) return;

                    final String? fileExtension =
                        PlacedImageSerializer.detectImageFormat(imageBytes);
                    if (fileExtension == null) {
                      Settings.showToast(
                        message: 'Upload failed',
                        backgroundColor:
                            Settings.tacticalVioletTheme.destructive,
                      );
                      return;
                    }

                    if (kIsWeb) {
                      Settings.showToast(
                        message:
                            'This feature is only supported in the Windows version.',
                        backgroundColor:
                            Settings.tacticalVioletTheme.destructive,
                      );
                      return;
                    }

                    final aspectRatio = await ref
                        .read(placedImageProvider.notifier)
                        .getImageAspectRatio(imageBytes);
                    final placementCenter = ref.read(placementCenterProvider);
                    final imageHeight = _defaultImageSpawnWidth / aspectRatio;
                    final centeredTopLeft =
                        DefaultPlacement.topLeftFromVirtualAnchor(
                      viewportCenter: placementCenter,
                      anchorVirtual:
                          Offset(_defaultImageSpawnWidth / 2, imageHeight / 2),
                    );

                    ref.read(placedImageProvider.notifier).addImage(
                          imageBytes: imageBytes,
                          fileExtension: fileExtension,
                          aspectRatio: aspectRatio,
                          position: centeredTopLeft,
                        );
                  },
                  icon: const Icon(Icons.image_outlined),
                ),
              ),
              SelectableIconButton(
                tooltip: "Add Lineup",
                onPressed: () async {
                  if (kIsWeb) {
                    Settings.showToast(
                      message:
                          'This feature is only supported in the Windows version.',
                      backgroundColor: Settings.tacticalVioletTheme.destructive,
                    );
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
                icon: const Icon(LucideIcons.bookOpen400),
                isSelected: ref.watch(interactionStateProvider) ==
                    InteractionState.lineUpPlacing,
              ),
              ShadTooltip(
                builder: (context) => const Text("Vision Cone Tools"),
                child: SelectableIconButton(
                  tooltip: "Vision Cone",
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
                  icon: const Icon(LucideIcons.eye, size: 20),
                  isSelected:
                      currentInteractionState == InteractionState.visionCone,
                ),
              ),
              ShadTooltip(
                builder: (context) => const Text("Custom Shapes"),
                child: SelectableIconButton(
                  tooltip: "Custom Shapes",
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
                  icon: const Icon(Icons.crop_square, size: 20),
                  isSelected:
                      currentInteractionState == InteractionState.customShapes,
                ),
              ),
              ShadTooltip(
                builder: (context) => const Text("Spike"),
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
                    icon: SvgPicture.asset(
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
