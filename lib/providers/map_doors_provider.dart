import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

/// The map doors changed on the page on screen. Rebuilds only when that set
/// changes, not on every edit to a utility, because every cone watches it.
final changedMapDoorsProvider = Provider<Set<String>>((ref) {
  final map = ref.watch(mapProvider.select((state) => state.currentMap));
  final doors = ref.watch(
    utilityProvider.select(
      (utilities) =>
          (changedMapDoors(utilities, map).toList()..sort()).join(','),
    ),
  );
  return doors.isEmpty ? const {} : doors.split(',').toSet();
});
