import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/image_provider.dart';

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
        if (kIsWeb) {
          Settings.showToast(
            message: 'This feature is only supported in the Windows version.',
            backgroundColor: Settings.tacticalVioletTheme.destructive,
          );
          return;
        }
        isDragging = false;
        final files = details.files;

        for (final file in files) {
          final String fileExtension = file.name.split('.').last.toLowerCase();
          if (['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(fileExtension)) {
            await ref.read(placedImageProvider.notifier).addImage(
                imageBytes: await file.readAsBytes(),
                fileExtension: fileExtension);
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
