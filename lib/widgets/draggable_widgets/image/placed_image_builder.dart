import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/image_provider.dart';

import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/image/scalable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/mouse_watch.dart';

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
  // Optionally define min and max scale values
  static const double minScale = 100;
  static const double maxScale = 800;

  @override
  void initState() {
    super.initState();
    localScale ??= widget.scale;
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
        localScale = ref.read(placedImageProvider).images[index].scale;
      }

      return ImageScaleController(
        isDragging: isDragging,
        onPanUpdate: (details) {
          log("I'm being panned");
          setState(() {
            isPanning = true;
            localScale = details.delta.dx + localScale!;
            if (localScale! < minScale) localScale = minScale;
            if (localScale! > maxScale) localScale = maxScale;
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
                link: widget.placedImage.link,
                aspectRatio: widget.placedImage.aspectRatio,
                scale: localScale!,
                fileExtension: widget.placedImage.fileExtension,
                id: widget.placedImage.id,
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
          child: MouseWatch(
            cursor: SystemMouseCursors.click,
            onDeleteKeyPressed: () {
              final id = widget.placedImage.id;
              final action = UserAction(
                  type: ActionType.deletion, id: id, group: ActionGroup.image);

              ref.read(actionProvider.notifier).addAction(action);
              ref.read(placedImageProvider.notifier).removeImage(id);
            },
            child: ImageWidget(
              fileExtension: widget.placedImage.fileExtension,
              aspectRatio: widget.placedImage.aspectRatio,
              link: widget.placedImage.link,
              scale: localScale!,
              id: widget.placedImage.id,
            ),
          ),
        ),
      );
    });
  }
}
