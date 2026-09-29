import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/color_library_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/image_provider.dart';

import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/draggable_widgets/adjacent_page_copy_menu.dart';
import 'package:icarus/widgets/draggable_widgets/canonical_positioned.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/image/scalable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class PlacedImageBuilder extends StatefulWidget {
  const PlacedImageBuilder({
    required this.placedImage,
    required this.isAttack,
    required this.onDragEnd,
    required this.scale,
    super.key,
  });

  final double scale;
  final PlacedImage placedImage;
  final bool isAttack;
  final Function(DraggableDetails details) onDragEnd;
  @override
  State<PlacedImageBuilder> createState() => _PlacedImageBuilderState();
}

class _PlacedImageBuilderState extends State<PlacedImageBuilder> {
  final _boxKey = GlobalKey();
  double? localScale; // Make localScale nullable to check if it's initialized
  bool isPanning = false;
  bool isDragging = false;
  Offset? pinnedScreenPosition;

  /// How far a mid-resize side switch moved the image away from the held
  /// pointer, so the width keeps following the pointer's movement.
  double pointerShift = 0;

  @override
  void initState() {
    super.initState();
    localScale ??= ImageScalePolicy.clamp(widget.scale);
  }

  /// A side switch mid-resize moves the pin to where the image now shows,
  /// so the position stored on release is read on the side it was pinned on.
  /// The image leaves the held pointer behind, so later drag updates measure
  /// from where the left edge was.
  @override
  void didUpdateWidget(covariant PlacedImageBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pinned = pinnedScreenPosition;
    final renderBox = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (pinned == null ||
        renderBox == null ||
        oldWidget.isAttack == widget.isAttack) {
      return;
    }
    final coordinateSystem = CoordinateSystem.instance;
    final boxSize = renderBox.size.bottomRight(Offset.zero);
    final nextPinned = coordinateSystem.screenPositionForSide(
      attackScreenPosition: coordinateSystem.screenPositionFromSide(
        sideScreenPosition: pinned,
        reflectionOffset: boxSize,
        isAttack: oldWidget.isAttack,
      ),
      reflectionOffset: boxSize,
      isAttack: widget.isAttack,
    );
    pointerShift += nextPinned.dx - pinned.dx;
    pinnedScreenPosition = nextPinned;
  }

  /// Stores the new scale, and the position that keeps the image's top-left
  /// where the resize pinned it. On defense the image hangs from its
  /// bottom-right corner, so that position moves with the size.
  ///
  /// Waits for the frame that lays out the last drag update, so the stored
  /// position matches the size the user let go at. Writes only if the image
  /// it resized is still loaded: a page switch in that frame loads the next
  /// page's copy, which keeps the same id.
  Future<void> _finishResize(WidgetRef ref) async {
    final resizedImage = widget.placedImage;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final pinned = pinnedScreenPosition;
    final renderBox = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    final stillLoaded = ref
        .read(placedImageProvider)
        .images
        .any((image) => identical(image, resizedImage));
    if (pinned != null && renderBox != null && stillLoaded) {
      final coordinateSystem = CoordinateSystem.instance;
      final position = coordinateSystem.screenToCoordinate(
        coordinateSystem.screenPositionFromSide(
          sideScreenPosition: pinned,
          reflectionOffset: renderBox.size.bottomRight(Offset.zero),
          isAttack: widget.isAttack,
        ),
      );
      ref
          .read(placedImageProvider.notifier)
          .resize(widget.placedImage.id, scale: localScale!, position: position);
      ref.read(strategyProvider.notifier).setUnsaved();
    }
    setState(() {
      isPanning = false;
      pinnedScreenPosition = null;
      pointerShift = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (localScale == null) {
      return const SizedBox.shrink();
    }

    return Consumer(builder: (context, ref, child) {
      final index = PlacedWidget.getIndexByID(
          widget.placedImage.id, ref.watch(placedImageProvider).images);

      if (ref.watch(placedImageProvider).images[index].scale != localScale &&
          !isPanning) {
        localScale = ImageScalePolicy.clamp(
            ref.read(placedImageProvider).images[index].scale);
      }

      final coordinateSystem = CoordinateSystem.instance;
      final attackScreenPosition =
          coordinateSystem.coordinateToScreen(widget.placedImage.position);
      return CanonicalPositionedBox(
        attackScreenPosition: attackScreenPosition,
        isAttack: widget.isAttack,
        pinnedScreenPosition: pinnedScreenPosition,
        child: ImageScaleController(
          key: _boxKey,
          isDragging: isDragging,
          onPanUpdate: (details) {
            final renderBox =
                _boxKey.currentContext?.findRenderObject() as RenderBox?;
            if (renderBox == null) return;

            final topLeftGlobal = renderBox.localToGlobal(Offset.zero);
            final screenZoom = ref.read(screenZoomProvider);
            final widthInScreenPixels =
                details.globalPosition.dx - topLeftGlobal.dx;
            final widthInContentSpace =
                widthInScreenPixels / screenZoom + pointerShift;
            final widthInWorldSpace =
                coordinateSystem.screenWidthToWorld(widthInContentSpace);

            setState(() {
              isPanning = true;
              pinnedScreenPosition ??= coordinateSystem.screenPositionForSide(
                attackScreenPosition: attackScreenPosition,
                reflectionOffset: renderBox.size.bottomRight(Offset.zero),
                isAttack: widget.isAttack,
              );
              localScale = ImageScalePolicy.clamp(widthInWorldSpace);
            });
          },
          onPanEnd: (_) => _finishResize(ref),
          child: Draggable<PlacedWidget>(
            data: widget.placedImage,
            feedback: ZoomTransform(
              child: IgnorePointer(
                child: ImageWidget(
                  isFeedback: true,
                  link: widget.placedImage.link,
                  aspectRatio: widget.placedImage.aspectRatio,
                  scale: localScale!,
                  fileExtension: widget.placedImage.fileExtension,
                  id: widget.placedImage.id,
                  tagColorValue: widget.placedImage.tagColorValue,
                ),
              ),
            ),
            childWhenDragging: const SizedBox.shrink(),
            dragAnchorStrategy:
                ref.read(screenZoomProvider.notifier).zoomDragAnchorStrategy,
            onDragStarted: () {
              setState(() {
                isDragging = true;
              });
            },
            onDragEnd: (details) {
              widget.onDragEnd(details);
              setState(() {
                isDragging = false;
              });
            },
            child: ShadContextMenuRegion(
              items: _buildTagColorItems(ref),
              child: MouseWatch(
                cursor: SystemMouseCursors.click,
                deleteTarget: HoveredDeleteTarget.image(
                  id: widget.placedImage.id,
                  ownerToken: Object(),
                ),
                child: ImageWidget(
                  fileExtension: widget.placedImage.fileExtension,
                  aspectRatio: widget.placedImage.aspectRatio,
                  link: widget.placedImage.link,
                  scale: localScale!,
                  id: widget.placedImage.id,
                  tagColorValue: widget.placedImage.tagColorValue,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  List<ShadContextMenuItem> _buildTagColorItems(WidgetRef ref) {
    return [
      ShadContextMenuItem(
        child: const Text('Reset tag to gray'),
        onPressed: () {
          ref
              .read(placedImageProvider.notifier)
              .updateTagColor(widget.placedImage.id, null);
          ref.read(strategyProvider.notifier).setUnsaved();
        },
      ),
      ...ref.watch(colorLibraryProvider).map(
            (entry) => ShadContextMenuItem(
              leading: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: entry.color,
                  shape: BoxShape.circle,
                ),
              ),
              child: Text(_labelForColor(entry)),
              onPressed: () {
                ref.read(placedImageProvider.notifier).updateTagColor(
                    widget.placedImage.id, entry.color.toARGB32());
                ref.read(strategyProvider.notifier).setUnsaved();
              },
            ),
          ),
      ...buildAdjacentPageCopyMenuItems(ref, widget.placedImage.id),
    ];
  }

  String _labelForColor(ColorLibraryEntry entry) {
    final kind = entry.isCustom ? 'custom' : 'default';
    final hex = (entry.color.toARGB32() & 0x00FFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase();
    return '#$hex $kind tag';
  }
}
