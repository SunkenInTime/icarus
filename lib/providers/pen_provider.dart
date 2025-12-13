import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/color_option.dart';
import 'package:icarus/const/coordinate_system.dart';
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
  final CustomMouseCursor? drawingCursor;
  final CustomMouseCursor? erasingCursor;
  PenState({
    required this.listOfColors,
    required this.color,
    required this.hasArrow,
    required this.isDotted,
    required this.opacity,
    required this.thickness,
    required this.penMode,
    required this.drawingCursor,
    required this.erasingCursor,
  });

  PenState copyWith({
    Color? color,
    bool? hasArrow,
    bool? isDotted,
    double? opacity,
    double? thickness,
    PenMode? penMode,
    List<ColorOption>? listOfColors,
    CustomMouseCursor? drawingCursor,
    CustomMouseCursor? erasingCursor,
  }) {
    return PenState(
      listOfColors: listOfColors ?? this.listOfColors,
      penMode: penMode ?? this.penMode,
      color: color ?? this.color,
      hasArrow: hasArrow ?? this.hasArrow,
      isDotted: isDotted ?? this.isDotted,
      opacity: opacity ?? this.opacity,
      thickness: thickness ?? this.thickness,
      drawingCursor: drawingCursor ?? this.drawingCursor,
      erasingCursor: erasingCursor ?? this.erasingCursor,
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
      drawingCursor: staticDrawingCursor,
      erasingCursor: null,
    );
  }

  Future<void> buildCursors() async {
    final coordinateSystem = CoordinateSystem.instance;
    final erasingSize = coordinateSystem.scale(Settings.erasingSize * 2);

    final drawingCursor = await CustomMouseCursor.icon(
      CustomIcons.drawcursor,
      size: 12,
      hotX: 6,
      hotY: 6,
      color: state.color,
    );

    final erasingCursor = await CustomMouseCursor.icon(
      CustomIcons.drawcursor,
      size: erasingSize,
      hotX: erasingSize ~/ 2,
      hotY: erasingSize ~/ 2,
      color: Settings.tacticalVioletTheme.destructive,
    );

    state = state.copyWith(
      drawingCursor: drawingCursor,
      erasingCursor: erasingCursor,
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
    await buildCursors();
  }

  void toggleArrow() {
    state = state.copyWith(hasArrow: !state.hasArrow);
  }
}
