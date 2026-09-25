import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';

import 'package:icarus/widgets/youtube_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Fullscreen viewer for one lineup's media, with delete and edit actions.
class LineUpMediaCarousel extends ConsumerWidget {
  const LineUpMediaCarousel({super.key, required this.linkId});

  final String linkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(
      lineUpProvider.select((state) => state.linkById(linkId)),
    );

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
              if (link != null)
                LineUpMediaPages(
                  images: link.images,
                  youtubeLink: link.youtubeLink,
                  padding: const EdgeInsets.all(56.0),
                ),
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
                        onPressed: () {
                          Navigator.of(context).pop();
                          ref.read(lineUpProvider.notifier).deleteLink(linkId);
                        },
                      ),
                      ShadButton(
                        leading: const Icon(LucideIcons.pencil),
                        child: const Text("Edit"),
                        onPressed: () {
                          Navigator.of(context).pop();
                          showDialog(
                            context: context,
                            builder: (context) =>
                                CreateLineupDialog(linkId: linkId),
                          );
                        },
                      ),
                      ShadIconButton.secondary(
                        icon: const Icon(LucideIcons.x),
                        decoration: ShadDecoration(
                          border: ShadBorder.all(
                              color: Settings.tacticalVioletTheme.border),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
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

/// Pages through a lineup's YouTube link and images with arrows and dots.
/// Embeddable: the lineup panel shows it beside the list, the fullscreen
/// carousel wraps it in a backdrop.
class LineUpMediaPages extends ConsumerStatefulWidget {
  const LineUpMediaPages({
    super.key,
    required this.images,
    required this.youtubeLink,
    this.padding = EdgeInsets.zero,
  });

  final List<SimpleImageData> images;
  final String youtubeLink;
  final EdgeInsets padding;

  @override
  ConsumerState<LineUpMediaPages> createState() => _LineUpMediaPagesState();
}

class _LineUpMediaPagesState extends ConsumerState<LineUpMediaPages>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final PageController _pageController = PageController();
  int _currentIndex = 0;
  late final InAppWebViewKeepAlive keepAlive;

  @override
  void initState() {
    super.initState();
    keepAlive = InAppWebViewKeepAlive();
  }

  @override
  void didUpdateWidget(covariant LineUpMediaPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.images != widget.images ||
        oldWidget.youtubeLink != widget.youtubeLink) {
      _currentIndex = 0;
      if (_pageController.hasClients) _pageController.jumpToPage(0);
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
            padding: widget.padding,
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
                final source = watchStrategyImageSource(
                  ref,
                  (id: image.id, fileExtension: image.fileExtension),
                );
                return switch (source.imageProvider) {
                  final imageProvider? => InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4.0,
                      child: Image(
                        key: ValueKey(image.id),
                        image: imageProvider,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  null => const Center(
                      child: Icon(LucideIcons.imageOff, color: Colors.white),
                    ),
                };
              },
            ),
          ),
          if (widget.images.isNotEmpty) ...[
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

    return content;
  }
}
