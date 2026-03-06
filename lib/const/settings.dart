import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/color_option.dart';
import 'package:icarus/theme/ui_theme_runtime.dart';
import 'package:icarus/theme/ui_theme_tokens.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

class Settings {
  static const double agentSize = 35;
  static const double agentSizeMin = 15;
  static const double agentSizeMax = 45;

  static const double abilitySize = 25;
  static const double abilitySizeMin = 15;
  static const double abilitySizeMax = 35;

  static const double feedbackOpacity = 0.7;
  static const double brushSize = 5;
  static const double freeDrawMinDistance = 3;
  static const bool enableStrokeSimplification = false;
  static const double strokeSimplificationEpsilon = 1.4;
  static const PhysicalKeyboardKey deleteKey = PhysicalKeyboardKey.keyX;

  static Color get abilityBGColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.abilityBg);
  static Color get sideBarColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.sidebarSurface);
  static Color get highlightColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.sidebarHighlight);

  static Color get enemyBGColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.enemyBg);
  static Color get allyBGColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.allyBg);
  static Color get enemyOutlineColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.enemyOutline);
  static Color get allyOutlineColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.allyOutline);

  static Color get attackBadgeColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.attackBadge);
  static Color get defendBadgeColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.defendBadge);
  static Color get mixedBadgeColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.mixedBadge);

  static Color get defaultTagColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.tagNeutral);

  static List<Color> get tagPalette => [
        UiThemeRuntime.current.color(UiThemeTokenIds.tagGreen),
        UiThemeRuntime.current.color(UiThemeTokenIds.tagBlue),
        UiThemeRuntime.current.color(UiThemeTokenIds.tagAmber),
        UiThemeRuntime.current.color(UiThemeTokenIds.tagRed),
        UiThemeRuntime.current.color(UiThemeTokenIds.tagPurple),
      ];

  static Color get favoriteOnColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.favoriteOn);
  static Color get favoriteOffColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.favoriteOff);
  static Color get favoriteRemoveColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.favoriteRemove);

  static Color get scrollbarThumbColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.scrollbarThumb);
  static Color get mapBackdropCenterColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.mapBackdropCenter);
  static Color get mapTileOverlayColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.mapTileOverlay);
  static Color get swatchOutlineColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.swatchOutline);
  static Color get swatchSelectedColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.swatchSelected);
  static Color get textCardBackgroundColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.textCardBackground);
  static Color get imageCardBackgroundColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.imageCardBackground);
  static Color get backdropOverlayColor =>
      UiThemeRuntime.current.color(UiThemeTokenIds.backdropOverlay);

  static List<BoxShadow> get cardForegroundBackdropShadows =>
      UiThemeRuntime.current.boxShadows(UiThemeTokenIds.shadowCard);

  static BoxShadow get cardForegroundBackdrop {
    return cardForegroundBackdropShadows.first;
  }

  static List<BoxShadow> get raisedControlShadows =>
      UiThemeRuntime.current.boxShadows(UiThemeTokenIds.shadowRaised);

  static List<BoxShadow> get favoriteIconShadows =>
      UiThemeRuntime.current.boxShadows(UiThemeTokenIds.shadowFavoriteIcon);

  static List<Shadow> get favoriteIconTextShadows =>
      UiThemeRuntime.current.textShadows(UiThemeTokenIds.shadowFavoriteIcon);

  static List<BoxShadow> get textHandleShadows =>
      UiThemeRuntime.current.boxShadows(UiThemeTokenIds.shadowTextHandle);

  static List<Shadow> get mapTitleTextShadows =>
      UiThemeRuntime.current.textShadows(UiThemeTokenIds.shadowMapTitle);

  static List<BoxShadow> folderGlowShadowsFor(Color folderColor) {
    return UiThemeRuntime.current
        .boxShadows(UiThemeTokenIds.shadowFolderGlow)
        .map(
          (layer) => layer.copyWith(
            color: folderColor.withValues(alpha: layer.color.a),
          ),
        )
        .toList();
  }

  static List<ColorOption> get penColors => [
        ColorOption(color: Colors.white, isSelected: true),
        ColorOption(color: Colors.red, isSelected: false),
        ColorOption(color: Colors.blue, isSelected: false),
        ColorOption(color: Colors.yellow, isSelected: false),
        ColorOption(color: Colors.green, isSelected: false),
      ];

  static final Uri dicordLink = Uri.parse("https://discord.gg/PN2uKwCqYB");

  static const Duration autoSaveOffset = Duration(seconds: 15);
  static const int versionNumber = 42;
  static const String versionName = "3.2.3";

  static const double sideBarContentWidth = 325;
  static const double sideBarPanelWidth = sideBarContentWidth + 20;
  static const double sideBarPanelPaddingLeft = 8;
  static const double sideBarPanelPaddingRight = 8;
  static const double sideBarReservedWidth =
      sideBarPanelWidth + sideBarPanelPaddingLeft + sideBarPanelPaddingRight;

  static final Uri windowsStoreLink = Uri.parse(
      "https://apps.microsoft.com/detail/9PBWHHZRQFW6?hl=en-us&gl=US&ocid=pdpshare");

  static ThemeData get appTheme {
    return ThemeData(
      colorScheme: ColorScheme.dark(
        primary: tacticalVioletTheme.primary,
        secondary: tacticalVioletTheme.secondary,
        error: tacticalVioletTheme.destructive,
        surface: abilityBGColor,
      ),
      dividerColor: Colors.transparent,
      useMaterial3: true,
      expansionTileTheme: const ExpansionTileThemeData(),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(sideBarColor),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.all(8)),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: highlightColor, width: 2),
            ),
          ),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.resolveWith<OutlinedBorder?>(
            (Set<WidgetState> states) {
              if (states.contains(WidgetState.hovered)) {
                return RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: highlightColor, width: 2),
                );
              }
              return RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide.none,
              );
            },
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: highlightColor, width: 2),
        ),
        backgroundColor: sideBarColor,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
        ),
      ),
    );
  }

  static ShadColorScheme get tacticalVioletTheme =>
      UiThemeRuntime.current.shadColorScheme;

  static void showToast(
      {required String message, required Color backgroundColor}) {
    toastification.showCustom(
      autoCloseDuration: const Duration(seconds: 3),
      alignment: Alignment.bottomCenter,
      builder: (context, holder) {
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Settings.tacticalVioletTheme.border,
            ),
          ),
          child: Text(
            message,
            style: ShadTheme.of(context)
                .textTheme
                .small
                .copyWith(color: Colors.white),
          ),
        );
      },
    );
  }

  static double utilityIconSize = 20;
  static double erasingSize = 15;
}


