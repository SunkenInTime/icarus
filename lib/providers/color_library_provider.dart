import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/map_theme_provider.dart';

class ColorLibraryEntry {
  const ColorLibraryEntry({
    required this.color,
    required this.isCustom,
    this.customIndex,
  });

  final Color color;
  final bool isCustom;
  final int? customIndex;
}

final defaultColorLibraryProvider = Provider<List<Color>>((ref) {
  return const [
    Colors.white,
    Colors.red,
    Colors.blue,
    Colors.yellow,
    Colors.green,
  ];
});

final customColorLibraryProvider = Provider<List<Color>>((ref) {
  final colorValues = ref.watch(colorLibraryControllerProvider);
  return colorValues.map(Color.new).toList(growable: false);
});

final colorLibraryProvider = Provider<List<ColorLibraryEntry>>((ref) {
  final defaults = ref.watch(defaultColorLibraryProvider);
  final customColors = ref.watch(customColorLibraryProvider);
  return [
    for (final color in defaults)
      ColorLibraryEntry(color: color, isCustom: false),
    for (final (index, color) in customColors.indexed)
      ColorLibraryEntry(color: color, isCustom: true, customIndex: index),
  ];
});

class ColorLibraryController extends Notifier<List<int>> {
  static const int customColorLimit = 15;

  @override
  List<int> build() {
    return ref.read(appPreferencesProvider).customColorValues;
  }

  bool get canAddColor => state.length < customColorLimit;

  Future<void> addColor(Color color) async {
    if (!canAddColor) return;
    await _save([...state, color.toARGB32()]);
  }

  Future<void> updateColor(int customIndex, Color color) async {
    if (customIndex < 0 || customIndex >= state.length) return;
    final next = [...state];
    next[customIndex] = color.toARGB32();
    await _save(next);
  }

  Future<void> deleteColor(int customIndex) async {
    if (customIndex < 0 || customIndex >= state.length) return;
    final next = [...state]..removeAt(customIndex);
    await _save(next);
  }

  Future<void> _save(List<int> colorValues) async {
    state = colorValues;
    await ref
        .read(appPreferencesProvider.notifier)
        .setCustomColorValues(colorValues);
  }
}

final colorLibraryControllerProvider =
    NotifierProvider<ColorLibraryController, List<int>>(
  ColorLibraryController.new,
);
