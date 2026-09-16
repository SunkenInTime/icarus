import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/color_option.dart';
import 'package:icarus/widgets/inset_shadow_decoration.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

const String kUpdateChannel = String.fromEnvironment(
  'ICARUS_UPDATE_CHANNEL',
  defaultValue: 'stable',
);
final String kResolvedUpdateChannel = normalizeUpdateChannel(kUpdateChannel);

String normalizeUpdateChannel(String channel) {
  switch (channel.trim().toLowerCase()) {
    case 'prerelease':
    case 'pre-release':
    case 'pre_release':
      return 'prerelease';
    case 'stable':
    default:
      return 'stable';
  }
}

String updateChannelLabel(String channel) {
  return switch (normalizeUpdateChannel(channel)) {
    'prerelease' => 'Pre-release',
    _ => 'Stable',
  };
}

Uri buildDesktopUpdaterArchiveUrl(String channel) {
  final resolvedChannel = normalizeUpdateChannel(channel);
  return Uri.parse(
    "https://sunkenintime.github.io/icarus/updates/windows/$resolvedChannel/app-archive.json",
  );
}

class Settings {
  static const double agentSize = 35;
  static const double agentSizeMin = 15;
  static const double agentSizeMax = 45;
  static const double agentWeaponWidthRatio = 0.70;
  static const double agentWeaponHeightRatio = 0.40;
  static const double agentWeaponRightOverhangRatio = 0.18;
  static const double agentWeaponBottomOverhangRatio = 0.12;
  static const double agentWeaponOutlineWidthRatio = 0.035;

  static const double abilitySize = 25;
  static const double abilitySizeMin = 15;
  static const double abilitySizeMax = 35;

  static const Color abilityBGColor = Color(0xFF1B1B1B);
  static const double feedbackOpacity = 0.7;

  // Custom shape edit handles (virtual units). Tune here, not in the widgets:
  // - thickness/length size the visible resize pills and the circle's arc,
  // - hitPadding is the extra invisible grab area added around every handle,
  // - rotationHandleSize sizes the rectangle's rotation glyph,
  // - rotationHandleOffset places it above the rectangle's top edge.
  static const double shapeHandleThickness = 6;
  static const double shapeHandleLength = 24;
  static const double shapeHandleHitPadding = 8;
  static const double shapeRotationHandleSize = 24;
  static const double shapeRotationHandleOffset = 36;

  static const double strokeThicknessThin = 2;
  static const double strokeThicknessSmall = 3;
  static const double strokeThicknessMedium = 5;
  static const double strokeThicknessLarge = 8;
  static const double defaultStrokeThickness = strokeThicknessMedium;
  static const List<double> strokeThicknessOptions = [
    strokeThicknessThin,
    strokeThicknessSmall,
    strokeThicknessMedium,
    strokeThicknessLarge,
  ];
  static const double brushSize = defaultStrokeThickness;
  static const double freeDrawMinDistance = 3;
  static const bool enableStrokeSimplification = false;
  static const double strokeSimplificationEpsilon = 1.4;
  static const PhysicalKeyboardKey deleteKey = PhysicalKeyboardKey.keyX;

  static const Color sideBarColor = Color(0xFF141114);
  static const Color highlightColor = Color(0xff27272a);

  static List<ColorOption> penColors = [
    ColorOption(color: Colors.white, isSelected: true),
    ColorOption(color: Colors.red, isSelected: false),
    ColorOption(color: Colors.blue, isSelected: false),
    ColorOption(color: Colors.yellow, isSelected: false),
    ColorOption(color: Colors.green, isSelected: false),
  ];

  static const Color enemyBGColor = Color.fromARGB(255, 119, 39, 39);
  static const Color allyBGColor = Color.fromARGB(255, 58, 126, 93);

  static const Color enemyOutlineColor = Color.fromARGB(139, 255, 82, 82);
  static const Color allyOutlineColor = Color.fromARGB(106, 105, 240, 175);

  static Color neutralTeamShade(Color color) {
    return HSLColor.fromColor(color).withSaturation(0).toColor();
  }

  static final Uri dicordLink = Uri.parse("https://discord.gg/PN2uKwCqYB");

  static const Duration autoSaveOffset = Duration(seconds: 15);
  static const int versionNumber = 100;
  static const String versionName = "4.6.1";
  static final Uri desktopUpdaterArchiveUrl =
      buildDesktopUpdaterArchiveUrl(kResolvedUpdateChannel);

  static const double sideBarContentWidth = 325;
  static const double sideBarPanelWidth = sideBarContentWidth + 20;
  static const double sideBarPanelPaddingLeft = 8;
  static const double sideBarPanelPaddingRight = 8;
  static const double sideBarReservedWidth =
      sideBarPanelWidth + sideBarPanelPaddingLeft + sideBarPanelPaddingRight;

  static final Uri windowsStoreLink = Uri.parse(
      "https://apps.microsoft.com/detail/9PBWHHZRQFW6?hl=en-us&gl=US&ocid=pdpshare");
  static ThemeData appTheme = ThemeData(
      colorScheme: const ColorScheme.dark(
        // primary: Color.fromARGB(255, 129, 75, 223),
        primary: Colors.deepPurpleAccent,
        secondary: Colors.teal,
        error: Colors.red,
        surface: Color(0xFF1B1B1B),
      ),
      dividerColor: Colors.transparent,
      useMaterial3: true,
      expansionTileTheme: const ExpansionTileThemeData(),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
          // You can also set other properties like textStyle here if needed
          // textStyle: MaterialStateProperty.all<TextStyle>(
          //   const TextStyle(color: Colors.white),
          // ),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor:
              const WidgetStatePropertyAll<Color>(Settings.sideBarColor),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.all(8)),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Settings.highlightColor, width: 2),
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
                  side: const BorderSide(
                      color: Settings.highlightColor, width: 2),
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
          side: const BorderSide(color: Settings.highlightColor, width: 2),
        ),
        backgroundColor: Settings.sideBarColor,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
          // You can also set other properties like textStyle here if needed
          // textStyle: MaterialStateProperty.all<TextStyle>(
          //   const TextStyle(color: Colors.white),
          // ),
        ),
      ));

  /// Violet for lines, glyphs, text, and strokes on dark surfaces: two
  /// steps lighter than [tacticalVioletTheme.primary], which is the fill
  /// under white text and too dark to read as a thin mark.
  static const Color accentInk = Color(0xff8b5cf6); // violet-500

  static const ShadColorScheme tacticalVioletTheme = ShadColorScheme(
    // --- THE GRAYS (UNCHANGED) ---
    // These are the "Zinc" cool grays you liked.
    background: Color(0xff09090b),
    foreground: Color(0xfffafafa),
    card: Color(0xff18181b),
    cardForeground: Color(0xfffafafa),
    popover: Color(0xff18181b),
    popoverForeground: Color(0xfffafafa),
    secondary: Color(0xff27272a),
    secondaryForeground: Color(0xfffafafa),
    muted: Color(0xff27272a),
    mutedForeground: Color(0xffa1a1aa),
    accent: Color(0xff27272a),
    accentForeground: Color(0xfffafafa),
    border: Color(0xff27272a),
    // Zinc-700: field edges sit one step above the panel border so a field
    // on a card still reads as a field.
    input: Color(0xff3f3f46),

    // --- THE NEW PURPLE (UPDATED) ---
    // Violet-700: Higher contrast, deeper, premium look.
    primary: Color(0xff7c3aed),
    primaryForeground: Color(0xfff9fafb), // Pure white text pops perfectly here

    ring: accentInk,

    // Selection can stay a bit darker (Violet-800) or match primary
    selection: Color(0xff4c1d95),

    // --- ERROR STATE ---
    destructive: Color(0xffef4444),
    destructiveForeground: Color(0xfffafafa),
  );

  // Semantic accents for settings tile icons. Each hue follows the meaning of
  // its setting (never the violet action hue, which is reserved for
  // commands/selection).
  static const Color settingsAgentAccent = Color(0xff5da37e); // team markers
  static const Color settingsAbilityAccent = Color(0xff6aa1d8); // utility
  static const Color settingsNeutralAccent = Color(0xffa1a1aa); // greys toggle
  static const Color settingsPersistenceAccent = Color(0xff4b8f86); // saving
  static const Color settingsDiscordAccent = Color(0xff5865f2); // brand blurple
  static const Color settingsMapAccent = Color(0xffb27c40); // map layers

  // Resting glyph color for toolbar controls: a step under foreground so the
  // strip of icons stays quiet, but above mutedForeground, which vanishes at
  // the light stroke weights. Hover still comes up to foreground.
  static const Color toolbarGlyph = Color(0xffd4d4d8); // zinc-300

  // Raised surfaces (a selected tab, a checked tool, a primary command) are
  // lit from above: the fill runs lighter at the top, a bright 1px edge sits
  // inside the top, a dark 1px edge inside the bottom, and a 1px shadow drops
  // beneath. The sides stay bare. Everything paints inside or 1px under the
  // box, so the footprint never changes. Hover stays flat.
  static const Color raisedTopLight = Color(0x24ffffff); // white 14%
  static const Color raisedBottomShade = Color(0x4d000000); // black 30%
  static const List<InsetShadow> raisedRim = [
    InsetShadow(color: raisedTopLight, offset: Offset(0, 1)),
    InsetShadow(color: raisedBottomShade, offset: Offset(0, -1)),
  ];
  static const BoxShadow raisedDropShadow = BoxShadow(
    color: Color(0x73000000), // black 45%
    offset: Offset(0, 1),
  );
  // How far the fill's top and bottom move from the base color, in HSL
  // lightness. These two numbers set the lift for every raised surface.
  static const double raisedTopLift = 0.06;
  static const double raisedBottomDrop = 0.03;

  /// The lit fill for any base color: lighter at the top, darker at the
  /// bottom, so one recipe serves violet, zinc, red, and the rest.
  static LinearGradient raisedGradient(Color base) {
    final hsl = HSLColor.fromColor(base);
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        hsl
            .withLightness((hsl.lightness + raisedTopLift).clamp(0, 1))
            .toColor(),
        hsl
            .withLightness((hsl.lightness - raisedBottomDrop).clamp(0, 1))
            .toColor(),
      ],
    );
  }

  /// A raised surface of [base] color at [radius]. Use this wherever a
  /// selected or primary state would otherwise be a flat fill.
  static InsetShadowDecoration raised(Color base, double radius) =>
      InsetShadowDecoration(
        gradient: raisedGradient(base),
        borderRadius: BorderRadius.circular(radius),
        boxShadows: const [raisedDropShadow],
        shadows: raisedRim,
      );

  /// The raised neutral surface: a selected tab or chip.
  static InsetShadowDecoration raisedSurface(double radius) =>
      raised(tacticalVioletTheme.secondary, radius);

  /// The raised command surface: a checked tool, the active segment, the
  /// active page, anything that would otherwise be a flat `primary` fill.
  static InsetShadowDecoration raisedPrimary(double radius) =>
      raised(tacticalVioletTheme.primary, radius);

  /// Dialogs are panels: one surface step above the canvas at the dialog
  /// radius, one step above the floating panels, so they read as a sheet
  /// from the same family rather than a black box on black.
  static final ShadDialogTheme dialogTheme = ShadDialogTheme(
    backgroundColor: tacticalVioletTheme.card,
    radius: const BorderRadius.all(Radius.circular(16)),
  );

  /// The destructive fill, raised the same way as the primary one.
  static final LinearGradient raisedDestructiveFill =
      raisedGradient(tacticalVioletTheme.destructive);

  /// The primary fill alone, for the Shad theme and animated fills.
  static final LinearGradient raisedPrimaryFill =
      raisedGradient(tacticalVioletTheme.primary);

  // The shadow a floating menu earns (DESIGN.md: 0 8px 24px rgba(0,0,0,0.28)).
  static const BoxShadow floatingMenuShadow = BoxShadow(
    color: Color(0x47000000),
    blurRadius: 24,
    offset: Offset(0, 8),
  );

  static const cardForegroundBackdrop = BoxShadow(
    color: Colors.black54, // High opacity because the background is dark
    blurRadius: 12,
    offset: Offset(0, 4), // Slight downward shift
  );

  static void showToast({
    required String message,
    required Color backgroundColor,
    String? actionLabel,
    VoidCallback? onActionPressed,
  }) {
    toastification.showCustom(
      autoCloseDuration: const Duration(seconds: 3),
      alignment: Alignment.bottomCenter,
      builder: (context, holder) {
        final actionIsVisible = actionLabel != null &&
            actionLabel.isNotEmpty &&
            onActionPressed != null;

        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: Settings.raised(backgroundColor, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  message,
                  style: ShadTheme.of(context)
                      .textTheme
                      .small
                      .copyWith(color: Colors.white),
                ),
              ),
              if (actionIsVisible) const SizedBox(width: 12),
              if (actionIsVisible)
                TextButton(
                  onPressed: onActionPressed,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: Text(actionLabel),
                ),
            ],
          ),
        );
      },
    );
  }

  static double utilityIconSize = 20;
  static double erasingSize = 15;
}
