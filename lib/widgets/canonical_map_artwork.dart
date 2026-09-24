import 'package:flutter/widgets.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/map_artwork_registration.dart';

/// Places the existing map SVG in the same side frame as saved markers.
///
/// Defense artwork has a small authored translation after reflecting attack.
/// Moving its presentation cancels that translation without resizing the map,
/// rewriting SVG coordinates, or changing a saved strategy.
class CanonicalMapArtwork extends StatelessWidget {
  const CanonicalMapArtwork({
    super.key,
    required this.map,
    required this.isAttack,
    required this.child,
  });

  final MapValue map;
  final bool isAttack;
  final Widget child;

  static const defenseOffsetSvg = mapDefenseArtworkOffsetSvg;

  static Offset translation(MapValue map, Size viewport,
      {required bool isAttack}) {
    if (isAttack || viewport.isEmpty) return Offset.zero;
    final sourceSize = Maps.mapViewBox[map]!;
    final fitted = applyBoxFit(BoxFit.contain, sourceSize, viewport);
    return -defenseOffsetSvg[map]! *
        (fitted.destination.width / sourceSize.width);
  }

  @override
  Widget build(BuildContext context) {
    if (isAttack || defenseOffsetSvg[map] == Offset.zero) return child;
    return LayoutBuilder(
      builder: (context, constraints) => Transform.translate(
        offset: translation(map, constraints.biggest, isAttack: false),
        child: child,
      ),
    );
  }
}
