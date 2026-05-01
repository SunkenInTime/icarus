import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/color_library_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/image_provider.dart';

import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/image/scalable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class PlacedImageBuilder extends StatefulWidget {
  const PlacedImageBuilder({
    required this.placedImage,
    required this.onDragEnd,
    required this.scale,
    super.key,
  });

  final double scale;
  final PlacedImage placedImage;
  final Function(DraggableDetails details) onDragEnd;
  @override
  State<PlacedImageBuilder> createState() => _PlacedImageBuilderState();
}

class _PlacedImageBuilderState extends State<PlacedImageBuilder> {
  double? localScale; // Make localScale nullable to check if it's initialized
  bool isPanning = false;
  bool isDragging = false;

  @override
  void initState() {
    super.initState();
    localScale ??= ImageScalePolicy.clamp(widget.scale);
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

      return ImageScaleController(
        isDragging: isDragging,
        onPanUpdate: (details) {
          final renderBox = context.findRenderObject() as RenderBox?;
          if (renderBox == null) return;

          final topLeftGlobal = renderBox.localToGlobal(Offset.zero);
          final screenZoom = ref.read(screenZoomProvider);
          final widthInScreenPixels =
              details.globalPosition.dx - topLeftGlobal.dx;
          final widthInContentSpace = widthInScreenPixels / screenZoom;
          final widthInWorldSpace =
              CoordinateSystem.instance.screenWidthToWorld(widthInContentSpace);

          setState(() {
            isPanning = true;
            localScale = ImageScalePolicy.clamp(widthInWorldSpace);
          });
        },
        onPanEnd: (details) {
          final index = PlacedWidget.getIndexByID(
            widget.placedImage.id,
            ref.read(placedImageProvider).images,
          );
          ref
              .read(placedImageProvider.notifier)
              .updateScale(index, localScale!);

          setState(() {
            isPanning = false;
          });
        },
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
              },
            ),
          ),
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
