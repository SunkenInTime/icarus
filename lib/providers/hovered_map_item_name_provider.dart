import 'package:flutter_riverpod/flutter_riverpod.dart';

final hoveredMapItemNameProvider = StateProvider<String?>((ref) => null);

void clearHoveredMapItemNameIfCurrent(WidgetRef ref, String name) {
  final currentName = ref.read(hoveredMapItemNameProvider);
  if (currentName == name) {
    ref.read(hoveredMapItemNameProvider.notifier).state = null;
  }
}
