import 'dart:math' as math;

import 'package:flutter/material.dart';

class ThemeColorFormat {
  static String toHex(Color color) {
    final int value = color.toARGB32();
    final alpha = (value >> 24) & 0xFF;
    final rgb = value & 0x00FFFFFF;
    if (alpha == 0xFF) {
      return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
    }
    return '#${value.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  static String toHsl(Color color) {
    final hsl = HSLColor.fromColor(color);
    final hue = hsl.hue.toStringAsFixed(0);
    final sat = (hsl.saturation * 100).toStringAsFixed(1);
    final light = (hsl.lightness * 100).toStringAsFixed(1);
    if (hsl.alpha >= 0.999) {
      return 'hsl($hue, $sat%, $light%)';
    }
    final alpha = hsl.alpha.toStringAsFixed(3);
    return 'hsla($hue, $sat%, $light%, $alpha)';
  }

  static Color? parseHex(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final normalized = trimmed.startsWith('#') ? trimmed.substring(1) : trimmed;
    if (normalized.length != 6 && normalized.length != 8) {
      return null;
    }
    final value = int.tryParse(normalized, radix: 16);
    if (value == null) {
      return null;
    }
    final argb = normalized.length == 6 ? (0xFF000000 | value) : value;
    return Color(argb);
  }

  static Color? parseHsl(String input) {
    final trimmed = input.trim().toLowerCase();
    final regExp = RegExp(
      r'^hsla?\(\s*([-+]?[0-9]*\.?[0-9]+)\s*,\s*([-+]?[0-9]*\.?[0-9]+)%\s*,\s*([-+]?[0-9]*\.?[0-9]+)%\s*(?:,\s*([-+]?[0-9]*\.?[0-9]+)\s*)?\)$',
    );
    final match = regExp.firstMatch(trimmed);
    if (match == null) return null;

    final h = double.tryParse(match.group(1) ?? '');
    final s = double.tryParse(match.group(2) ?? '');
    final l = double.tryParse(match.group(3) ?? '');
    final a = match.group(4) == null
        ? 1.0
        : double.tryParse(match.group(4) ?? '');

    if (h == null || s == null || l == null || a == null) {
      return null;
    }

    final hue = h % 360;
    final saturation = (s / 100).clamp(0.0, 1.0);
    final lightness = (l / 100).clamp(0.0, 1.0);
    final alpha = a.clamp(0.0, 1.0);

    return HSLColor.fromAHSL(alpha, hue, saturation, lightness).toColor();
  }

  static Color? parseFlexible(String input) {
    return parseHex(input) ?? parseHsl(input);
  }

  static Color lerp(Color a, Color b, double t) {
    return Color.lerp(a, b, t.clamp(0.0, 1.0)) ?? a;
  }

  static double normalizeHue(double value) {
    final mod = value % 360;
    return mod < 0 ? mod + 360 : mod;
  }

  static double clampPercent(double value) {
    return math.max(0, math.min(100, value));
  }
}

