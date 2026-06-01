import 'package:flutter/material.dart';
import 'package:icarus/widgets/better_color_picker.dart';

const icarusColorPickerStyle = BetterColorPickerStyle(
  darkPalette: BetterColorPickerPalette(
    surface: Color(0xff18181b),
    foreground: Color(0xfffafafa),
    mutedForeground: Color(0xffa1a1aa),
    inputBorder: Color(0xff27272a),
    fieldFill: Color(0xff27272a),
  ),
  lightPalette: BetterColorPickerPalette(
    surface: Color(0xff18181b),
    foreground: Color(0xfffafafa),
    mutedForeground: Color(0xffa1a1aa),
    inputBorder: Color(0xff27272a),
    fieldFill: Color(0xff27272a),
  ),
  textStyle: TextStyle(
    color: Color(0xfffafafa),
    fontSize: 13,
  ),
  monospaceTextStyle: TextStyle(
    color: Color(0xfffafafa),
    fontSize: 13,
    fontFeatures: [FontFeature.tabularFigures()],
  ),
  mainSliderRadius: 6,
  channelSliderRadius: 4,
  fieldRadius: 6,
  swatchRadius: 6,
  dialogWidth: 320,
);
