import 'package:flutter/material.dart';
import 'package:icarus/const/maps.dart';

/// One part of a map's aerial picture: where its centre sits, as fractions
/// of the picture's width and height.
typedef _View = ({double x, double y});

/// The parts of each map's picture a card can show. Every map offers the
/// same six (three across, two down) except the few that land on mostly sky
/// or cliff, which are left out.
const List<_View> _allViews = [
  (x: 0.22, y: 0.38),
  (x: 0.50, y: 0.38),
  (x: 0.78, y: 0.38),
  (x: 0.22, y: 0.62),
  (x: 0.50, y: 0.62),
  (x: 0.78, y: 0.62),
];

const Map<MapValue, List<int>> _leftOut = {
  MapValue.breeze: [1],
  MapValue.corrode: [0],
  MapValue.summit: [0, 3],
};

List<_View> _viewsOf(MapValue map) {
  final leftOut = _leftOut[map] ?? const [];
  return [
    for (final (index, view) in _allViews.indexed)
      if (!leftOut.contains(index)) view,
  ];
}

/// How much of the picture's height a card shows.
const double _shownHeight = 0.6;
const double _pictureAspect = 16 / 9;

String aerialPictureOf(MapValue map) =>
    'assets/maps/aerial/${Maps.mapNames[map]}_aerial.webp';

/// [map]'s aerial picture, cropped to one of its views. [seed] picks the
/// view, so the same post shows the same part every time and a page of one
/// map's posts doesn't repeat one picture.
class CommunityMapArt extends StatelessWidget {
  const CommunityMapArt({super.key, required this.map, required this.seed});

  final MapValue map;
  final String seed;

  @override
  Widget build(BuildContext context) {
    final views = _viewsOf(map);
    final view = views[_stableHash(seed) % views.length];
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        var height = box.height / _shownHeight;
        var width = height * _pictureAspect;
        if (width < box.width) {
          width = box.width;
          height = width / _pictureAspect;
        }
        final left =
            (box.width / 2 - view.x * width).clamp(box.width - width, 0.0);
        final top =
            (box.height / 2 - view.y * height).clamp(box.height - height, 0.0);
        return ClipRect(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: left,
                top: top,
                width: width,
                height: height,
                child: Image.asset(
                  aerialPictureOf(map),
                  fit: BoxFit.cover,
                  // Decoded at the size it is drawn, never the full file.
                  cacheWidth: (width * pixelRatio).round().clamp(1, 1600),
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A hash of [value] that is the same in every run and on every platform
/// (String.hashCode is not). Small enough to stay exact on web, where ints
/// are doubles.
int _stableHash(String value) {
  var hash = 7;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) % 1000000007;
  }
  return hash;
}
