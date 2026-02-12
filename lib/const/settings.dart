import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/color_option.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

class Settings {
  static const double agentSize = 35;
  static const double agentSizeMin = 15;
  static const double agentSizeMax = 45;

  static const double abilitySize = 25;
  static const double abilitySizeMin = 15;
  static const double abilitySizeMax = 35;

  static const Color abilityBGColor = Color(0xFF1B1B1B);
  static const double feedbackOpacity = 0.7;
  static const double brushSize = 5;
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

  static final Uri dicordLink = Uri.parse("https://discord.gg/PN2uKwCqYB");

  static const Duration autoSaveOffset = Duration(seconds: 15);
  static const int versionNumber = 37;
  static const String versionName = "3.0.2";

  static const double sideBarContentWidth = 325;
  static const double sideBarPanelWidth = sideBarContentWidth + 20;
  static const double sideBarPanelPaddingRight = 8;
  static const double sideBarReservedWidth =
      sideBarPanelWidth + sideBarPanelPaddingRight;

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
    input: Color(0xff27272a),

    // --- THE NEW PURPLE (UPDATED) ---
    // Violet-700: Higher contrast, deeper, premium look.
    primary: Color(0xff7c3aed),
    primaryForeground: Color(0xfff9fafb), // Pure white text pops perfectly here

    // Updated ring to match the new primary
    ring: Color(0xff7c3aed),

    // Selection can stay a bit darker (Violet-800) or match primary
    selection: Color(0xff4c1d95),

    // --- ERROR STATE ---
    destructive: Color(0xffef4444),
    destructiveForeground: Color(0xfffafafa),
  );

  static const cardForegroundBackdrop = BoxShadow(
    color: Colors.black54, // High opacity because the background is dark
    blurRadius: 12,
    offset: Offset(0, 4), // Slight downward shift
  );

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
