import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/const/settings.dart';

/// How far from a bar the pointer counts as on it, in pixels on the screen
/// whatever the zoom.
const _hoverReach = 6.0;

const _turnDuration = Duration(milliseconds: 200);

/// A page's doors on the way to another's, for a page change: the doors
/// changed on the page it's leaving, and curved progress in [0, 1].
typedef MapDoorTransition = ({Set<String> from, double t});

/// How changed [door] is drawn, 0 at rest and 1 changed.
double _changedAmount(
  MapDoor door,
  Set<String> changed,
  MapDoorTransition? transition,
) {
  final to = changed.contains(door.id) ? 1.0 : 0.0;
  if (transition == null) return to;
  final from = transition.from.contains(door.id) ? 1.0 : 0.0;
  return from + (to - from) * transition.t;
}

/// [door]'s line on the canvas, on [isAttack]'s side.
(Offset, Offset) _lineOnCanvas(
  MapDoor door, {
  required double changed,
  required bool isAttack,
}) {
  final coordinates = CoordinateSystem.instance;
  Offset onCanvas(Offset world) => coordinates.coordinateToScreen(
        coordinates.positionForSide(
          canonicalPosition: world,
          reflectionOffset: Offset.zero,
          isAttack: isAttack,
        ),
      );
  final (from, to) = door.worldLine(changed: changed);
  return (onCanvas(from), onCanvas(to));
}

/// The middle of [door]'s bar on the canvas, the same whichever way it's turned.
Offset mapDoorMiddleOnCanvas(MapDoor door, {required bool isAttack}) {
  final (from, to) = _lineOnCanvas(door, changed: 0, isAttack: isAttack);
  return (from + to) / 2;
}

/// One door on the canvas. Only the bar is hit, so what lies beside it stays
/// reachable.
class MapDoorPainter extends CustomPainter {
  MapDoorPainter({
    required this.kind,
    required this.line,
    required this.changed,
    required this.wallColor,
    required this.thickness,
    this.hovered = false,
    this.reach = _hoverReach,
  });

  final MapDoorKind kind;
  final (Offset, Offset) line;
  final double changed;
  final Color wallColor;
  final double thickness;
  final bool hovered;

  /// How far past the bar a hit lands, on the canvas.
  final double reach;

  void _stroke(Canvas canvas, Color color, double width) {
    canvas.drawLine(
      line.$1,
      line.$2,
      Paint()
        ..color = color
        ..strokeWidth = width,
    );
  }

  void _dashes(Canvas canvas, Color color) {
    const dashes = 3;
    final (from, to) = line;
    final step = (to - from) / (dashes * 2 - 1);
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness;
    for (var i = 0; i < dashes; i++) {
      final start = from + step * (i * 2.0);
      canvas.drawLine(start, start + step, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (hovered) {
      _stroke(canvas, Colors.white, thickness + 2);
      _stroke(canvas, Color.lerp(wallColor, Colors.white, 0.4)!, thickness);
      return;
    }
    switch (kind) {
      case MapDoorKind.drop:
        if (changed > 0) {
          _stroke(canvas, wallColor.withValues(alpha: changed), thickness);
        }
      case MapDoorKind.spin:
        _stroke(canvas, wallColor, thickness);
      case MapDoorKind.breakable:
        if (changed < 1) {
          _stroke(
            canvas,
            wallColor.withValues(alpha: 1 - changed),
            thickness,
          );
        }
        if (changed > 0) {
          _dashes(canvas, wallColor.withValues(alpha: changed));
        }
      case MapDoorKind.shutter:
        if (changed < 1) {
          _dashes(canvas, wallColor.withValues(alpha: 1 - changed));
        }
        if (changed > 0) {
          _stroke(canvas, wallColor.withValues(alpha: changed), thickness);
        }
    }
  }

  @override
  bool hitTest(Offset position) {
    final (a, b) = line;
    final along = b - a;
    final span = along.distanceSquared;
    final t = span == 0
        ? 0.0
        : (((position - a).dx * along.dx + (position - a).dy * along.dy) / span)
            .clamp(0.0, 1.0);
    return (a + along * t - position).distance <= reach + thickness / 2;
  }

  @override
  bool shouldRepaint(MapDoorPainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.line != line ||
      oldDelegate.changed != changed ||
      oldDelegate.wallColor != wallColor ||
      oldDelegate.thickness != thickness ||
      oldDelegate.hovered != hovered ||
      oldDelegate.reach != reach;
}

double _barThickness() =>
    CoordinateSystem.instance.worldHeightToScreen(mapDoorBarWorldWidth);

/// [map]'s doors as a capture draws them: [changed] names those changed.
class MapDoorBars extends ConsumerWidget {
  const MapDoorBars({
    super.key,
    required this.map,
    required this.isAttack,
    required this.changed,
    this.transition,
    this.amounts,
  });

  final MapValue map;
  final bool isAttack;
  final Set<String> changed;
  final MapDoorTransition? transition;

  /// How far each door is, for a replay: a door the game moves can stand part
  /// way, and spin through 2. Doors not listed are at rest.
  final Map<String, double>? amounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doors = mapDoorsOf(map);
    if (doors.isEmpty) return const SizedBox.shrink();
    final wallColor = ref.watch(effectiveMapThemePaletteProvider).detailColor;
    double amountOf(MapDoor door) =>
        amounts?[door.id] ??
        (amounts != null ? 0 : _changedAmount(door, changed, transition));
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final door in doors)
          CustomPaint(
            painter: MapDoorPainter(
              kind: door.kind,
              line: _lineOnCanvas(
                door,
                changed: amountOf(door),
                isAttack: isAttack,
              ),
              changed: amountOf(door),
              wallColor: wallColor,
              thickness: _barThickness(),
            ),
          ),
      ],
    );
  }
}

/// The current map's doors on the editor's canvas: above the cones, below
/// everything placed, so a placed item keeps its clicks.
class MapDoorLayer extends ConsumerWidget {
  const MapDoorLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapState = ref.watch(mapProvider);
    final doors = mapDoorsOf(mapState.currentMap);
    if (doors.isEmpty) return const SizedBox.shrink();

    final changed = changedMapDoors(
      ref.watch(utilityProvider),
      mapState.currentMap,
    );
    final transition = ref.watch(transitionProvider);
    final moving = transition.phase != PageTransitionPhase.idle;
    final canClick = !moving &&
        ref.watch(currentStrategyCapabilitiesProvider).canEditPages &&
        ref.watch(interactionStateProvider).itemsInReach;

    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        for (final door in doors)
          _MapDoorBar(
            key: ValueKey('map-door-${door.id}'),
            door: door,
            changed: changed.contains(door.id),
            amount: moving
                ? _changedAmount(
                    door,
                    changed,
                    (
                      from: transition.fromDoors,
                      t: transition.phase == PageTransitionPhase.animating
                          ? transition.progress
                          : 0,
                    ),
                  )
                : null,
            isAttack: mapState.isAttack,
            canClick: canClick,
          ),
      ],
    );
  }
}

class _MapDoorBar extends ConsumerStatefulWidget {
  const _MapDoorBar({
    super.key,
    required this.door,
    required this.changed,
    required this.amount,
    required this.isAttack,
    required this.canClick,
  });

  final MapDoor door;
  final bool changed;

  /// Set during a page change, which sets the pace instead of a click.
  final double? amount;
  final bool isAttack;
  final bool canClick;

  @override
  ConsumerState<_MapDoorBar> createState() => _MapDoorBarState();
}

class _MapDoorBarState extends ConsumerState<_MapDoorBar> {
  bool _hovered = false;

  void _setHovered(bool hovered) {
    if (_hovered != hovered) setState(() => _hovered = hovered);
  }

  @override
  void didUpdateWidget(covariant _MapDoorBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A region that stops taking the pointer can't report it leaving.
    if (!widget.canClick) _hovered = false;
  }

  @override
  Widget build(BuildContext context) {
    final door = widget.door;
    final wallColor = ref.watch(effectiveMapThemePaletteProvider).detailColor;
    final zoom = ref.watch(screenZoomProvider);
    final amount = widget.amount;
    return IgnorePointer(
      ignoring: !widget.canClick,
      child: MouseRegion(
        hitTestBehavior: HitTestBehavior.deferToChild,
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onTap: () => ref.read(utilityProvider.notifier).toggleMapDoor(door),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: amount ?? (widget.changed ? 1 : 0)),
            duration: amount == null ? _turnDuration : Duration.zero,
            curve: Settings.easeOut,
            builder: (context, value, _) {
              final line = _lineOnCanvas(
                door,
                changed: value,
                isAttack: widget.isAttack,
              );
              return CustomPaint(
                painter: MapDoorPainter(
                  kind: door.kind,
                  line: line,
                  changed: value,
                  wallColor: wallColor,
                  thickness: _barThickness(),
                  hovered: _hovered,
                  reach: _hoverReach / zoom,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
