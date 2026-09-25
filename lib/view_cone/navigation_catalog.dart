import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/maps.dart';

/// One entry per map: the navigation chart, its checksum, and the standing
/// heights the elevation menu offers on that map.
const navigationAssetDirectory = 'assets/maps/world';

class NavigationCatalogEntry {
  NavigationCatalogEntry.fromJson(this.map, Map<String, dynamic> json)
      : navigation =
            _filename(json['navigation'], '${map.name}_navigation.json.gz'),
        navigationSha256 = _hashValue(json['navigationSha256']),
        navigationBytes = _positiveInt(json['navigationBytes']),
        observerHeightCm = _finite(json['observerHeightCm']),
        defaultFloorElevationCm = _finite(json['defaultFloorElevationCm']),
        menuElevationsCm = _numbers(json['menuElevationsCm']),
        defenseOffsetSvg = _offset(json['defenseOffsetSvg']) {
    if (observerHeightCm != 175 || menuElevationsCm.isEmpty) {
      throw const FormatException('Invalid navigation catalog metadata.');
    }
  }

  final MapValue map;
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

Future<Map<MapValue, NavigationCatalogEntry>> loadNavigationCatalog(
    {AssetBundle? bundle}) async {
  final json = jsonDecode(await (bundle ?? rootBundle)
      .loadString('$navigationAssetDirectory/navigation_catalog.json'));
  if (json is! Map<String, dynamic> ||
      json['version'] != 1 ||
      json['format'] != 'icarus-navigation-catalog-v1' ||
      json['maps'] is! Map<String, dynamic>) {
    throw const FormatException('Invalid navigation catalog.');
  }
  final maps = json['maps'] as Map<String, dynamic>;
  if (maps.length != MapValue.values.length) {
    throw const FormatException('Incomplete navigation catalog.');
  }
  return Map.unmodifiable({
    for (final map in MapValue.values)
      map: NavigationCatalogEntry.fromJson(
          map, maps[map.name] as Map<String, dynamic>)
  });
}

/// The chart bytes, checked against the catalog before they are decoded.
Future<Uint8List> loadVerifiedNavigation(MapValue map,
    {AssetBundle? bundle, NavigationCatalogEntry? catalogEntry}) async {
  final assets = bundle ?? rootBundle;
  final entry =
      catalogEntry ?? (await loadNavigationCatalog(bundle: assets))[map]!;
  if (entry.map != map) {
    throw const FormatException('Navigation catalog map mismatch.');
  }
  final data =
      await assets.load('$navigationAssetDirectory/${entry.navigation}');
  return compute(_verifyNavigation, (
    entry: entry,
    bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
  ));
}

Future<Uint8List> _verifyNavigation(
    ({NavigationCatalogEntry entry, Uint8List bytes}) input) async {
  final bytes = input.bytes;
  final hash = (await Sha256().hash(bytes))
      .bytes
      .map((v) => v.toRadixString(16).padLeft(2, '0'))
      .join();
  if (bytes.length != input.entry.navigationBytes ||
      hash != input.entry.navigationSha256) {
    throw const FormatException('Navigation chart checksum mismatch.');
  }
  return bytes;
}

String _filename(dynamic value, String expected) {
  if (value != expected) {
    throw const FormatException('Unexpected navigation chart path.');
  }
  return expected;
}

String _hashValue(dynamic value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('Invalid navigation chart hash.');
  }
  return value;
}

int _positiveInt(dynamic value) {
  if (value is! int || value <= 0) {
    throw const FormatException('Invalid navigation chart size.');
  }
  return value;
}

double _finite(dynamic value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('Invalid navigation catalog number.');
  }
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
