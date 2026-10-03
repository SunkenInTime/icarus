import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/widgets/draggable_widgets/shared/framed_ability_icon_shell.dart';

/// Where a canonical world point is drawn on the canvas, on [isAttack]'s side.
Offset replayScreenPoint(Offset canonical, {required bool isAttack}) {
  final coordinates = CoordinateSystem.instance;
  return coordinates.coordinateToScreen(coordinates.positionForSide(
    canonicalPosition: canonical,
    reflectionOffset: Offset.zero,
    isAttack: isAttack,
  ));
}

/// The rings and trails of a replay moment: utility arriving and leaving,
/// and the path a thrown utility just took.
class ReplayEffectsPainter extends CustomPainter {
  ReplayEffectsPainter({
    required this.effects,
    required this.isAttack,
    required this.iconSize,
  });

  final List<ReplayEffect> effects;
  final bool isAttack;

  /// The ability icon's size on screen; rings never start inside it.
  final double iconSize;

  static Color _ink(bool isAlly) =>
      isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final coordinates = CoordinateSystem.instance;
    double reach(double worldRadius) =>
        math.max(coordinates.worldHeightToScreen(worldRadius), iconSize * 0.75);
    for (final effect in effects) {
      final ink = _ink(effect.isAlly);
      switch (effect) {
        case ReplayActivation(:final centre, :final radius, :final progress):
          // A ring spreading out to the ability's reach as it takes hold.
          final eased = Curves.easeOutCubic.transform(progress);
          final full = reach(radius);
          canvas.drawCircle(
            replayScreenPoint(centre, isAttack: isAttack),
            full * (0.3 + 0.8 * eased),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = coordinates.scale(1 + 2.5 * (1 - progress))
              ..color = ink.withValues(alpha: 0.9 * (1 - progress)),
          );
        case ReplayExit(:final centre, :final radius, :final progress):
          // A brief flash where it stood, and a ring bursting outward.
          final eased = Curves.easeOutCubic.transform(progress);
          final full = reach(radius);
          final at = replayScreenPoint(centre, isAttack: isAttack);
          if (progress < 0.5) {
            canvas.drawCircle(
              at,
              full * 0.9,
              Paint()..color = ink.withValues(alpha: 0.25 * (1 - progress * 2)),
            );
          }
          canvas.drawCircle(
            at,
            full * (0.9 + 0.6 * eased),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = coordinates.scale(2 * (1 - progress) + 0.5)
              ..color = ink.withValues(alpha: 0.8 * (1 - progress)),
          );
        case ReplayFlight(:final trail):
          // The path just flown, fading toward its tail.
          if (trail.length < 2) continue;
          final points = [
            for (final point in trail)
              replayScreenPoint(point, isAttack: isAttack),
          ];
          for (var i = 1; i < points.length; i++) {
            final age = 1 - i / (points.length - 1);
            canvas.drawLine(
              points[i - 1],
              points[i],
              Paint()
                ..strokeCap = StrokeCap.round
                ..strokeWidth = coordinates.scale(2.5)
                ..color = ink.withValues(alpha: 0.85 * (1 - age * 0.8)),
            );
          }
      }
    }
  }

  @override
  bool shouldRepaint(ReplayEffectsPainter oldDelegate) =>
      oldDelegate.effects != effects || oldDelegate.isAttack != isAttack;
}

/// A thrown utility's icon where it is now, a little smaller than the
/// ability it will become.
class ReplayFlightIcon extends StatelessWidget {
  const ReplayFlightIcon({
    super.key,
    required this.flight,
    required this.isAttack,
    required this.abilitySize,
  });

  final ReplayFlight flight;
  final bool isAttack;
  final double abilitySize;

  static const _scale = 0.7;

  @override
  Widget build(BuildContext context) {
    final size = CoordinateSystem.instance.scale(abilitySize * _scale);
    final head = replayScreenPoint(flight.trail.last, isAttack: isAttack);
    return Positioned(
      left: head.dx - size / 2,
      top: head.dy - size / 2,
      child: IgnorePointer(
        child: FramedAbilityIconShell(
          size: abilitySize * _scale,
          isAlly: flight.isAlly,
          child: Image.asset(flight.iconPath, fit: BoxFit.contain),
        ),
      ),
    );
  }
}
