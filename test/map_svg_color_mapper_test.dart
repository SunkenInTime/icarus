import 'package:flutter/painting.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/map_svg_color_mapper.dart';

void main() {
  final palette = MapThemePalette(
    baseColorValue: 0xFF271406,
    detailColorValue: 0xFFB27C40,
    highlightColorValue: 0xFFF08234,
  );

  // A map widget rebuilt with a mapper made again from the same palette must
  // keep its loaded picture: flutter_svg reloads whenever the loader changes,
  // and the loader compares mappers.
  test('a mapper made again from the same palette gives an equal loader', () {
    SvgAssetLoader loader(MapSvgColorMapper mapper) =>
        SvgAssetLoader('assets/maps/ascent_map.svg', colorMapper: mapper);

    for (final make in [
      MapSvgColorMapper.forPalette,
      MapSvgColorMapper.revealed,
    ]) {
      final again = make(palette.copyWith());
      expect(again, make(palette));
      expect(again.hashCode, make(palette).hashCode);
      expect(loader(again), loader(make(palette)));
    }
  });

  test('the order colours were listed in does not matter', () {
    const red = Color(0xFFFF0000), blue = Color(0xFF0000FF);
    final one = MapSvgColorMapper(const {1: red, 2: blue});
    final other = MapSvgColorMapper(const {2: blue, 1: red});
    expect(other, one);
    expect(other.hashCode, one.hashCode);
  });

  test('mappers for different colours differ', () {
    final other = palette.copyWith(baseColorValue: 0xFF102030);
    expect(MapSvgColorMapper.forPalette(other),
        isNot(MapSvgColorMapper.forPalette(palette)));
    expect(MapSvgColorMapper.revealed(palette),
        isNot(MapSvgColorMapper.forPalette(palette)));
  });
}
