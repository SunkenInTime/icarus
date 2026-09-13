import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:icarus/const/weapons.dart';

/// Fits the visible silhouette, rather than the transparent kill-feed canvas.
/// The bundled source images stay untouched; these bounds only affect painting.
class WeaponIcon extends StatelessWidget {
  const WeaponIcon({
    super.key,
    required this.weapon,
    required this.width,
    required this.height,
    this.color = Colors.white,
    this.outlineColor,
    this.outlineWidth = 0,
  });

  final WeaponType weapon;
  final double width;
  final double height;
  final Color color;
  final Color? outlineColor;
  final double outlineWidth;

  @override
  Widget build(BuildContext context) {
    if (weapon == WeaponType.none) return const SizedBox.shrink();
    final (size, bounds) = _artworkBounds[weapon]!;
    final icon = SizedBox(
      width: width,
      height: height,
      child: FittedBox(
        fit: BoxFit.contain,
        child: ClipRect(
          child: SizedBox(
            width: bounds.width,
            height: bounds.height,
            child: Stack(
              children: [
                Positioned(
                  left: -bounds.left,
                  top: -bounds.top,
                  width: size.width,
                  height: size.height,
                  child: Image.asset(
                    weapon.iconPath,
                    color: color,
                    filterQuality: FilterQuality.medium,
                    excludeFromSemantics: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (outlineColor == null || outlineWidth <= 0) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.dilate(
            radiusX: outlineWidth,
            radiusY: outlineWidth,
          ),
          child: ColorFiltered(
            colorFilter: ColorFilter.mode(outlineColor!, BlendMode.srcIn),
            child: icon,
          ),
        ),
        icon,
      ],
    );
  }
}

const _artworkBounds = <WeaponType, (Size, Rect)>{
  WeaponType.classic: (Size(256, 96), Rect.fromLTRB(72, 6, 183, 90)),
  WeaponType.shorty: (Size(256, 96), Rect.fromLTRB(1, 12, 255, 90)),
  WeaponType.frenzy: (Size(256, 96), Rect.fromLTRB(72, 6, 186, 92)),
  WeaponType.ghost: (Size(256, 96), Rect.fromLTRB(1, 10, 256, 89)),
  WeaponType.bandit: (Size(256, 140), Rect.fromLTRB(20, 5, 237, 134)),
  WeaponType.sheriff: (Size(256, 96), Rect.fromLTRB(32, 3, 214, 94)),
  WeaponType.bulldog: (Size(384, 96), Rect.fromLTRB(36, 1, 346, 95)),
  WeaponType.guardian: (Size(384, 96), Rect.fromLTRB(2, 7, 382, 87)),
  WeaponType.phantom: (Size(384, 96), Rect.fromLTRB(2, 4, 383, 92)),
  WeaponType.vandal: (Size(384, 96), Rect.fromLTRB(34, 1, 342, 96)),
  WeaponType.bucky: (Size(384, 96), Rect.fromLTRB(2, 10, 382, 84)),
  WeaponType.judge: (Size(384, 96), Rect.fromLTRB(34, 0, 350, 95)),
  WeaponType.stinger: (Size(256, 96), Rect.fromLTRB(3, 1, 251, 95)),
  WeaponType.spectre: (Size(256, 96), Rect.fromLTRB(0, 3, 255, 94)),
  WeaponType.marshal: (Size(512, 96), Rect.fromLTRB(1, 3, 510, 92)),
  WeaponType.outlaw: (Size(512, 96), Rect.fromLTRB(35, 0, 480, 96)),
  WeaponType.operator: (Size(512, 96), Rect.fromLTRB(18, 0, 494, 95)),
  WeaponType.ares: (Size(512, 96), Rect.fromLTRB(18, 1, 495, 96)),
  WeaponType.odin: (Size(384, 96), Rect.fromLTRB(18, 1, 361, 96)),
};
