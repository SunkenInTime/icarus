import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';

class TextScaleController extends ConsumerWidget {
  const TextScaleController({
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.child,
    required this.isDragging,
    super.key,
  });

  final Function(DragUpdateDetails details) onPanUpdate;
  final GestureDragEndCallback onPanEnd;

  final double minScale = 100;
  final Widget child;
  final bool isDragging;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        child,
        if (!isDragging)
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onPanUpdate: onPanUpdate,
                onPanEnd: onPanEnd,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color.fromARGB(68, 255, 255, 255),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: Settings.textHandleShadows,
                      ),
                      width: 5,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

