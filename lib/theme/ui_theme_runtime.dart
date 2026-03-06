import 'package:icarus/theme/ui_theme_models.dart';
import 'package:icarus/theme/ui_theme_tokens.dart';

class UiThemeRuntime {
  static UiThemeResolvedData _current = UiThemeResolvedData(
    colors: UiThemeTokenRegistry.defaultColorMap(),
    shadows: UiThemeTokenRegistry.defaultShadowMap(),
  );

  static UiThemeResolvedData get current => _current;

  static void apply(UiThemeResolvedData data) {
    _current = data;
  }
}

