import 'dart:convert';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/map_artwork_registration.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/view_cone/svg_height_cone_cache.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';

/// A map enters the SVG-height runtime only through this reviewed registration.
/// Keep both model sides paired with the exact artwork used to build them.
class SvgHeightMapRegistration {
  const SvgHeightMapRegistration({
    required this.map,
    required this.attackModelAsset,
    required this.defenseModelAsset,
    required this.attackArtworkAsset,
    required this.defenseArtworkAsset,
  });

  final MapValue map;
  final String attackModelAsset;
  final String defenseModelAsset;
  final String attackArtworkAsset;
  final String defenseArtworkAsset;

  String modelAsset(bool isAttack) =>
      isAttack ? attackModelAsset : defenseModelAsset;
  String artworkAsset(bool isAttack) =>
      isAttack ? attackArtworkAsset : defenseArtworkAsset;
  Size get viewBox => Maps.mapViewBox[map]!;
  Offset get defenseArtworkOffset => mapDefenseArtworkOffsetSvg[map]!;
}

const svgHeightMapRegistrations = <MapValue, SvgHeightMapRegistration>{
  MapValue.ascent: SvgHeightMapRegistration(
    map: MapValue.ascent,
    attackModelAsset: 'assets/maps/ascent_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/ascent_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/ascent_map.svg',
    defenseArtworkAsset: 'assets/maps/ascent_map_defense.svg',
  ),
  MapValue.breeze: SvgHeightMapRegistration(
    map: MapValue.breeze,
    attackModelAsset: 'assets/maps/breeze_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/breeze_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/breeze_map.svg',
    defenseArtworkAsset: 'assets/maps/breeze_map_defense.svg',
  ),
  MapValue.lotus: SvgHeightMapRegistration(
    map: MapValue.lotus,
    attackModelAsset: 'assets/maps/lotus_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/lotus_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/lotus_map.svg',
    defenseArtworkAsset: 'assets/maps/lotus_map_defense.svg',
  ),
  MapValue.icebox: SvgHeightMapRegistration(
    map: MapValue.icebox,
    attackModelAsset: 'assets/maps/icebox_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/icebox_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/icebox_map.svg',
    defenseArtworkAsset: 'assets/maps/icebox_map_defense.svg',
  ),
  MapValue.sunset: SvgHeightMapRegistration(
    map: MapValue.sunset,
    attackModelAsset: 'assets/maps/sunset_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/sunset_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/sunset_map.svg',
    defenseArtworkAsset: 'assets/maps/sunset_map_defense.svg',
  ),
  MapValue.split: SvgHeightMapRegistration(
    map: MapValue.split,
    attackModelAsset: 'assets/maps/split_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/split_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/split_map.svg',
    defenseArtworkAsset: 'assets/maps/split_map_defense.svg',
  ),
  MapValue.haven: SvgHeightMapRegistration(
    map: MapValue.haven,
    attackModelAsset: 'assets/maps/haven_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/haven_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/haven_map.svg',
    defenseArtworkAsset: 'assets/maps/haven_map_defense.svg',
  ),
  MapValue.fracture: SvgHeightMapRegistration(
    map: MapValue.fracture,
    attackModelAsset: 'assets/maps/fracture_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/fracture_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/fracture_map.svg',
    defenseArtworkAsset: 'assets/maps/fracture_map_defense.svg',
  ),
  MapValue.abyss: SvgHeightMapRegistration(
    map: MapValue.abyss,
    attackModelAsset: 'assets/maps/abyss_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/abyss_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/abyss_map.svg',
    defenseArtworkAsset: 'assets/maps/abyss_map_defense.svg',
  ),
  MapValue.pearl: SvgHeightMapRegistration(
    map: MapValue.pearl,
    attackModelAsset: 'assets/maps/pearl_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/pearl_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/pearl_map.svg',
    defenseArtworkAsset: 'assets/maps/pearl_map_defense.svg',
  ),
  MapValue.bind: SvgHeightMapRegistration(
    map: MapValue.bind,
    attackModelAsset: 'assets/maps/bind_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/bind_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/bind_map.svg',
    defenseArtworkAsset: 'assets/maps/bind_map_defense.svg',
  ),
  MapValue.corrode: SvgHeightMapRegistration(
    map: MapValue.corrode,
    attackModelAsset: 'assets/maps/corrode_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/corrode_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/corrode_map.svg',
    defenseArtworkAsset: 'assets/maps/corrode_map_defense.svg',
  ),
  MapValue.summit: SvgHeightMapRegistration(
    map: MapValue.summit,
    attackModelAsset: 'assets/maps/summit_svg_height_attack.json.gz',
    defenseModelAsset: 'assets/maps/summit_svg_height_defense.json.gz',
    attackArtworkAsset: 'assets/maps/summit_map.svg',
    defenseArtworkAsset: 'assets/maps/summit_map_defense.svg',
  ),
};

SvgHeightMapRegistration? svgHeightRegistrationFor(MapValue map) =>
    svgHeightMapRegistrations[map];

bool hasSvgHeightRuntime(MapValue map) =>
    svgHeightMapRegistrations.containsKey(map);

class SvgHeightRuntimeDependencies {
  const SvgHeightRuntimeDependencies();

  Future<Uint8List> loadModel(
          SvgHeightMapRegistration registration, bool isAttack) =>
      rootBundle
          .load(registration.modelAsset(isAttack))
          .then((data) => Uint8List.sublistView(data));

  Future<List<int>> loadArtwork(
          SvgHeightMapRegistration registration, bool isAttack) =>
      rootBundle.load(registration.artworkAsset(isAttack)).then((data) =>
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
}

final svgHeightRuntimeDependenciesProvider =
    Provider<SvgHeightRuntimeDependencies>(
        (ref) => const SvgHeightRuntimeDependencies());

final svgHeightRuntimeProvider = FutureProvider.autoDispose
    .family<SvgHeightRuntime?, MapValue>((ref, map) async {
  final registration = svgHeightRegistrationFor(map);
  if (registration == null) return null;
  var disposed = false;
  SvgHeightRuntime? currentRuntime;
  ref.onDispose(() {
    disposed = true;
    currentRuntime?.dispose();
  });
  try {
    final dependencies = ref.watch(svgHeightRuntimeDependenciesProvider);
    final attackModelFuture = dependencies.loadModel(registration, true);
    final defenseModelFuture = dependencies.loadModel(registration, false);
    final attackArtworkFuture = dependencies.loadArtwork(registration, true);
    final defenseArtworkFuture = dependencies.loadArtwork(registration, false);
    final attack = await _loadSide(
        await attackModelFuture, await attackArtworkFuture,
        registration: registration, expectedSide: 'attack');
    final defense = await _loadSide(
        await defenseModelFuture, await defenseArtworkFuture,
        registration: registration, expectedSide: 'defense');
    if (disposed) return null;
    final runtime = SplitSvgHeightRuntime.forMap(map, attack, defense);
    currentRuntime = runtime;
    attack.enableNativeAcceleration();
    defense.enableNativeAcceleration();
    return runtime;
  } catch (error, stack) {
    AppErrorReporter.reportError(
      'Could not load ${Maps.mapNames[map] ?? map.name} sightlines. View cones are hidden for this map.',
      error: error,
      stackTrace: stack,
      source: 'svgHeightRuntimeProvider.${map.name}',
    );
    rethrow;
  }
});

Future<SvgHeightVisibility> _loadSide(Uint8List source, List<int> artworkBytes,
    {required SvgHeightMapRegistration registration,
    required String expectedSide}) async {
  final decoded = await compute(_decodeModel, source);
  final expectedMap = Maps.mapNames[registration.map]!;
  if (decoded['map'] != expectedMap || decoded['side'] != expectedSide) {
    throw FormatException(
        'Invalid $expectedMap $expectedSide sightline asset.');
  }
  if ((decoded['version'] != 2 && decoded['version'] != 3) ||
      decoded['coordinateSpace'] != 'svg' ||
      decoded['verticalSpace'] != 'meters-source-elevation') {
    throw FormatException(
        '$expectedMap $expectedSide sightline asset uses an unsupported schema.');
  }
  final ground = decoded['ground'];
  if (ground is! Map ||
      ground['vertices'] is! List ||
      (ground['vertices'] as List).isEmpty ||
      ground['triangles'] is! List ||
      (ground['triangles'] as List).isEmpty) {
    throw FormatException(
        '$expectedMap $expectedSide sightline asset has no source ground model.');
  }
  final supports = decoded['supports'];
  if (supports is! List ||
      supports.any((row) =>
          row is! Map ||
          row['label'] is! String ||
          row['floorElevationMeters'] is! num ||
          row['surfaceElevationMeters'] is! num)) {
    throw FormatException(
        '$expectedMap $expectedSide sightline supports lack explicit elevations.');
  }
  final viewBox = decoded['viewBox'];
  final registeredViewBox = registration.viewBox;
  if (viewBox is! List ||
      viewBox.length != 4 ||
      viewBox[0] != 0 ||
      viewBox[1] != 0 ||
      viewBox[2] != registeredViewBox.width ||
      viewBox[3] != registeredViewBox.height) {
    throw FormatException('Invalid $expectedMap $expectedSide SVG view box.');
  }
  final sourceSvg = decoded['sourceSvg'];
  final expectedHash = sourceSvg is Map ? sourceSvg['sha256'] : null;
  if (expectedHash is! String ||
      await _sha256(artworkBytes) != expectedHash.toLowerCase()) {
    throw FormatException(
        '$expectedMap $expectedSide artwork does not match its sightline data.');
  }
  final model = SvgHeightVisibility.fromJson(decoded);
  if (model.receivers.isEmpty) {
    throw FormatException(
        '$expectedMap $expectedSide must contain a receiver footprint.');
  }
  return model;
}

Map<String, dynamic> _decodeModel(Uint8List source) {
  final decoded = jsonDecode(utf8.decode(decodeWorldGzip(source)));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('SVG sightline asset must be an object.');
  }
  return decoded;
}

Future<String> _sha256(List<int> bytes) async {
  final hash = await Sha256().hash(bytes);
  return hash.bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

class SplitSvgHeightRuntime {
  SplitSvgHeightRuntime(SvgHeightVisibility attack, SvgHeightVisibility defense)
      : this.forMap(MapValue.split, attack, defense);

  SplitSvgHeightRuntime.forMap(this.map, this.attack, this.defense)
      : attackCache = SvgHeightConeCache(attack),
        defenseCache = SvgHeightConeCache(defense);

  final MapValue map;
  final SvgHeightVisibility attack, defense;
  final SvgHeightConeCache attackCache, defenseCache;

  SvgHeightVisibility model(bool isAttack) => isAttack ? attack : defense;
  SvgHeightConeCache cache(bool isAttack) =>
      isAttack ? attackCache : defenseCache;

  void dispose() {
    attackCache.clear();
    defenseCache.clear();
    attack.closeNativeAcceleration();
    defense.closeNativeAcceleration();
  }
}

/// Map-neutral name used by production integration. The typedef preserves the
/// existing Split constructor for audit tools while maps move to the registry.
typedef SvgHeightRuntime = SplitSvgHeightRuntime;
