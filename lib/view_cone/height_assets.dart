import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/tactical_ground_field.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

const heightAssetDirectory = 'assets/maps/world';

class HeightAssetEntry {
  HeightAssetEntry.fromJson(this.map, Map<String, dynamic> json,
      {this.variant = ''})
      : pack = _filename(json['pack'], '${map.name}$variant.height.bin.gz'),
        packSha256 = _hashValue(json['packSha256']),
        compressedBytes = _positiveInt(json['compressedBytes']),
        rawSha256 = _hashValue(json['rawSha256']),
        rawBytes = _positiveInt(json['rawBytes']),
        navigation =
            _filename(json['navigation'], '${map.name}_navigation.json.gz'),
        navigationSha256 = _hashValue(json['navigationSha256']),
        navigationBytes = _positiveInt(json['navigationBytes']),
        sourceGeometrySha256 = _hashValue(json['sourceGeometrySha256']),
        policySha256 = _hashValue(json['policySha256']),
        observerHeightCm = _finite(json['observerHeightCm']),
        defaultFloorElevationCm = _finite(json['defaultFloorElevationCm']),
        heightDomainMeters = _numbers(json['heightDomainMeters']),
        menuElevationsCm = _numbers(json['menuElevationsCm']),
        defenseOffsetSvg = _offset(json['defenseOffsetSvg']),
        tacticalGroundField = json['tacticalGroundField'] == null
            ? null
            : TacticalGroundAsset.fromJson(
                map, json['tacticalGroundField'] as Map<String, dynamic>,
                variant: variant),
        displayWarp = json['displayWarp'] == null
            ? null
            : DisplayWarpAsset.fromJson(map, json['displayWarp']),
        variants = _variantEntries(map, json, variant),
        uiTransform = Map<String, double>.unmodifiable(
          (json['uiTransform'] as Map<String, dynamic>)
              .map((key, value) => MapEntry(key, _finite(value))),
        ) {
    if ((variant != '' && variant != '.upper') ||
        heightDomainMeters.length != 2 ||
        heightDomainMeters.first >= heightDomainMeters.last ||
        observerHeightCm != 175 ||
        menuElevationsCm.isEmpty ||
        rawBytes > 256 * 1024 * 1024 ||
        compressedBytes > 64 * 1024 * 1024 ||
        !['XMultiplier', 'YMultiplier', 'XScalarToAdd', 'YScalarToAdd']
            .every(uiTransform.containsKey) ||
        uiTransform['XMultiplier'] == 0 ||
        uiTransform['YMultiplier'] == 0) {
      throw const FormatException('Invalid standing-height catalog metadata.');
    }
  }

  final MapValue map;
  final String variant;
  final List<HeightAssetEntry> variants;
  final String pack, packSha256, rawSha256, navigation, navigationSha256;
  final String sourceGeometrySha256, policySha256;
  final int compressedBytes, rawBytes, navigationBytes;
  final double observerHeightCm, defaultFloorElevationCm;
  final List<double> heightDomainMeters, menuElevationsCm;
  final Map<String, double> uiTransform;
  final TacticalGroundAsset? tacticalGroundField;
  final DisplayWarpAsset? displayWarp;
  final Offset defenseOffsetSvg;

  Offset get defenseOffsetCanvas {
    final box = Maps.mapViewBox[map]!;
    final scale = math.min(1240 / box.width, 1000 / box.height);
    return defenseOffsetSvg * scale;
  }

  Offset nativeToUv(Offset point) => Offset(
        uiTransform['XScalarToAdd']! -
            point.dy * 100 * uiTransform['XMultiplier']!,
        uiTransform['YScalarToAdd']! +
            point.dx * 100 * uiTransform['YMultiplier']!,
      );

  VisionWorldProjection get projection => _projection(
      (point) => VisionGeometryMap.projectUv(map, nativeToUv(point)));

  VisionWorldProjection get svgProjection => _projection((point) {
        final uv = nativeToUv(point);
        final rotated =
            switch ((Maps.visionGeometryCwQuarterTurns[map] ?? 0) % 4) {
          1 => Offset(1 - uv.dy, uv.dx),
          2 => Offset(1 - uv.dx, 1 - uv.dy),
          3 => Offset(uv.dy, 1 - uv.dx),
          _ => uv,
        };
        final box = Maps.mapViewBox[map]!;
        final padding = Maps.visionGeometryPadding[map]!;
        return Offset(
            rotated.dx * (box.width + padding.horizontal) - padding.left,
            rotated.dy * (box.height + padding.vertical) - padding.top);
      });
}

class TacticalGroundAsset {
  TacticalGroundAsset.fromJson(MapValue map, Map<String, dynamic> json,
      {String variant = ''})
      : file = _filename(
            json['file'], '${map.name}$variant.tactical-ground.json.gz'),
        sha256 = _hashValue(json['sha256']),
        bytes = _positiveInt(json['bytes']) {
    if (bytes > 8 * 1024 * 1024) {
      throw const FormatException('Tactical ground asset is too large.');
    }
  }
  final String file, sha256;
  final int bytes;
}

class DisplayWarpAsset {
  DisplayWarpAsset.fromJson(MapValue map, dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid display projection asset.');
    }
    file = _filename(value['file'], '${map.name}.display-warp.json.gz');
    sha256 = _hashValue(value['sha256']);
    bytes = _positiveInt(value['bytes']);
    if (bytes > 2 * 1024 * 1024) {
      throw const FormatException('Display projection asset is too large.');
    }
  }
  late final String file, sha256;
  late final int bytes;
}

List<HeightAssetEntry> _variantEntries(
    MapValue map, Map<String, dynamic> json, String variant) {
  final upper = json['upperChart'];
  if (upper == null) return const [];
  if (variant.isNotEmpty || upper is! Map<String, dynamic>) {
    throw const FormatException('Invalid upper-floor chart metadata.');
  }
  const allowed = {
    'pack',
    'packSha256',
    'compressedBytes',
    'rawSha256',
    'rawBytes',
    'heightDomainMeters',
    'tacticalGroundField',
    'retainedFaces'
  };
  if (upper.keys.any((key) => !allowed.contains(key)) ||
      !allowed.difference({'retainedFaces'}).every(upper.containsKey) ||
      upper['tacticalGroundField'] == null) {
    throw const FormatException(
        'Upper chart must share its map and navigation.');
  }
  return List.unmodifiable([
    HeightAssetEntry.fromJson(map, {...json, ...upper, 'upperChart': null},
        variant: '.upper')
  ]);
}

VisionWorldProjection _projection(Offset Function(Offset) project) {
  final origin = project(Offset.zero);
  return VisionWorldProjection(
      origin: origin,
      axisU: project(const Offset(1, 0)) - origin,
      axisV: project(const Offset(0, 1)) - origin);
}

class HeightAssets {
  const HeightAssets(
      {required this.folder,
      required this.entry,
      this.groundField,
      this.displayWarp,
      this.variants = const []});
  final String folder;
  final HeightAssetEntry entry;
  final TacticalGroundField? groundField;
  final DisplayWarp? displayWarp;
  final List<HeightAssets> variants;
  VisionWorldProjection get projection => entry.projection;
  VisionWorldProjection get svgProjection => entry.svgProjection;
  VisionWorldProjection get defenseProjection {
    final reflected = projection.defense;
    return VisionWorldProjection(
        origin: reflected.origin + entry.defenseOffsetCanvas,
        axisU: reflected.axisU,
        axisV: reflected.axisV);
  }

  double get minimumHeightMeters => entry.heightDomainMeters.first;
  double get maximumHeightMeters => entry.heightDomainMeters.last;
}

Future<Map<MapValue, HeightAssetEntry>> loadHeightCatalog(
    {AssetBundle? bundle}) async {
  final json = jsonDecode(await (bundle ?? rootBundle)
      .loadString('$heightAssetDirectory/height_catalog.json'));
  if (json is! Map<String, dynamic> ||
      json['version'] != 1 ||
      json['format'] != 'icarus-height-assets-v1' ||
      json['maps'] is! Map<String, dynamic>) {
    throw const FormatException('Invalid standing-height asset catalog.');
  }
  final maps = json['maps'] as Map<String, dynamic>;
  if (maps.length != MapValue.values.length)
    throw const FormatException('Incomplete standing-height catalog.');
  return Map.unmodifiable({
    for (final map in MapValue.values)
      map:
          HeightAssetEntry.fromJson(map, maps[map.name] as Map<String, dynamic>)
  });
}

Future<HeightAssets> loadHeightAssets(MapValue map,
    {AssetBundle? bundle, Directory? cacheRoot}) async {
  final assets = bundle ?? rootBundle;
  final entry = (await loadHeightCatalog(bundle: assets))[map]!;
  final root = cacheRoot ??
      Directory(path.join(
          (await getApplicationSupportDirectory()).path, 'world-height-v1'));
  return _loadHeightEntry(entry, assets, root);
}

Future<HeightAssets> _loadHeightEntry(
    HeightAssetEntry entry, AssetBundle assets, Directory root) async {
  final data = await assets.load('$heightAssetDirectory/${entry.pack}');
  final folder = await compute(prepareHeightAsset, (
    entry: entry,
    compressed: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    cacheRoot: root.path,
  ));
  TacticalGroundField? groundField;
  final groundAsset = entry.tacticalGroundField;
  if (groundAsset != null) {
    final ground =
        await assets.load('$heightAssetDirectory/${groundAsset.file}');
    groundField = await compute(decodeTacticalGroundField, (
      asset: groundAsset,
      compressed:
          ground.buffer.asUint8List(ground.offsetInBytes, ground.lengthInBytes),
    ));
  }
  DisplayWarp? displayWarp;
  final warpAsset = entry.displayWarp;
  if (warpAsset != null) {
    final data = await assets.load('$heightAssetDirectory/${warpAsset.file}');
    displayWarp = await compute(decodeDisplayWarp, (
      entry: entry,
      compressed:
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    ));
  }
  final variants = <HeightAssets>[];
  for (final variant in entry.variants) {
    variants.add(await _loadHeightEntry(variant, assets, root));
  }
  return HeightAssets(
      folder: folder,
      entry: entry,
      groundField: groundField,
      displayWarp: displayWarp,
      variants: List.unmodifiable(variants));
}

Future<DisplayWarp> decodeDisplayWarp(
    ({HeightAssetEntry entry, Uint8List compressed}) input) async {
  final asset = input.entry.displayWarp;
  if (asset == null) {
    throw const FormatException('Missing display projection descriptor.');
  }
  await _verifyBytes(input.compressed, asset.bytes, asset.sha256);
  final decoded = gzip.decode(input.compressed);
  if (decoded.length > 16 * 1024 * 1024) {
    throw const FormatException('Decoded display projection is too large.');
  }
  final json = jsonDecode(utf8.decode(decoded));
  if (json is! Map<String, dynamic>) {
    throw const FormatException('Invalid display projection document.');
  }
  final warp = DisplayWarp.fromJson(json,
      expectedMap: input.entry.map.name,
      expectedSourceGeometrySha256: input.entry.sourceGeometrySha256,
      expectedProjection: input.entry.svgProjection);
  final box = Offset.zero & Maps.mapViewBox[input.entry.map]!;
  final expectedDefenseOrigin = box.topLeft * 2 +
      Offset(box.width, box.height) +
      input.entry.defenseOffsetSvg;
  if (warp.attackViewBox != box ||
      (warp.defenseOrigin - expectedDefenseOrigin).distance > 1e-7) {
    throw const FormatException('Display projection side binding mismatch.');
  }
  return warp;
}

Future<void> verifyDisplayWarpArtwork(
    DisplayWarp warp, String attackSvg, String defenseSvg) async {
  if (await _sha(utf8.encode(attackSvg)) != warp.attackSha256 ||
      await _sha(utf8.encode(defenseSvg)) != warp.defenseSha256) {
    throw const FormatException(
        'Display projection artwork checksum mismatch.');
  }
}

Future<TacticalGroundField> decodeTacticalGroundField(
    ({TacticalGroundAsset asset, Uint8List compressed}) input) async {
  await _verifyBytes(input.compressed, input.asset.bytes, input.asset.sha256);
  final decoded = gzip.decode(input.compressed);
  if (decoded.length > 64 * 1024 * 1024) {
    throw const FormatException('Decoded tactical ground field is too large.');
  }
  return TacticalGroundField.fromJson(
      jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>);
}

/// Use before decoding navigation so movement and visibility share the sealed source.
Future<Uint8List> loadVerifiedHeightNavigation(MapValue map,
    {AssetBundle? bundle, HeightAssetEntry? catalogEntry}) async {
  final assets = bundle ?? rootBundle;
  final entry = catalogEntry ?? (await loadHeightCatalog(bundle: assets))[map]!;
  if (entry.map != map) {
    throw const FormatException('Navigation catalog map mismatch.');
  }
  final data = await assets.load('$heightAssetDirectory/${entry.navigation}');
  return compute(_verifyNavigation, (
    entry: entry,
    bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
  ));
}

Future<Uint8List> _verifyNavigation(
    ({HeightAssetEntry entry, Uint8List bytes}) input) async {
  await _verifyBytes(
      input.bytes, input.entry.navigationBytes, input.entry.navigationSha256);
  return input.bytes;
}

/// Called on a loader isolate. Cached files are checked and sidecars regenerated
/// from the sealed header before the native library sees them.
Future<String> prepareHeightAsset(
    ({
      HeightAssetEntry entry,
      Uint8List compressed,
      String cacheRoot
    }) input) async {
  final entry = input.entry;
  await _verifyBytes(input.compressed, entry.compressedBytes, entry.packSha256);
  final folder = Directory(
      path.join(input.cacheRoot, '${entry.map.name}-${entry.rawSha256}'));
  await folder.create(recursive: true);
  final rawFile = File(path.join(folder.path, 'height-source.raw'));
  Uint8List? raw;
  if (await rawFile.exists() && await rawFile.length() == entry.rawBytes) {
    final candidate = await rawFile.readAsBytes();
    if (await _sha(candidate) == entry.rawSha256) raw = candidate;
  }
  final cached = raw != null;
  if (!cached) {
    raw = Uint8List.fromList(gzip.decode(input.compressed));
    await _verifyBytes(raw, entry.rawBytes, entry.rawSha256);
  }
  final verifiedRaw = raw;
  final sidecars = heightPackSidecars(verifiedRaw, entry);
  // The native model owns its bytes after open. Replacing an invalid disk cache
  // cannot change an already loaded map.
  if (!cached) {
    await _replaceFile(rawFile, verifiedRaw);
  }
  for (final file in sidecars.entries) {
    final target = File(path.join(folder.path, file.key));
    if (!await target.exists() || await target.readAsString() != file.value) {
      await _replaceFile(target, utf8.encode(file.value));
    }
  }
  return folder.path;
}

Future<void> _replaceFile(File target, List<int> bytes) async {
  final temporary = await Directory(target.parent.path).createTemp('.install-');
  final file = File(path.join(temporary.path, 'payload'));
  try {
    await file.writeAsBytes(bytes, flush: true);
    await file.rename(target.path);
  } finally {
    // This directory was created here and contains only our temporary payload.
    if (await file.exists()) await file.delete();
    await temporary.delete();
  }
}

Map<String, String> heightPackSidecars(Uint8List raw, HeightAssetEntry entry) {
  if (raw.length < 16 ||
      ascii.decode(raw.sublist(0, 4), allowInvalid: true) != 'IHD1')
    throw const FormatException('Invalid height-pack magic.');
  final size = ByteData.sublistView(raw).getUint32(4, Endian.little);
  if (size > 1024 * 1024 || size < 2 || size + 8 > raw.length)
    throw const FormatException('Invalid height-pack header length.');
  final header =
      jsonDecode(utf8.decode(raw.sublist(8, 8 + size))) as Map<String, dynamic>;
  final base = (8 + size + 7) ~/ 8 * 8;
  if (header['version'] != 1 ||
      header['packerVersion'] != 2 ||
      header['map'] != entry.map.name ||
      header['sourceGeometrySha256'] != entry.sourceGeometrySha256 ||
      header['policySha256'] != entry.policySha256 ||
      !listEquals(
          _numbers(header['heightDomainMeters']), entry.heightDomainMeters))
    throw const FormatException('Height-pack source mismatch.');
  final ground = entry.tacticalGroundField;
  if (ground == null) {
    if (header['tacticalGroundFieldSha256'] != null ||
        header['coordinatePolicy'] == 'tactical-floor-relative-v1') {
      throw const FormatException(
          'Missing tactical ground field catalog entry.');
    }
  } else if (header['coordinatePolicy'] != 'tactical-floor-relative-v1' ||
      header['tacticalGroundFieldSha256'] != ground.sha256) {
    throw const FormatException('Height-pack tactical ground field mismatch.');
  }
  final arrays = header['arrays'] as Map<String, dynamic>;
  const types = {
    'vertices': ('float64', 8, [3]),
    'faces': ('uint32', 4, [3]),
    'bounds': ('float64', 8, [6]),
    'nodes': ('int32', 4, [4]),
    'faceMasks': ('int32', 4, <int>[]),
    'maskedUvs': ('float64', 8, [3, 2]),
    'maskedMaterials': ('uint32', 4, <int>[])
  };
  if (arrays.length != types.length)
    throw const FormatException('Unexpected height-pack arrays.');
  final ranges = <(int, int)>[];
  final arrayLines = <String>[];
  final records = <String, int>{};
  void range(int offset, int bytes) {
    if (offset < 0 || bytes < 0 || base + offset + bytes > raw.length)
      throw const FormatException('Height-pack array outside payload.');
    if (bytes > 0) ranges.add((offset, offset + bytes));
  }

  for (final definition in types.entries) {
    final data = arrays[definition.key] as Map<String, dynamic>;
    final (dtype, width, suffix) = definition.value;
    final offset = _nonnegativeInt(data['offset']);
    final count = _nonnegativeInt(data['count']);
    final shape = (data['shape'] as List).map(_nonnegativeInt).toList();
    if (data['dtype'] != dtype ||
        offset % width != 0 ||
        shape.length != suffix.length + 1 ||
        !listEquals(shape.skip(1).toList(), suffix) ||
        shape.fold(1, (a, b) => a * b) != count)
      throw const FormatException('Invalid height-pack array layout.');
    range(offset, count * width);
    records[definition.key] = shape.first;
    arrayLines.add('${definition.key} ${base + offset} $count');
  }
  if (records['vertices'] == 0 ||
      records['faces'] == 0 ||
      records['nodes'] == 0 ||
      records['bounds'] != records['nodes'] ||
      records['faceMasks'] != records['faces'] ||
      records['maskedUvs'] != records['maskedMaterials'])
    throw const FormatException('Inconsistent height-pack array counts.');
  final textures = header['textures'] as List;
  final textureLines = <String>[];
  for (var index = 0; index < textures.length; index++) {
    final t = textures[index] as Map<String, dynamic>;
    final width = _positiveInt(t['width']),
        height = _positiveInt(t['height']),
        offset = _nonnegativeInt(t['offset']);
    range(offset, width * height);
    textureLines.add('$index $width $height ${base + offset}');
  }
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  for (var i = 1; i < ranges.length; i++) {
    if (ranges[i].$1 < ranges[i - 1].$2)
      throw const FormatException('Overlapping height-pack arrays.');
  }
  const wraps = {'repeat': 0, 'clamp': 1, 'mirror': 2, 'black': 3};
  final materialIds = <int>{};
  final materialLines = <String>[];
  for (final item in header['materials'] as List) {
    final m = item as Map<String, dynamic>;
    final material = _nonnegativeInt(m['material']),
        texture = _nonnegativeInt(m['texture']);
    final threshold = _finite(m['threshold']),
        scale = _finite(m['alphaScale']),
        bias = _finite(m['alphaBias']);
    if (!materialIds.add(material) ||
        texture >= textures.length ||
        !wraps.containsKey(m['wrapS']) ||
        !wraps.containsKey(m['wrapT']))
      throw const FormatException('Invalid height-pack alpha material.');
    materialLines.add(
        '$material $texture $threshold $scale $bias ${wraps[m['wrapS']]} ${wraps[m['wrapT']]}');
  }
  return {
    'arrays.txt': arrayLines.join('\n'),
    'alpha-textures.txt': textureLines.join('\n'),
    'alpha-materials.txt': materialLines.join('\n'),
    'parameters.txt': entry.heightDomainMeters.join(' ')
  };
}

Future<String> _sha(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((v) => v.toRadixString(16).padLeft(2, '0'))
    .join();
Future<void> _verifyBytes(Uint8List bytes, int length, String hash) async {
  if (bytes.length != length || await _sha(bytes) != hash)
    throw const FormatException('Standing-height asset checksum mismatch.');
}

String _filename(dynamic value, String expected) {
  if (value != expected)
    throw const FormatException('Unexpected standing-height asset path.');
  return expected;
}

String _hashValue(dynamic value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value))
    throw const FormatException('Invalid standing-height asset hash.');
  return value;
}

int _nonnegativeInt(dynamic value) {
  if (value is! int || value < 0)
    throw const FormatException('Invalid height-pack integer.');
  return value;
}

int _positiveInt(dynamic value) {
  final result = _nonnegativeInt(value);
  if (result == 0)
    throw const FormatException('Expected positive height-pack integer.');
  return result;
}

double _finite(dynamic value) {
  if (value is! num || !value.isFinite)
    throw const FormatException('Invalid standing-height number.');
  return value.toDouble();
}

List<double> _numbers(dynamic value) =>
    List.unmodifiable((value as List).map(_finite));

Offset _offset(dynamic value) {
  if (value == null) return Offset.zero;
  final values = _numbers(value);
  if (values.length != 2 || values.any((v) => v.abs() > 5)) {
    throw const FormatException('Invalid defense artwork registration.');
  }
  return Offset(values[0], values[1]);
}
