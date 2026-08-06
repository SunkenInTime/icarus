import 'dart:math' as math;

import 'package:icarus/const/agents.dart';
import 'package:icarus/const/utilities.dart';

/// The directional vision an ability contributes to a strategy.
class AbilityVisionConeSpec {
  const AbilityVisionConeSpec({
    required this.angleDegrees,
    this.maxRangeMeters,
  });

  /// Full rendered wedge angle in degrees.
  final double angleDegrees;

  /// Fixed in-game detection distance. Null uses the normal adjustable
  /// line-of-sight cone length.
  final double? maxRangeMeters;

  static const double _defaultLength = 50;

  static const Map<(AgentType, int), AbilityVisionConeSpec> _specs = {
    (AgentType.killjoy, 2): AbilityVisionConeSpec(angleDegrees: 100),
    (AgentType.cypher, 2): AbilityVisionConeSpec(angleDegrees: 103),
    (AgentType.raze, 0): AbilityVisionConeSpec(
      angleDegrees: 40,
      maxRangeMeters: 15,
    ),
    (AgentType.gekko, 1): AbilityVisionConeSpec(
      angleDegrees: 40,
      maxRangeMeters: 15,
    ),
  };

  static AbilityVisionConeSpec? forAbility(AbilityInfo ability) {
    return _specs[(ability.type, ability.index)];
  }

  double maximumLength(double mapScale) {
    final rangeMeters = maxRangeMeters;
    if (rangeMeters == null) {
      return ViewConeUtility.maxLength;
    }
    return math.min(
      rangeMeters * AgentData.inGameMeters * mapScale,
      ViewConeUtility.maxLength,
    );
  }

  double resolveLength({
    required double storedLength,
    required double mapScale,
  }) {
    final maximum = maximumLength(mapScale);
    final minimum = math.min(ViewConeUtility.minLength, maximum);
    final fallback = maxRangeMeters == null ? _defaultLength : maximum;
    final requested = storedLength > 0 ? storedLength : fallback;
    return requested.clamp(minimum, maximum);
  }
}
