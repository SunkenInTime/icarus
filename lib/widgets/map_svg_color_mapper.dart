import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

/// The three placeholder colors the map SVGs are authored with. Rendering
/// swaps them for a strategy's palette via [MapSvgColorMapper].
class MapSvgSourceColors {
  static const Color base = Color(0xFF271406);
  static const Color detail = Color(0xFFB27C40);
  static const Color highlight = Color(0xFFF08234);
}

class MapSvgColorMapper extends ColorMapper {
  const MapSvgColorMapper(this.replacements);

  MapSvgColorMapper.forPalette(MapThemePalette palette)
      : replacements = {
          MapSvgSourceColors.base.toARGB32(): palette.baseColor,
          MapSvgSourceColors.detail.toARGB32(): palette.detailColor,
          MapSvgSourceColors.highlight.toARGB32(): palette.highlightColor,
        };

  final Map<int, Color> replacements;

  @override
  Color substitute(
    String? id,
    String elementName,
    String attributeName,
    Color color,
  ) {
    final opaqueColorValue = (color.toARGB32() & 0x00FFFFFF) | 0xFF000000;
    final replacement = replacements[opaqueColorValue];
    if (replacement == null) {
      return color;
    }
    // Keep per-element opacity from the original SVG.
    final alpha = (color.a * 255.0).round().clamp(0, 255);
    return replacement.withAlpha(alpha);
  }
}
