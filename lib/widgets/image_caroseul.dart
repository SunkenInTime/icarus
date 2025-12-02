import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:path/path.dart' as path;

class ImageCarousel extends ConsumerStatefulWidget {
  const ImageCarousel({
    super.key,
    required this.images,
    this.youtubeLink,
  });
  final List<SimpleImageData> images;
  final String? youtubeLink;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ImageCarouselState();
}

class _ImageCarouselState extends ConsumerState<ImageCarousel> {
  Directory? imageFolderPath;
  final PageController _pageController = PageController();
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadDirectory();
  }

  Future<void> _loadDirectory() async {
    final strategyID = ref.read(strategyProvider).id;
    final dir = await PlacedImageProvider.getImageFolder(strategyID);
    if (mounted) {
      setState(() {
        imageFolderPath = dir;
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (imageFolderPath == null) {
      return const Center(child: CircularProgressIndicator());
    }

    Widget content;
    if (widget.images.isEmpty) {
      content = const Center(
        child: Text(
          'No images available',
          style: TextStyle(color: Colors.white),
        ),
      );
    } else {
      content = Stack(
        alignment: Alignment.center,
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: widget.images.length,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            itemBuilder: (context, index) {
              final image = widget.images[index];
              final fullPath = path.join(
                  imageFolderPath!.path, image.id + image.fileExtension);
              final file = File(fullPath);

              if (!file.existsSync()) {
                return const Center(
                    child: Icon(Icons.broken_image, color: Colors.white));
              }

              return InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(
                  file,
                  fit: BoxFit.contain,
                ),
              );
            },
          ),
          if (widget.images.length > 1) ...[
            if (_currentIndex > 0)
              Positioned(
                left: 8,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                  onPressed: () {
                    _pageController.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  },
                ),
              ),
            if (_currentIndex < widget.images.length - 1)
              Positioned(
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.arrow_forward_ios, color: Colors.white),
                  onPressed: () {
                    _pageController.nextPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  },
                ),
              ),
            Positioned(
              bottom: 24,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(widget.images.length, (index) {
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _currentIndex == index
                          ? Colors.white
                          : Colors.white.withOpacity(0.5),
                    ),
                  );
                }),
              ),
            ),
          ],
        ],
      );
    }

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
          content,
          Positioned(
            top: 24,
            right: 24,
            child: SafeArea(
              child: IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: Colors.white),
                icon: const Icon(Icons.close, color: Colors.black),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
