import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/theme/ui_theme_models.dart';
import 'package:icarus/theme/ui_theme_tokens.dart';

void main() {
  test('shadow layer json roundtrip preserves values', () {
    const layer = UiShadowLayerDefinition(
      colorValue: 0x66000000,
      blurRadius: 8,
      spreadRadius: 2,
      offsetX: 1,
      offsetY: 3,
    );

    final parsed = UiShadowLayerDefinition.fromJson(layer.toJson());
    expect(parsed.colorValue, layer.colorValue);
    expect(parsed.blurRadius, layer.blurRadius);
    expect(parsed.spreadRadius, layer.spreadRadius);
    expect(parsed.offsetX, layer.offsetX);
    expect(parsed.offsetY, layer.offsetY);
  });

  test('resolved export includes color and shadow maps', () {
    final resolved = UiThemeResolvedData(
      colors: UiThemeTokenRegistry.defaultColorMap(),
      shadows: UiThemeTokenRegistry.defaultShadowMap(),
    );

    final colorExport = resolved.exportColorHexMap();
    final shadowExport = resolved.exportShadowMap();

    expect(colorExport[UiThemeTokenIds.shadPrimary], isNotNull);
    expect(shadowExport[UiThemeTokenIds.shadowCard], isNotNull);
    expect(shadowExport[UiThemeTokenIds.shadowCard]!.isNotEmpty, isTrue);
    expect(shadowExport[UiThemeTokenIds.shadowCard]!.first['color'], startsWith('#'));
  });
}
