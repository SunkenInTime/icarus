import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 1, sigmaY: 1),
                    child: Opacity(
                      opacity: .8,
                      child: Image.asset(
                        cacheWidth: 180,
                        cacheHeight: 53,
                        "assets/maps/thumbnails/${widget.name}_thumbnail.webp",
                        fit: BoxFit.cover,
                      ),
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
                    widget.name.toUpperCase(),
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
