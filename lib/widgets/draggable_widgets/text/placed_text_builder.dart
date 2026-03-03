import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_scale_controller.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
  static const List<Color> _tagPalette = [
    Color(0xFF22C55E),
    Color(0xFF3B82F6),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFFA855F7),
  ];
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
              tagColorValue: widget.placedText.tagColorValue,
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
        child: ShadContextMenuRegion(
          items: _buildTagColorItems(),
          child: TextWidget(
            id: widget.placedText.id,
            text: widget.placedText.text,
            size: localSize!,
            tagColorValue: widget.placedText.tagColorValue,
            isFeedback: false,
          ),
        ),
      ),
    );
  }

  List<ShadContextMenuItem> _buildTagColorItems() {
    return [
      ShadContextMenuItem(
        child: const Text('Reset tag to gray'),
        onPressed: () {
          ref.read(textProvider.notifier).updateTagColor(widget.placedText.id, null);
        },
      ),
      ..._tagPalette.map(
        (color) => ShadContextMenuItem(
          leading: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          child: Text(_labelForColor(color)),
          onPressed: () {
            ref
                .read(textProvider.notifier)
                .updateTagColor(widget.placedText.id, color.toARGB32());
          },
        ),
      ),
    ];
  }

  String _labelForColor(Color color) {
    if (color.toARGB32() == const Color(0xFF22C55E).toARGB32()) {
      return 'Green tag';
    }
    if (color.toARGB32() == const Color(0xFF3B82F6).toARGB32()) {
      return 'Blue tag';
    }
    if (color.toARGB32() == const Color(0xFFF59E0B).toARGB32()) {
      return 'Amber tag';
    }
    if (color.toARGB32() == const Color(0xFFEF4444).toARGB32()) {
      return 'Red tag';
    }
    return 'Purple tag';
  }
}
