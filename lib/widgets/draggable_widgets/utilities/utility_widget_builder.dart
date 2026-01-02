import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

class UtilityWidgetBuilder extends ConsumerStatefulWidget {
  final PlacedUtility utility;
  final Function(DraggableDetails details) onDragEnd;
  final String id;
  final double rotation;
  final double length;
  const UtilityWidgetBuilder({
    required this.utility,
    required this.onDragEnd,
    required this.id,
    required this.rotation,
    required this.length,
    super.key,
  });
  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _UtilityWidgetBuilderState();
}

class _UtilityWidgetBuilderState extends ConsumerState<UtilityWidgetBuilder> {
  @override
  Widget build(BuildContext context) {
    return Draggable<PlacedUtility>(
      data: widget.utility,
      // feedback:widget.data
      childWhenDragging: const SizedBox.shrink(),

      feedback: Opacity(
        opacity: Settings.feedbackOpacity,
        child: ZoomTransform(
          child:
              UtilityData.utilityWidgets[widget.utility.type]!.createWidget(),
        ),
      ),
      onDragEnd: (details) {
        widget.onDragEnd(details);
      },
      child: ZoomTransform(
        child: UtilityData.utilityWidgets[widget.utility.type]!
            .createWidget(id: widget.id),
      ),
    );
  }
}
