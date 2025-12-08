import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/color_option.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/main.dart';

enum PenMode { line, freeDraw, square }

class PenState {
  final Color color;

  final bool hasArrow;
  final bool isDotted;

  final double opacity;
  final double thickness;
  final PenMode penMode;

  final List<ColorOption> listOfColors;

  PenState({
    required this.listOfColors,
    required this.color,
    required this.hasArrow,
    required this.isDotted,
    required this.opacity,
    required this.thickness,
    required this.penMode,
  });

  PenState copyWith({
    Color? color,
    bool? hasArrow,
    bool? isDotted,
    double? opacity,
    double? thickness,
    PenMode? penMode,
    List<ColorOption>? listOfColors,
  }) {
    return PenState(
      listOfColors: listOfColors ?? this.listOfColors,
      penMode: penMode ?? this.penMode,
      color: color ?? this.color,
      hasArrow: hasArrow ?? this.hasArrow,
      isDotted: isDotted ?? this.isDotted,
      opacity: opacity ?? this.opacity,
      thickness: thickness ?? this.thickness,
    );
  }
}

final penProvider = NotifierProvider<PenProvider, PenState>(PenProvider.new);

class PenProvider extends Notifier<PenState> {
  @override
  PenState build() {
    return PenState(
      listOfColors: Settings.penColors,
      penMode: PenMode.freeDraw,
      color: Colors.white,
      hasArrow: false,
      isDotted: false,
      opacity: 1,
      thickness: Settings.brushSize,
    );
  }

  void updateValue({
    Color? color,
    bool? hasArrow,
    bool? isDotted,
    double? opacity,
    double? thickness,
    PenMode? penMode,
  }) {
    state = state.copyWith(
      color: color,
      hasArrow: hasArrow,
      isDotted: isDotted,
      opacity: opacity,
      thickness: thickness,
      penMode: penMode,
    );
  }

  void setColor(int index) async {
    List<ColorOption> newColors = [...state.listOfColors];
    Color selectedColor = Colors.white;
    for (final (currentIndex, color) in newColors.indexed) {
      if (currentIndex == index) {
        selectedColor = color.color;
        color.isSelected = true;
      } else {
        color.isSelected = false;
      }
    }

    state = state.copyWith(listOfColors: newColors, color: selectedColor);
  }

  void toggleArrow() {
    state = state.copyWith(hasArrow: !state.hasArrow);
  }
}
