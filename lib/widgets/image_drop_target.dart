import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/dot_painter.dart';

class ImageDropTarget extends ConsumerStatefulWidget {
  const ImageDropTarget({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _ImageDropTargetState();
}

class _ImageDropTargetState extends ConsumerState<ImageDropTarget> {
  bool isDragging = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (details) {
        setState(() {
          isDragging = true;
        });
      },
      onDragExited: (details) {
        setState(() {
          isDragging = false;
        });
      },
      onDragDone: (details) async {
        isDragging = false;
        final files = details.files;

        for (final file in files) {
          final String extension = file.name.split('.').last.toLowerCase();
          if (['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(extension)) {
            await ref.read(placedImageProvider.notifier).addImage(file);
          }
        }
      },
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          if (isDragging)
            const Positioned.fill(
              child: ColoredBox(
                color: Color.fromARGB(118, 2, 2, 2),
              ),
            ),
          if (isDragging)
            const Positioned.fill(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.download, size: 60),
                    SizedBox(
                      height: 10,
                    ),
                    Text(
                      "Import image file (.png, .jpg, .webp, .gif)",
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    )
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
