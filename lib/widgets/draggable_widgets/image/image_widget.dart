import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_media_dimensions.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';

// Full-screen overlay launcher
void _showImageFullScreenOverlay({
  required BuildContext context,
  required String heroTag,
  required double aspectRatio,
  File? file,
  String? networkLink,
}) {
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, anim, __) => FadeTransition(
        opacity: anim,
        child: _ImageFullScreenOverlay(
          heroTag: heroTag,
          aspectRatio: aspectRatio,
          file: file,
          networkLink: networkLink,
        ),
      ),
    ),
  );
}

class _ImageFullScreenOverlay extends StatelessWidget {
  const _ImageFullScreenOverlay({
    required this.heroTag,
    required this.aspectRatio,
    this.file,
    this.networkLink,
  });

  final String heroTag;
  final double aspectRatio;
  final File? file;
  final String? networkLink;

  @override
  Widget build(BuildContext context) {
    final image = file != null
        ? Image.file(
            file!,
            fit: BoxFit.contain,
          )
        : (networkLink != null && networkLink!.isNotEmpty
            ? Image.network(networkLink!, fit: BoxFit.contain)
            : const Placeholder());

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
              child: Container(color: Colors.black54),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: LayoutBuilder(builder: (context, constraints) {
                final width =
                    constraints.maxWidth - 100; // typically the screen width
                final height = width / aspectRatio;

                return Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    Align(
                      alignment: Alignment.center,
                      child: InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 8,
                        child: SizedBox(
                          width: width,
                          height: height,
                          child: Hero(
                            tag: heroTag,
                            child: image,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
          Positioned(
            top: 24,
            right: 24,
            child: SafeArea(
              child: ShadIconButton.secondary(
                icon: const Icon(LucideIcons.x, color: Colors.white),
                decoration: ShadDecoration(
                  border: ShadBorder.all(
                    color: Settings.tacticalVioletTheme.border,
                  ),
                ),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ImageWidget extends ConsumerStatefulWidget {
  const ImageWidget({
    super.key,
    required this.aspectRatio,
    required this.scale,
    required this.fileExtension,
    required this.id,
    this.tagColorValue,
    this.isFeedback = false,
  });
  final double aspectRatio;
  final double scale;
  final String? fileExtension;
  final String id;
  final int? tagColorValue;
  final bool isFeedback;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ImageWidgetState();
}

class _ImageWidgetState extends ConsumerState<ImageWidget> {
  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final metrics = PlacedImageDimensions.screenSize(
      coordinateSystem: coordinateSystem,
      scale: widget.scale,
      aspectRatio: widget.aspectRatio,
    );
    final safeAspectRatio = widget.aspectRatio <= 0 ? 1.0 : widget.aspectRatio;
    final cardWidth = (metrics.width -
            PlacedImageDimensions.tagWidth -
            PlacedImageDimensions.tagGap)
        .clamp(1.0, double.infinity);
    final contentWidth = (cardWidth - (PlacedImageDimensions.imagePadding * 2))
        .clamp(1.0, double.infinity);
    final file = File(path.join(
      ref.watch(strategyProvider).storageDirectory!,
      'images',
      '${widget.id}${widget.fileExtension}',
    ));
    final strategyState = ref.watch(strategyProvider);
    final remoteAsset = ref
        .watch(remoteStrategySnapshotProvider)
        .valueOrNull
        ?.assetsById[widget.id];
    final remoteUrl = remoteAsset?.url;
    final hasLocalFile = file.existsSync() && widget.fileExtension != null;
    final isCloudStrategy = strategyState.source == StrategySource.cloud;
    final remoteUploadStatus = remoteAsset?.uploadStatus;
    final showFailedPlaceholder =
        isCloudStrategy && remoteUploadStatus == 'failed' && !hasLocalFile;
    final showLoadingPlaceholder = isCloudStrategy &&
        !showFailedPlaceholder &&
        !hasLocalFile &&
        (remoteUrl == null || remoteUrl.isEmpty);

    // Build the small image widget used both here and in the hero
    Widget buildThumb() {
      if (hasLocalFile) {
        return Image.file(file, fit: BoxFit.contain);
      }
      if (remoteUrl != null && remoteUrl.isNotEmpty) {
        return Image.network(remoteUrl, fit: BoxFit.contain);
      }
      if (showFailedPlaceholder) {
        return const _ImageStatePlaceholder(
          icon: LucideIcons.imageOff,
          label: 'Image unavailable',
        );
      }
      if (showLoadingPlaceholder) {
        return const _ImageStatePlaceholder(
          icon: LucideIcons.loaderCircle,
          label: 'Syncing image',
          showSpinner: true,
        );
      }
      return const Placeholder();
    }

    return GestureDetector(
      onTap: () {
        _showImageFullScreenOverlay(
          context: context,
          heroTag: 'image_${widget.id}',
          file: hasLocalFile ? file : null,
          networkLink: hasLocalFile ? null : remoteUrl,
          aspectRatio: widget.aspectRatio,
        );
      },
      child: SizedBox(
        width: metrics.width,
        height: metrics.height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              //Tag container
              width: PlacedImageDimensions.tagWidth,
              decoration: BoxDecoration(
                color: Color(widget.tagColorValue ?? 0xFFC5C5C5),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: PlacedImageDimensions.tagGap),
            Expanded(
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(3),
                ),
                margin: EdgeInsets.zero,
                color: Colors.black,
                child: Padding(
                  padding: const EdgeInsets.all(
                    PlacedImageDimensions.imagePadding,
                  ),
                  child: SizedBox(
                    width: contentWidth,
                    height: contentWidth / safeAspectRatio,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color.fromARGB(255, 20, 20, 20),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Hero(
                          tag: 'image_${widget.id}',
                          child: buildThumb(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageStatePlaceholder extends StatelessWidget {
  const _ImageStatePlaceholder({
    required this.icon,
    required this.label,
    this.showSpinner = false,
  });

  final IconData icon;
  final String label;
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color.fromARGB(255, 20, 20, 20),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showSpinner)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(icon, color: Colors.white70, size: 22),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
