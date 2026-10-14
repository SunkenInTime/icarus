import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/view_cone/cone_coverage.dart';

/// The three placeholder colors the map SVGs are authored with. Rendering
/// swaps them for a strategy's palette via [MapSvgColorMapper].
class MapSvgSourceColors {
  static const Color base = Color(0xFF271406);
  static const Color detail = Color(0xFFB27C40);
  static const Color highlight = Color(0xFFF08234);
}

class MapSvgColorMapper extends ColorMapper {
  MapSvgColorMapper(Map<int, Color> replacements)
      : replacements = Map.unmodifiable(replacements);

  MapSvgColorMapper.forPalette(MapThemePalette palette)
      : replacements = Map.unmodifiable({
          MapSvgSourceColors.base.toARGB32(): palette.baseColor,
          MapSvgSourceColors.detail.toARGB32(): palette.detailColor,
          MapSvgSourceColors.highlight.toARGB32(): palette.highlightColor,
        });

  /// The map in [palette] as cones reveal it: the same art with its floor
  /// in [revealedFloorColor] (see `lib/view_cone/cone_coverage.dart`).
  MapSvgColorMapper.revealed(MapThemePalette palette)
      : replacements = Map.unmodifiable({
          MapSvgSourceColors.base.toARGB32(): revealedFloorColor(palette),
          MapSvgSourceColors.detail.toARGB32(): palette.detailColor,
          MapSvgSourceColors.highlight.toARGB32(): palette.highlightColor,
        });

  /// Unmodifiable: mappers are compared by these, so they never change.
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

  // The SVG loader and its picture cache compare mappers, so a mapper made
  // again with the same colours, as views do on every build (a replay builds
  // every frame), must equal the last one. If it didn't, the map would be
  // loaded and drawn again from scratch.
  @override
  bool operator ==(Object other) =>
      other is MapSvgColorMapper && mapEquals(other.replacements, replacements);

  @override
  int get hashCode => Object.hashAllUnordered([
        for (final MapEntry(:key, :value) in replacements.entries)
          Object.hash(key, value),
      ]);
}
