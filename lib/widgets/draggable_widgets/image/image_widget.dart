import 'dart:developer';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/image_widget_size_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
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

                log("Max width $width");

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
    required this.link,
    required this.aspectRatio,
    required this.scale,
    required this.fileExtension,
    required this.id,
    this.isFeedback = false,
  });
  final double aspectRatio;
  final String? link;
  final double scale;
  final String? fileExtension;
  final String id;
  final bool isFeedback;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ImageWidgetState();
}

class _ImageWidgetState extends ConsumerState<ImageWidget> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      RenderObject? renderObject = context.findRenderObject();
      RenderBox? renderBox = renderObject as RenderBox;
      // if (renderBox == null) return;
      double height = renderBox.size.height;
      double width = renderBox.size.width;

      Offset offset = Offset(width, height);

      ref.read(imageWidgetSizeProvider.notifier).updateSize(widget.id, offset);
    });
  }

  @override
  Widget build(BuildContext context) {
    log(widget.scale.toString());
    final file = File(path.join(
      ref.watch(strategyProvider).storageDirectory!,
      'images',
      '${widget.id}${widget.fileExtension}',
    ));

    // Build the small image widget used both here and in the hero
    Widget buildThumb() {
      if (file.existsSync() && widget.fileExtension != null) {
        return Image.file(file, fit: BoxFit.cover);
      }
      if (widget.link != null && widget.link!.isNotEmpty) {
        return Image.network(widget.link!, fit: BoxFit.cover);
      }
      return const Placeholder();
    }

    return GestureDetector(
      onTap: () {
        _showImageFullScreenOverlay(
          context: context,
          heroTag: 'image_${widget.id}',
          file:
              (file.existsSync() && widget.fileExtension != null) ? file : null,
          networkLink: (file.existsSync() && widget.fileExtension != null)
              ? null
              : widget.link,
          aspectRatio: widget.aspectRatio,
        );
      },
      child: NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (notification) {
          RenderObject? renderObject = context.findRenderObject();
          RenderBox? renderBox = renderObject as RenderBox;
          double height = renderBox.size.height;
          double width = renderBox.size.width;

          Offset offset = Offset(width, height);
          WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
            ref
                .read(imageWidgetSizeProvider.notifier)
                .updateSize(widget.id, offset);
          });
          return true;
        },
        child: SizeChangedLayoutNotifier(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.scale),
            child: AspectRatio(
              aspectRatio: widget.aspectRatio,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The grey container on left
                  Container(
                    width: 10,
                    decoration: BoxDecoration(
                      color: const Color(0xFFC5C5C5),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(3),
                      ),
                      margin: EdgeInsets.zero,
                      color: Colors.black,
                      child: Padding(
                        padding: const EdgeInsets.all(5),
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
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
