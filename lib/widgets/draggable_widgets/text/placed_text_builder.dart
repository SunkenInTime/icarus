import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_scale_controller.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

class PlacedTextBuilder extends ConsumerStatefulWidget {
  const PlacedTextBuilder({
    super.key,
    required this.size,
    required this.placedText,
    required this.onDragEnd,
  });
  final double size;
  final PlacedText placedText;
  final Function(DraggableDetails details) onDragEnd;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _PlacedTextBuilderState();
}

class _PlacedTextBuilderState extends ConsumerState<PlacedTextBuilder> {
  static const double minSize = 100;
  double? localSize; // Make localScale nullable to check if it's initialized
  bool isPanning = false;
  bool isDragging = false;
  @override
  void initState() {
    localSize ??= widget.size;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final index = PlacedWidget.getIndexByID(
        widget.placedText.id, ref.watch(textProvider));
    if (localSize == null) {
      return const SizedBox.shrink();
    }

    if (ref.watch(textProvider)[index].size != localSize && !isPanning) {
      localSize = ref.read(textProvider)[index].size;
    }
    return TextScaleController(
      isDragging: isDragging,
      onPanUpdate: (details) {
        final renderBox = context.findRenderObject() as RenderBox?;
        if (renderBox == null) return;

        final leftEdgeGlobal = renderBox.localToGlobal(Offset.zero);
        final scale = ref.read(screenZoomProvider);
        final widthInScreenPixels =
            details.globalPosition.dx - leftEdgeGlobal.dx;
        final widthInContentSpace = widthInScreenPixels / scale;

        setState(() {
          isPanning = true;
          localSize = widthInContentSpace.clamp(minSize, double.infinity);
        });
      },
      onPanEnd: (details) {
        final index = PlacedWidget.getIndexByID(
            widget.placedText.id, ref.watch(textProvider));
        setState(() {
          isPanning = false;
          isDragging = false;
        });
        ref.read(textProvider.notifier).updateSize(index, localSize!);
      },
      child: Draggable<PlacedText>(
        data: widget.placedText,
        feedback: Opacity(
          opacity: 0.8,
          child: ZoomTransform(
            child: TextWidget(
              id: widget.placedText.id,
              text: widget.placedText.text,
              size: localSize!,
              isFeedback: true,
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
        child: TextWidget(
          id: widget.placedText.id,
          text: widget.placedText.text,
          size: localSize!,
          isFeedback: false,
        ),
      ),
    );
  }
}
