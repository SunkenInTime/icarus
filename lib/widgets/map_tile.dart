import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MapTile extends ConsumerWidget {
  const MapTile({
    super.key,
    required this.name,
    required this.onTap,
    this.isPreview,
  });
  final String name;
  final VoidCallback onTap;
  final bool? isPreview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 180,
          height: (isPreview == null || isPreview == false) ? 65 : null,
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
                      "assets/maps/thumbnails/${name}_thumbnail.webp",
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.center,
                child: Text(
                  name.toUpperCase(),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    shadows: [
                      Shadow(
                        color: Colors.black,
                        blurRadius: 2,
                        offset: Offset(0, 2),
                      )
                    ],
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
