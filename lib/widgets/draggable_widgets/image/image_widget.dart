import 'dart:developer';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:path/path.dart' as path;

class ImageWidget extends ConsumerWidget {
  const ImageWidget({
    super.key,
    required this.link,
    required this.aspectRatio,
    required this.scale,
    required this.fileExtension,
    required this.id,
  });
  final double aspectRatio;
  final String? link;
  final double scale;
  final String? fileExtension;
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    log(scale.toString());
    final file = File(path.join(
      ref.watch(strategyProvider).storageDirectory!,
      'images',
      '$id$fileExtension',
    ));
    // Build the small image widget used both here and in the hero
    Widget buildThumb() {
      if (file.existsSync() && fileExtension != null) {
        return Image.file(file, fit: BoxFit.cover);
      }
      if (link != null && link!.isNotEmpty) {
        return Image.network(link!, fit: BoxFit.cover);
      }
      return const Placeholder();
    }

    return GestureDetector(
      onTap: () {
        _showImageFullScreenOverlay(
          context: context,
          heroTag: 'image_$id',
          file: (file.existsSync() && fileExtension != null) ? file : null,
          networkLink:
              (file.existsSync() && fileExtension != null) ? null : link,
          aspectRatio: aspectRatio,
        );
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: scale),
        child: AspectRatio(
          aspectRatio: aspectRatio,
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
                          tag: 'image_$id',
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
    );
  }
}

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
        ? Image.file(file!, fit: BoxFit.contain)
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
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 8,
                        child: AspectRatio(
                          aspectRatio: aspectRatio,
                          child: Hero(
                            tag: heroTag,
                            child: image,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: IconButton.filled(
                          style: IconButton.styleFrom(
                              backgroundColor: Colors.white),
                          icon: const Icon(Icons.close, color: Colors.black),
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      )
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
