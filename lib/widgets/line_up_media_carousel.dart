import 'dart:developer';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';

import 'package:icarus/widgets/youtube_view.dart';
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';

class LineUpMediaCarousel extends ConsumerStatefulWidget {
  const LineUpMediaCarousel({
    super.key,
    required this.lineUpId,
    required this.images,
    required this.youtubeLink,
  });
  final List<SimpleImageData> images;
  final String lineUpId;
  final String youtubeLink;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ImageCarouselState();
}

class _ImageCarouselState extends ConsumerState<LineUpMediaCarousel>
    with AutomaticKeepAliveClientMixin {
  int counter = 0;

  Directory? imageFolderPath;

  @override
  bool get wantKeepAlive => true;

  final PageController _pageController = PageController();
  int _currentIndex = 0;
  late final InAppWebViewKeepAlive keepAlive;
  @override
  void initState() {
    super.initState();
    keepAlive = InAppWebViewKeepAlive();
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
    super.build(context);
    // log(widget.youtubeLink ?? 'No youtube link');
    if (imageFolderPath == null) {
      return const Center(child: CircularProgressIndicator());
    }

    Widget content;
    if (widget.images.isEmpty && widget.youtubeLink.isEmpty) {
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
          Padding(
            padding: const EdgeInsets.all(56.0),
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.images.length +
                  (widget.youtubeLink.isNotEmpty ? 1 : 0),
              onPageChanged: (index) {
                setState(() {
                  _currentIndex = index;
                });
              },
              itemBuilder: (context, index) {
                final imageIndex =
                    index - (widget.youtubeLink.isNotEmpty ? 1 : 0);

                if (widget.youtubeLink.isNotEmpty && index == 0) {
                  return YoutubeView(youtubeLink: widget.youtubeLink);
                }

                final image = widget.images[imageIndex];
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
          ),
          if (widget.images.length > 1) ...[
            if (_currentIndex > 0)
              Positioned(
                left: 8,
                child: ShadIconButton.secondary(
                  decoration: ShadDecoration(
                    border: ShadBorder.all(
                        color: Settings.tacticalVioletTheme.border),
                  ),
                  icon: const Icon(LucideIcons.arrowLeft, color: Colors.white),
                  onPressed: () {
                    _pageController.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  },
                ),
              ),
            if (_currentIndex <
                widget.images.length +
                    (widget.youtubeLink.isNotEmpty ? 1 : 0) -
                    1)
              Positioned(
                right: 8,
                child: ShadIconButton.secondary(
                  decoration: ShadDecoration(
                    border: ShadBorder.all(
                        color: Settings.tacticalVioletTheme.border),
                  ),
                  icon: const Icon(LucideIcons.arrowRight, color: Colors.white),
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
              child: Container(
                decoration: BoxDecoration(
                  color: Settings.tacticalVioletTheme.card,
                  borderRadius: BorderRadius.circular(6),
                  border:
                      Border.all(color: Settings.tacticalVioletTheme.border),
                  // boxShadow: const [Settings.cardForegroundBackdrop],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(
                        widget.images.length +
                            (widget.youtubeLink.isNotEmpty ? 1 : 0), (index) {
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _currentIndex == index
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.2),
                        ),
                      );
                    }),
                  ),
                ),
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
              child: Row(
                spacing: 8,
                children: [
                  ShadIconButton.destructive(
                    icon: const Icon(LucideIcons.trash2),
                    decoration: ShadDecoration(
                      border: ShadBorder.all(
                          color: Settings.tacticalVioletTheme.border),
                    ),
                    // tooltip: 'Close',
                    onPressed: () {
                      Navigator.of(context).pop();

                      ref
                          .read(lineUpProvider.notifier)
                          .deleteLineUpById(widget.lineUpId);
                    },
                  ),
                  ShadButton(
                    // height: 32,
                    leading: const Icon(LucideIcons.pencil),
                    // width: 80,
                    child: const Text("Edit"),
                    onPressed: () {
                      String lineUpId = widget.lineUpId;
                      Navigator.of(context).pop();

                      log("Editing line up");
                      showDialog(
                        context: context,
                        builder: (context) => CreateLineupDialog(
                          lineUpId: lineUpId,
                        ),
                      );
                    },
                  ),
                  ShadIconButton.secondary(
                    icon: const Icon(LucideIcons.x),
                    decoration: ShadDecoration(
                      border: ShadBorder.all(
                          color: Settings.tacticalVioletTheme.border),
                    ),
                    // tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
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
