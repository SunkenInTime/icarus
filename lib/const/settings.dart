import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/color_option.dart';

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
  static const Color highlightColor = Color(0xFF272528);
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

  static const Color backgroundColor = Color(0xFF1B1B1B);
  static final Uri dicordLink = Uri.parse("https://discord.gg/PN2uKwCqYB");

  static const Duration autoSaveOffset = Duration(seconds: 15);
  static const int versionNumber = 15;

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
}
