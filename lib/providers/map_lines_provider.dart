import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/map_lines.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/services/app_assets.dart';

/// The lines [map]'s drawing shows. Read once per map and kept: they are
/// small, and a drag shouldn't wait for them twice.
final mapLinesProvider = FutureProvider.family<MapLines, MapValue>(
  (ref, map) async => MapLines.fromSvg(
    await appAssets.loadString('assets/maps/${Maps.mapNames[map]}_map.svg'),
  ),
);
