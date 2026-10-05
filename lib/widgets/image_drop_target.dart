import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/widgets/platform_feature_toast.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
    final canEditPages = ref.watch(
      currentStrategyCapabilitiesProvider.select(
        (capabilities) => capabilities.canEditPages,
      ),
    );
    // Only invite a drop that can land.
    final canDrop = canEditPages &&
        ref.watch(platformPolicyProvider).supports(PlatformFeature.fileDrop);

    return DropTarget(
      onDragEntered: (details) {
        if (!canDrop) return;
        setState(() {
          isDragging = true;
        });
      },
      onDragExited: (details) {
        if (!canDrop) return;
        setState(() {
          isDragging = false;
        });
      },
      onDragDone: (details) async {
        if (!ref.read(currentStrategyCapabilitiesProvider).canEditPages) {
          return;
        }
        if (!ensureFeatureAvailable(ref, PlatformFeature.fileDrop)) return;
        if (!ensureFeatureAvailable(ref, PlatformFeature.addImages)) return;
        isDragging = false;
        final files = details.files;

        for (final file in files) {
          final parts = file.name.split('.');
          if (parts.length < 2) continue;
          final rawExtension = parts.last.toLowerCase();
          if (['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp']
              .contains(rawExtension)) {
            final fileExtension = '.$rawExtension';
            final strategyState = ref.read(strategyProvider);
            await ref.read(placedImageProvider.notifier).addImage(
                  imageBytes: await file.readAsBytes(),
                  strategyId: strategyState.strategyId,
                  strategySource: strategyState.source,
                  fileExtension: fileExtension,
                );
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
                    Icon(LucideIcons.download, size: 60),
                    SizedBox(
                      height: 10,
                    ),
                    Text(
                      "Import image file (.png, .jpg, .webp, .gif, .bmp)",
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
