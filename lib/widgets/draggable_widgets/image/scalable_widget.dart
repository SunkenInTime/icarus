import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';

class ImageScaleController extends ConsumerWidget {
  const ImageScaleController({
    super.key,
    required this.child,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.isDragging,
  });

  final Function(DragUpdateDetails details) onPanUpdate;
  final GestureDragEndCallback onPanEnd;

  final Widget child;
  final bool isDragging;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        child,
        !isDragging
            ? Positioned.fill(
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: GestureDetector(
                        onTap: () {
                          log("Hi");
                        },
                        onPanUpdate: onPanUpdate,
                        // Update the scale based on horizontal drag changes.
                        // onPanUpdate: (details) {
                        onPanEnd: onPanEnd,
                        // },
                        child: const Icon(
                          CustomIcons.resizeCorner,
                          size: 12,
                        )),
                  ),
                ),
              )
            : const SizedBox.shrink()
      ],
    );
  }
}

