import 'package:flutter/widgets.dart';

/// How strongly the abilities below draw their ranges: outlines, fills,
/// inner ranges, wall bodies and area art. Their icons are always drawn in
/// full. A replay draws utility ranges faint so the agents and cones beneath
/// stay readable while the icon still says what was thrown.
class AbilityRangeOpacity extends InheritedWidget {
  const AbilityRangeOpacity({
    super.key,
    required this.opacity,
    required super.child,
  });

  final double opacity;

  /// The opacity ranges are drawn at here: 1 outside any
  /// [AbilityRangeOpacity].
  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AbilityRangeOpacity>()
          ?.opacity ??
      1;

  @override
  bool updateShouldNotify(AbilityRangeOpacity oldWidget) =>
      oldWidget.opacity != opacity;
}
