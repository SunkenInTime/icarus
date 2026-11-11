import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/const/settings.dart';

class MapTile extends ConsumerStatefulWidget {
  const MapTile({
    super.key,
    required this.name,
    required this.onTap,
    this.isPreview = false,
    this.isActive = false,
    this.borderRadius = 10,
  });
  final String name;
  final VoidCallback onTap;
  final bool isPreview;
  final bool isActive;
  final double borderRadius;

  /// The tile's fixed footprint; the map card sizes itself from this.
  static const double width = 180;
  static const double height = 65;

  @override
  ConsumerState<MapTile> createState() => _MapTileState();
}

class _MapTileState extends ConsumerState<MapTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter:
          widget.isPreview ? null : (_) => setState(() => _isHovered = true),
      onExit:
          widget.isPreview ? null : (_) => setState(() => _isHovered = false),
      child: ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(widget.borderRadius)),
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: widget.onTap,
          child: SizedBox(
            width: MapTile.width,
            height: MapTile.height,
            child: Stack(
              children: [
                Positioned.fill(
                  // The tile takes the size its parent gives it: wider in the
                  // map list, shorter in the picker card.
                  child: LayoutBuilder(
                    builder: (context, constraints) => Image(
                      image: _SoftenedThumbnail(
                        'assets/maps/thumbnails/${widget.name}_thumbnail.webp',
                        constraints.biggest,
                      ),
                      fit: BoxFit.fill,
                    ),
                  ),
                ),
                if (_isHovered && !widget.isPreview)
                  Positioned.fill(
                    child: Container(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                Align(
                  alignment: Alignment.center,
                  child: Text(
                    context.l10n.mapNameOf(widget.name).toUpperCase(),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color:
                          widget.isActive ? Settings.accentInk : Colors.white,
                      shadows: const [
                        Shadow(
                          color: Colors.black,
                          blurRadius: 2,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A map's thumbnail as a tile of [size] draws it: covering the tile, at 80%,
/// softened by a 1 px blur, painted once into a picture the tile's size.
///
/// The tiles used to blur and fade the thumbnail as they drew it, two
/// offscreen layers per tile on every frame. Impeller, which draws on macOS,
/// keeps nothing between frames, so scrolling the map picker redrew every
/// visible tile's layers each frame and lagged.
class _SoftenedThumbnail extends ImageProvider<_SoftenedThumbnailKey> {
  const _SoftenedThumbnail(this.asset, this.size);

  final String asset;
  final Size size;

  /// The size the thumbnail is decoded at, kept from before it was painted
  /// once, so the tiles look as they did.
  static const _decodeWidth = 180;
  static const _decodeHeight = 53;

  @override
  Future<_SoftenedThumbnailKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(
      _SoftenedThumbnailKey(asset, size, configuration.devicePixelRatio ?? 1),
    );
  }

  @override
  ImageStreamCompleter loadImage(
    _SoftenedThumbnailKey key,
    ImageDecoderCallback decode,
  ) {
    final completer = OneFrameImageStreamCompleter(_paint(key, decode));
    completer.addEphemeralErrorListener((_, __) {
      // As in ResizeImage: a failed paint must not stay in the cache, or the
      // tile would stay blank until the app restarts. The cache may not hold
      // the key yet when the error arrives.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  static Future<ImageInfo> _paint(
    _SoftenedThumbnailKey key,
    ImageDecoderCallback decode,
  ) async {
    final codec = await decode(
      await rootBundle.loadBuffer(key.asset),
      getTargetSize: (_, __) => const ui.TargetImageSize(
        width: _decodeWidth,
        height: _decodeHeight,
      ),
    );
    final ui.Image thumbnail;
    try {
      thumbnail = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }

    final ratio = key.devicePixelRatio;
    final tile = Offset.zero & key.size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    // What ImageFiltered(blur 1) over Opacity(0.8) over Image(cover) drew.
    canvas.saveLayer(
      tile,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
    );
    canvas.saveLayer(tile, Paint()..color = const Color(0xCC000000));
    paintImage(
      canvas: canvas,
      rect: tile,
      image: thumbnail,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
    canvas
      ..restore()
      ..restore();
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(
        math.max(1, (tile.width * ratio).round()),
        math.max(1, (tile.height * ratio).round()),
      );
      return ImageInfo(image: image, scale: ratio, debugLabel: key.asset);
    } finally {
      picture.dispose();
      thumbnail.dispose();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _SoftenedThumbnail && other.asset == asset && other.size == size;

  @override
  int get hashCode => Object.hash(asset, size);
}

class _SoftenedThumbnailKey {
  const _SoftenedThumbnailKey(this.asset, this.size, this.devicePixelRatio);

  final String asset;
  final Size size;
  final double devicePixelRatio;

  @override
  bool operator ==(Object other) =>
      other is _SoftenedThumbnailKey &&
      other.asset == asset &&
      other.size == size &&
      other.devicePixelRatio == devicePixelRatio;

  @override
  int get hashCode => Object.hash(asset, size, devicePixelRatio);
}
