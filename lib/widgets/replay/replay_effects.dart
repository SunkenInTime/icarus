import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/widgets/draggable_widgets/shared/framed_ability_icon_shell.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
        case ReplayFlashed():
          // Drawn over the agents, by [ReplayFlashPainter].
          continue;
        case ReplaySweep():
          // Drawn under the utility, clipped by [ReplaySweepClipper].
          continue;
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

/// Keeps what lies on the cast side of where a sweep has reached: the
/// sweep's whole area, cut square across the way it runs. The icon at the
/// cast point is left out, since the placed ability draws it already.
class ReplaySweepClipper extends CustomClipper<Path> {
  ReplaySweepClipper({
    required this.sweep,
    required this.isAttack,
    required this.iconSide,
  });

  final ReplaySweep sweep;
  final bool isAttack;

  /// The ability icon's side on screen; it stands upright on the cast point.
  final double iconSide;

  /// Far enough to run off any canvas.
  static const _far = 100000.0;

  @override
  Path getClip(Size size) {
    final from = replayScreenPoint(sweep.from, isAttack: isAttack);
    final to = replayScreenPoint(sweep.to, isAttack: isAttack);
    final reach = to - from;
    // Nothing swept yet.
    if (reach.distance < 0.5) return Path();
    final along = reach / reach.distance;
    final across = Offset(-along.dy, along.dx);
    final swept = Path()
      ..addPolygon([
        to + across * _far,
        to - across * _far,
        to - across * _far - along * _far,
        to + across * _far - along * _far,
      ], true);
    final icon = Path()
      ..addRect(
          Rect.fromCenter(center: from, width: iconSide, height: iconSide));
    return Path.combine(PathOperation.difference, swept, icon);
  }

  @override
  bool shouldReclip(ReplaySweepClipper oldClipper) =>
      oldClipper.sweep.from != sweep.from ||
      oldClipper.sweep.to != sweep.to ||
      oldClipper.isAttack != isAttack ||
      oldClipper.iconSide != iconSide;
}

/// A flashed player's icon washed white and marked with a crossed-out eye,
/// its outline filling in a lighter shade as the flash passes. Drawn just
/// above that agent so agents stacked over it stay clear.
class ReplayFlashPainter extends CustomPainter {
  ReplayFlashPainter({
    required this.flash,
    required this.isAttack,
    required this.agentSize,
    required this.neutralTeamColors,
  });

  final ReplayFlashed flash;
  final bool isAttack;

  /// Whether agents wear neutral outlines, as [AgentWidget] draws them.
  final bool neutralTeamColors;

  /// The agent icon's size, as placed widgets are given it.
  final double agentSize;

  /// The agent icon's own corner radius.
  static const _radius = Radius.circular(3);

  /// The wash at full blindness: the agent stays recognisable through it.
  static const _fullWash = 0.7;

  /// The eye's size against the icon.
  static const _eyeShare = 0.55;

  @override
  void paint(Canvas canvas, Size size) {
    final side = CoordinateSystem.instance.scale(agentSize);
    final at = replayScreenPoint(flash.centre, isAttack: isAttack);
    final box = RRect.fromRectAndRadius(
      Rect.fromCenter(center: at, width: side, height: side),
      _radius,
    );
    canvas.drawRRect(
      box,
      Paint()
        ..color = Colors.white.withValues(alpha: _fullWash * flash.blindness),
    );

    final eye = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(LucideIcons.eyeOff.codePoint),
        style: TextStyle(
          fontFamily: LucideIcons.eyeOff.fontFamily,
          package: LucideIcons.eyeOff.fontPackage,
          fontSize: side * _eyeShare,
          color: Settings.flashedEyeInk,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    eye.paint(canvas, at - Offset(eye.width / 2, eye.height / 2));
    eye.dispose();

    // Over the agent's own 1 px border, which lies just inside its box:
    // from top centre, clockwise, as far as the flash has gone.
    final metric =
        _outlineFromTop(box.deflate(0.5)).computeMetrics().first;
    final trace = metric.extractPath(0, metric.length * flash.progress);
    var team =
        flash.isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor;
    if (neutralTeamColors) team = Settings.neutralTeamShade(team);
    canvas.drawPath(
      trace,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Color.lerp(team.withValues(alpha: 1), Colors.white, 0.35)!,
    );
  }

  /// [box]'s outline as one path from its top centre, clockwise.
  static Path _outlineFromTop(RRect box) {
    final r = Radius.circular(box.tlRadiusX);
    return Path()
      ..moveTo(box.center.dx, box.top)
      ..lineTo(box.right - r.x, box.top)
      ..arcToPoint(Offset(box.right, box.top + r.y), radius: r)
      ..lineTo(box.right, box.bottom - r.y)
      ..arcToPoint(Offset(box.right - r.x, box.bottom), radius: r)
      ..lineTo(box.left + r.x, box.bottom)
      ..arcToPoint(Offset(box.left, box.bottom - r.y), radius: r)
      ..lineTo(box.left, box.top + r.y)
      ..arcToPoint(Offset(box.left + r.x, box.top), radius: r)
      ..close();
  }

  @override
  bool shouldRepaint(ReplayFlashPainter oldDelegate) =>
      oldDelegate.flash != flash ||
      oldDelegate.isAttack != isAttack ||
      oldDelegate.agentSize != agentSize ||
      oldDelegate.neutralTeamColors != neutralTeamColors;
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
