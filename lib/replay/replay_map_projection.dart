import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/map_artwork_registration.dart';
import 'package:icarus/const/maps.dart';

/// Places Valorant game-world positions on Icarus's maps.
///
/// A replay gives positions in Unreal centimetres. Each map's attack SVG was
/// registered to the game's geometry in "native" metres, which is Unreal with
/// Y flipped (the geometry went through Blender): native = (x, -y) / 100.
/// Real replay positions confirm that convention; every other swap or sign
/// puts a third or more of the players off the map.
class ReplayMapProjection {
  ReplayMapProjection._(this.map, this._native)
      : _viewBox = Maps.mapViewBox[map]! {
    _scale = math.min(
      _mapWidth / _viewBox.width,
      _worldHeight / _viewBox.height,
    );
    _offset = Offset(
      (_worldWidth - _viewBox.width * _scale) / 2,
      (_worldHeight - _viewBox.height * _scale) / 2,
    );
  }

  /// null when the map path isn't one of Icarus's maps.
  static ReplayMapProjection? forMapPath(String mapPath) {
    final segments = mapPath.split('/');
    final folder = segments.indexOf('Maps');
    if (folder < 0 || folder + 1 >= segments.length) return null;
    final map = mapsByCodename[segments[folder + 1]];
    return map == null ? null : forMap(map);
  }

  static ReplayMapProjection forMap(MapValue map) => _projections.putIfAbsent(
      map, () => ReplayMapProjection._(map, _nativeToAttackSvg[map]!));

  static final _projections = <MapValue, ReplayMapProjection>{};

  /// Riot's folder names under /Game/Maps/, from valorant-api.com /v1/maps
  /// `mapUrl` and the paths replays record.
  static const mapsByCodename = <String, MapValue>{
    'Ascent': MapValue.ascent,
    'Duality': MapValue.bind,
    'Triad': MapValue.haven,
    'Bonsai': MapValue.split,
    'Port': MapValue.icebox,
    'Foxtrot': MapValue.breeze,
    'Canyon': MapValue.fracture,
    'Pitt': MapValue.pearl,
    'Jam': MapValue.lotus,
    'Juliett': MapValue.sunset,
    'Infinity': MapValue.abyss,
    'Rook': MapValue.corrode,
    'Plummet': MapValue.summit,
  };

  // The canvas frame SvgHeightMapTransform draws the SVG into.
  static const _worldHeight = 1000.0;
  static const _mapWidth = 1240.0;
  static const _worldWidth = _worldHeight * 16 / 9;

  final MapValue map;
  final _Affine _native;
  final Size _viewBox;
  late final double _scale;
  late final Offset _offset;

  /// Game-world cm (Unreal x, y) -> the point on the attack-side SVG.
  Offset attackSvgPoint(double x, double y) => _native.apply(x / 100, -y / 100);

  /// Game-world cm (Unreal x, y) -> the point on the defense-side SVG, which
  /// is the attack artwork turned half way round and nudged by its measured
  /// offset.
  Offset defenseSvgPoint(double x, double y) {
    final attack = attackSvgPoint(x, y);
    return Offset(_viewBox.width, _viewBox.height) -
        attack +
        mapDefenseArtworkOffsetSvg[map]!;
  }

  /// Game-world cm (Unreal x, y) -> Icarus's canonical attack-side world point,
  /// the same space PlacedWidget.position is saved in (CoordinateSystem normalized
  /// 1777.8 x 1000 world, map centred). The defense view is derived by
  /// CoordinateSystem.positionForSide, so this is always the attack-side point.
  ///
  /// This is where the player stands. A widget's saved position is its top
  /// left, so subtract the widget's anchor before saving.
  Offset toWorld(double x, double y) => _offset + attackSvgPoint(x, y) * _scale;

  /// Game yaw in degrees -> the canonical (attack-side) rotation in radians,
  /// stored the way PlacedViewConeAgent.rotation / PlacedAbility.rotation are,
  /// i.e. what you'd save so the cone/ability points the way the player looked.
  ///
  /// Icarus rotation 0 points up the screen and grows clockwise: a drag
  /// toward screen direction (dx, dy) saves atan2(dy, dx) + pi / 2.
  double rotationForYaw(double yawDegrees) {
    final yaw = yawDegrees * math.pi / 180;
    final direction = _native.applyLinear(math.cos(yaw), -math.sin(yaw));
    return math.atan2(direction.dy, direction.dx) + math.pi / 2;
  }

  /// Game centimetres -> Icarus world units at this map's scale (for lengths
  /// such as wall lengths and ranges).
  double worldLength(double centimetres) =>
      centimetres / 100 * _native.scale * _scale;

  // Native metres -> attack SVG, `nativeToAttackSvg` in
  // E:\IcarusWorldAudit\2026-09-06\tactical-alignment-sides-v1\<map>.json.
  // Each composes Riot's minimap UIData transform with the minimap image's
  // registration to the SVG (registration/results/<map>-registration.json,
  // held-out wall corners within 0.6 to 1.0 SVG units RMS).
  static const _nativeToAttackSvg = <MapValue, _Affine>{
    MapValue.ascent: _Affine(3.2969024617778473, 0.0, 161.53717490897037, 0.0,
        -3.2969024617778473, 382.7566201327165),
    MapValue.breeze: _Affine(0.0, -3.328286212568514, 206.72081203021492,
        -3.328286212568514, 0.0, 399.09339093388206),
    MapValue.lotus: _Affine(0.0, -4.035511936870364, 224.66388337076853,
        -4.035511936870364, 0.0, 466.17819818095813),
    MapValue.icebox: _Affine(-3.356078076230773, 0.0, 107.3159767810122, 0.0,
        3.3560780762308013, 269.01824348297737),
    MapValue.sunset: _Affine(0.0, -3.477221798286024, 204.47250012145628,
        -3.4772217982860525, 0.0, 243.89380298905087),
    MapValue.split: _Affine(3.9096202760835865, 0.0, 138.54452327926526, 0.0,
        -3.909620276083558, 413.8068381306813),
    MapValue.haven: _Affine(3.508288059722588, 0.0, 130.96278361326088, 0.0,
        -3.508288059722645, 513.7054628036302),
    MapValue.fracture: _Affine(0.0, -3.9644760557984, 272.4131479231745,
        -3.9644760557984, 0.0, 570.5067774183195),
    MapValue.abyss: _Affine(3.7696493669158144, 0.0, 226.36573016122568, 0.0,
        -3.7696493669158144, 236.55264870976578),
    MapValue.pearl: _Affine(0.0, -3.678878574846294, 225.5718974563849,
        -3.678878574846351, 0.0, 432.9945225279285),
    MapValue.bind: _Affine(0.0, -2.7287645932343594, 225.8488984336913,
        -2.7287645932343594, 0.0, 460.3265678718115),
    MapValue.corrode: _Affine(3.207988614324904, 0.0, 193.13706506207424, 0.0,
        -3.207988614324904, 244.73547402968953),
    MapValue.summit: _Affine(0.0, -3.3971209017364643, 4.613976772523586,
        -3.397120901736457, 0.0, 453.75554061572274),
  };
}

/// Row-major 2x3 matrix: (x, y) -> (a x + b y + c, d x + e y + f).
class _Affine {
  const _Affine(this.a, this.b, this.c, this.d, this.e, this.f);

  final double a, b, c, d, e, f;

  Offset apply(double x, double y) =>
      Offset(a * x + b * y + c, d * x + e * y + f);

  Offset applyLinear(double x, double y) =>
      Offset(a * x + b * y, d * x + e * y);

  /// SVG units per native metre; every map's matrix is a uniform scale.
  double get scale => math.sqrt((a * e - b * d).abs());
}
