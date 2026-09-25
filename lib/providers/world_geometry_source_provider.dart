import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';

// Compact source geometry and native navigation are bundled for every map.
const worldGeometryMaps = <MapValue>{...MapValue.values};

final worldGeometryEnabledProvider = Provider.family<bool, MapValue>(
  (ref, map) => worldGeometryMaps.contains(map),
);
