import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/maps.dart';

/// The sealed navigation catalog: one entry per map naming the navigation
/// chart, its checksum, and the standing heights the elevation menu offers.
const heightAssetDirectory = 'assets/maps/world';

class HeightAssetEntry {
  HeightAssetEntry.fromJson(this.map, Map<String, dynamic> json,
      {this.variant = ''})
      : navigation =
            _filename(json['navigation'], '${map.name}_navigation.json.gz'),
        navigationSha256 = _hashValue(json['navigationSha256']),
        navigationBytes = _positiveInt(json['navigationBytes']),
        observerHeightCm = _finite(json['observerHeightCm']),
        defaultFloorElevationCm = _finite(json['defaultFloorElevationCm']),
        menuElevationsCm = _numbers(json['menuElevationsCm']),
        defenseOffsetSvg = _offset(json['defenseOffsetSvg']),
        variants = _variantEntries(map, json, variant) {
    if ((variant != '' && variant != '.upper') ||
        observerHeightCm != 175 ||
        menuElevationsCm.isEmpty) {
      throw const FormatException('Invalid standing-height catalog metadata.');
    }
  }

  final MapValue map;
  final String variant;
  final List<HeightAssetEntry> variants;
  final String navigation, navigationSha256;
  final int navigationBytes;
  final double observerHeightCm, defaultFloorElevationCm;
  final List<double> menuElevationsCm;
  final Offset defenseOffsetSvg;

  Offset get defenseOffsetCanvas {
    final box = Maps.mapViewBox[map]!;
    final scale = math.min(1240 / box.width, 1000 / box.height);
    return defenseOffsetSvg * scale;
  }
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
