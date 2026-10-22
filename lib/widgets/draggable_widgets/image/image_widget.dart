import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_media_dimensions.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// How tall, in physical pixels, a canvas [canvasHeight] logical pixels
/// tall gets with the window as tall as its display. The window around the
/// canvas keeps its size as the window is resized, so this stays put while
/// the edge is dragged; following the canvas itself would decode every
/// picture again on each frame of the drag.
double _tallestCanvasHeight(BuildContext context, double canvasHeight) {
  final pixelRatio = MediaQuery.devicePixelRatioOf(context);
  final aroundCanvas = MediaQuery.sizeOf(context).height - canvasHeight;
  final display = View.of(context).display;
  // In logical pixels. A browser reports its screen in them already; a
  // desktop reports its display in physical pixels.
  final displayHeight = kIsWeb
      ? display.size.height
      : display.size.height / display.devicePixelRatio;
  final tallest = math.max(
    (displayHeight - aroundCanvas) * pixelRatio,
    canvasHeight * pixelRatio,
  );
  // Whole pixels, so float noise between frames never makes a new box.
  return tallest.roundToDouble();
}

// Full-screen overlay launcher
void _showImageFullScreenOverlay({
  required BuildContext context,
  required String heroTag,
  required double aspectRatio,
  required ImageProvider image,
  required ImageProvider fullImage,
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
          image: image,
          fullImage: fullImage,
        ),
      ),
    ),
  );
}

class _ImageFullScreenOverlay extends StatelessWidget {
  const _ImageFullScreenOverlay({
    required this.heroTag,
    required this.aspectRatio,
    required this.image,
    required this.fullImage,
  });

  final String heroTag;
  final double aspectRatio;

  /// The picture as the canvas decoded it, shown until [fullImage] is
  /// ready. It already fills the overlay before any zoom.
  final ImageProvider image;

  /// Every pixel of the picture: zoomed in, the overlay draws it larger than
  /// the canvas ever does.
  final ImageProvider fullImage;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Navigator.of(context).maybePop();
        },
      },
      child: Focus(
        autofocus: true,
        child: Material(
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
                    final width = constraints.maxWidth -
                        100; // typically the screen width
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
                                child: Image(
                                  image: fullImage,
                                  fit: BoxFit.contain,
                                  frameBuilder: (context, child, frame, _) =>
                                      frame == null
                                          ? Image(
                                              image: image,
                                              fit: BoxFit.contain,
                                            )
                                          : child,
                                ),
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
        ),
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
    required this.pictureId,
    this.tagColorValue,
    this.isFeedback = false,
  });
  final double aspectRatio;
  final double scale;
  final String? fileExtension;

  /// The placed image's id, which its hero tag carries: unique on a page.
  final String id;

  /// The id of the picture it shows (PlacedImage.pictureId), which images
  /// on several pages, or a copy and its original, can share.
  final String pictureId;
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
    final source = watchStrategyImageSource(
      ref,
      (id: widget.pictureId, fileExtension: widget.fileExtension),
    );
    // A capture draws the picture once, unzoomed, as the capture decoded
    // it; the editor's canvas zooms in.
    final capturePixelRatio = ref.watch(capturePixelRatioProvider);
    final image = source.imageProvider(
      drawnAtMost: capturePixelRatio != null
          ? PlacedImageDimensions.capturedPictureBox(
              pixelRatio: capturePixelRatio,
              aspectRatio: widget.aspectRatio,
            )
          : PlacedImageDimensions.largestPictureBox(
              canvasHeight: _tallestCanvasHeight(
                context,
                coordinateSystem.playAreaSize.height,
              ),
              zoom: Settings.canvasMaxZoom,
              aspectRatio: widget.aspectRatio,
            ),
    );

    Widget buildThumb() => switch (source) {
          // Gapless, keyed by asset: this image's pending bytes keep painting
          // while its cloud URL loads, and no other image's frame carries
          // over.
          LocalImageFile() || RemoteImageUrl() || ImageBytes() => Image(
              key: ValueKey(widget.pictureId),
              image: image!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ImageLoading() => const _ImageStatePlaceholder(
              icon: LucideIcons.loaderCircle,
              label: 'Syncing image',
              showSpinner: true,
            ),
          ImageFailed() => const _ImageStatePlaceholder(
              icon: LucideIcons.imageOff,
              label: 'Image unavailable',
            ),
        };

    return GestureDetector(
      onTap: image == null
          ? null
          : () => _showImageFullScreenOverlay(
                context: context,
                heroTag: 'image_${widget.id}',
                image: image,
                fullImage: source.imageProvider(drawnAtMost: null)!,
                aspectRatio: widget.aspectRatio,
              ),
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
