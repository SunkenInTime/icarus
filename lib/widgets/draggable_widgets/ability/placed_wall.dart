import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/wall_path.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

/// The wall's width and team edge against a map's scale, in virtual units:
/// a placed Viper's Toxic Screen is as wide.
const _wallWidth = 5.0;
const _wallEdge = 1.5;

/// How far from the wall the pointer counts as on it, screen pixels.
const _hoverReach = 7.0;

/// How long the dots outlast the pointer leaving, so it can cross the gap
/// between the wall and a dot.
const _hoverGrace = Duration(milliseconds: 220);

const _dotDiameter = 11.0;
const _pullDotDiameter = 8.0;

/// A guided wall's line as [canvas] draws it, for an icon at [center] on a
/// side's canvas: [sign] turns the saved points to that side.
class WallOnScreen {
  const WallOnScreen._(this.center, this._scale);

  /// Where the icon's middle is drawn on the canvas.
  final Offset center;

  /// Screen pixels per saved world unit, negative on the defending side.
  final double _scale;

  factory WallOnScreen.of(
    PlacedAbility ability, {
    required double mapScale,
    required double abilitySize,
    required bool isAttack,
    Offset? coordinatePosition,
  }) {
    final coordinates = CoordinateSystem.instance;
    final topLeft = screenPositionForWidget(
      widget: ability,
      coordinateSystem: coordinates,
      coordinatePosition: coordinatePosition,
      mapScale: mapScale,
      abilitySize: abilitySize,
      isAttack: isAttack,
    );
    final anchor = ability.data.abilityData!
        .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
        .scale(coordinates.scaleFactor, coordinates.scaleFactor);
    final scale = coordinates.worldHeightToScreen(1);
    return WallOnScreen._(topLeft + anchor, isAttack ? scale : -scale);
  }

  /// Where a saved point is drawn.
  Offset point(Offset saved) => center + saved * _scale;

  /// The saved point drawn at [screen].
  Offset saved(Offset screen) => (screen - center) / _scale;

  /// The icon and every point of [path], on the canvas.
  List<Offset> points(List<Offset> path) => [center, ...path.map(point)];
}

/// One saved length in metres, in world units, on a map of [mapScale].
double wallWorldPerMeter(double mapScale) =>
    CoordinateSystem.virtualLengthInWorld(mapScale * AgentData.inGameMeters);

/// The wall a High Tide starts with: straight up the screen on [isAttack]'s
/// side. Null for any other ability.
List<Offset>? defaultWallPath(
  Ability? ability, {
  required double mapScale,
  required bool isAttack,
}) {
  if (ability is! GuidedWallAbility) return null;
  final length = ability.defaultLengthMeters * wallWorldPerMeter(mapScale);
  return [Offset(0, isAttack ? -length : length)];
}

/// Strokes a wall along [line]: its colour over its team's edge. Stroked, not
/// clipped: on Windows a clip this shape costs a mask drawn on the CPU.
void paintWallStroke(
  Canvas canvas,
  List<Offset> line, {
  required double width,
  required double edge,
  required Color team,
  required double opacity,
}) {
  final path = Path()..addPolygon(line, false);
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  canvas.drawPath(
    path,
    stroke
      ..strokeWidth = width + edge * 2
      ..color = team.withValues(alpha: team.a * opacity),
  );
  canvas.drawPath(
    path,
    stroke
      ..strokeWidth = width
      ..color = Settings.highTideWall.withValues(alpha: opacity),
  );
}

/// One wall on the canvas. Only the wall itself is hit, so what lies beside
/// it stays reachable.
class WallPainter extends CustomPainter {
  WallPainter({
    required this.line,
    required this.team,
    required this.width,
    required this.edge,
    this.opacity = 1,
  });

  /// The drawn line, on the canvas.
  final List<Offset> line;
  final Color team;
  final double width;
  final double edge;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    paintWallStroke(
      canvas,
      line,
      width: width,
      edge: edge,
      team: team,
      opacity: opacity,
    );
  }

  @override
  bool hitTest(Offset position) {
    for (var i = 0; i + 1 < line.length; i++) {
      final a = line[i];
      final along = line[i + 1] - a;
      final span = along.distanceSquared;
      final t = span == 0
          ? 0.0
          : (((position - a).dx * along.dx + (position - a).dy * along.dy) /
                  span)
              .clamp(0.0, 1.0);
      if ((a + along * t - position).distance <= _hoverReach + width / 2) {
        return true;
      }
    }
    return false;
  }

  @override
  bool shouldRepaint(WallPainter oldDelegate) =>
      !listEquals(oldDelegate.line, line) ||
      oldDelegate.team != team ||
      oldDelegate.width != width ||
      oldDelegate.edge != edge ||
      oldDelegate.opacity != opacity;
}

/// The team colour of a wall, as agents' outlines take it.
Color wallTeamColor(bool isAlly, {required bool neutralTeamColors}) {
  final team = isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor;
  return neutralTeamColors ? Settings.neutralTeamShade(team) : team;
}

/// A wall's pixel width on a map of [mapScale].
double wallStrokeWidth(double mapScale) =>
    CoordinateSystem.instance.scale(_wallWidth * mapScale);

/// A wall's team edge on a map, in pixels.
double wallStrokeEdge() => CoordinateSystem.instance.scale(_wallEdge);

/// Every wall's dots, over everything else on the canvas. Hovering a wall's
/// icon shows them too.
class PlacedWallHandleList extends ConsumerWidget {
  const PlacedWallHandleList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(hoveredDeleteTargetProvider, (previous, next) {
      if (previous?.id == next?.id) return;
      final hover = ref.read(wallHoverProvider.notifier);
      if (previous != null) hover.leave(previous.id);
      final hasWall = ref.read(abilityProvider).any(
            (ability) =>
                ability.id == next?.id &&
                ability.data.abilityData is GuidedWallAbility,
          );
      if (hasWall) hover.enter(next!.id);
    });
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final ability in ref.watch(abilityProvider))
          if (ability.data.abilityData is GuidedWallAbility)
            EditorEntityLayer(
              key: ValueKey('wall-handles-${ability.id}'),
              id: ability.id,
              kind: SelectableKind.ability,
              child: PlacedWallHandles(ability: ability),
            ),
      ],
    );
  }
}

/// The wall whose dots are showing, by ability id. Set on hover and held
/// briefly after it, so the pointer can cross from the wall to a dot.
final wallHoverProvider =
    NotifierProvider<WallHoverNotifier, String?>(WallHoverNotifier.new);

class WallHoverNotifier extends Notifier<String?> {
  Timer? _leaving;

  @override
  String? build() {
    ref.onDispose(() => _leaving?.cancel());
    return null;
  }

  void enter(String id) {
    _leaving?.cancel();
    state = id;
  }

  void leave(String id) {
    if (state != id) return;
    _leaving?.cancel();
    _leaving = Timer(_hoverGrace, () {
      if (state == id) state = null;
    });
  }
}

/// A wall being shaped by a dot: drawn from here until the drag ends and
/// saves it.
typedef WallDraft = ({String id, List<Offset> path});

final wallDraftProvider =
    NotifierProvider<WallDraftNotifier, WallDraft?>(WallDraftNotifier.new);

/// The path being shaped for the ability [id], when one is.
List<Offset>? _draftPathOf(WidgetRef ref, String id) => ref.watch(
      wallDraftProvider.select(
        (draft) => draft?.id == id ? draft!.path : null,
      ),
    );

class WallDraftNotifier extends Notifier<WallDraft?> {
  @override
  WallDraft? build() => null;

  void set(WallDraft? draft) => state = draft;
}

/// The ability whose icon is being dragged. Its wall rides the drag's
/// feedback, so the one on the canvas steps aside.
final wallCarriedProvider =
    NotifierProvider<WallCarriedNotifier, String?>(WallCarriedNotifier.new);

class WallCarriedNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? id) => state = id;
}

/// Every wall on the page, under the abilities.
class PlacedWallList extends ConsumerWidget {
  const PlacedWallList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final ability in ref.watch(abilityProvider))
          if (ability.data.abilityData is GuidedWallAbility)
            PlacedWall(key: ValueKey('wall-${ability.id}'), ability: ability),
      ],
    );
  }
}

/// The pointer's hold on a wall: it shows the dots and makes the delete key
/// mean this ability. A region taken away under the pointer reports no exit,
/// so whoever removes one lets go here.
mixin _WallPointer<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  final Object _ownerToken = Object();
  ProviderContainer? _container;
  String? _heldId;

  void _pointerEntered(String id) {
    _heldId = id;
    ref.read(wallHoverProvider.notifier).enter(id);
    ref.read(hoveredDeleteTargetProvider.notifier).state =
        HoveredDeleteTarget.ability(id: id, ownerToken: _ownerToken);
  }

  void _pointerExited() => _release(_container!);

  void _release(ProviderContainer container) {
    final id = _heldId;
    if (id == null) return;
    _heldId = null;
    container.read(wallHoverProvider.notifier).leave(id);
    final hovered = container.read(hoveredDeleteTargetProvider);
    if (hovered?.ownerToken == _ownerToken) {
      container.read(hoveredDeleteTargetProvider.notifier).state = null;
    }
  }

  /// Lets go after this frame, for a build that just took the region away.
  void _releaseAfterFrame() {
    if (_heldId == null) return;
    final container = _container!;
    WidgetsBinding.instance.addPostFrameCallback((_) => _release(container));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    _releaseAfterFrame();
    super.dispose();
  }
}

class PlacedWall extends ConsumerStatefulWidget {
  const PlacedWall({super.key, required this.ability});

  final PlacedAbility ability;

  @override
  ConsumerState<PlacedWall> createState() => _PlacedWallState();
}

class _PlacedWallState extends ConsumerState<PlacedWall>
    with _WallPointer<PlacedWall> {
  @override
  Widget build(BuildContext context) {
    final ability = widget.ability;
    final path = _draftPathOf(ref, ability.id) ?? ability.wallPath;
    final carried = ref.watch(wallCarriedProvider) == ability.id;
    if (path == null || path.isEmpty || carried) {
      _releaseAfterFrame();
      return const SizedBox.shrink();
    }

    final mapState = ref.watch(mapProvider);
    final mapScale = Maps.mapScale[mapState.currentMap] ?? 1;
    final settings = ref.watch(strategySettingsProvider);
    final wall = WallOnScreen.of(
      ability,
      mapScale: mapScale,
      abilitySize: settings.abilitySize,
      isAttack: mapState.isAttack,
    );
    // While the selection is dragged, the wall goes with its icon.
    final shift = ref.watch(
      canvasGroupDragProvider.select(
        (drag) => drag != null && drag.ids.contains(ability.id) ? drag.by : null,
      ),
    );
    return Positioned.fill(
      child: Transform.translate(
        offset: shift ?? Offset.zero,
        child: MouseRegion(
          hitTestBehavior: HitTestBehavior.deferToChild,
          onEnter: (_) => _pointerEntered(ability.id),
          onExit: (_) => _pointerExited(),
          child: CustomPaint(
            painter: WallPainter(
              line: smoothWallLine(wall.points(path)),
              team: wallTeamColor(
                ability.isAlly,
                neutralTeamColors: settings.useNeutralTeamColors,
              ),
              width: wallStrokeWidth(mapScale),
              edge: wallStrokeEdge(),
            ),
          ),
        ),
      ),
    );
  }
}

/// A wall riding its icon's drag, around [child], the icon's feedback. Inside
/// the drag's own scale, so it needs none of its own.
class WallFeedback extends ConsumerWidget {
  const WallFeedback({
    super.key,
    required this.ability,
    required this.child,
  });

  final PlacedAbility ability;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ability.wallPath;
    if (path == null || path.isEmpty) return child;
    final mapState = ref.watch(mapProvider);
    final mapScale = Maps.mapScale[mapState.currentMap] ?? 1;
    final settings = ref.watch(strategySettingsProvider);
    final wall = WallOnScreen.of(
      ability,
      mapScale: mapScale,
      abilitySize: settings.abilitySize,
      isAttack: mapState.isAttack,
    );
    final coordinates = CoordinateSystem.instance;
    final middle = ability.data.abilityData!
        .getAnchorPoint(mapScale: mapScale, abilitySize: settings.abilitySize)
        .scale(coordinates.scaleFactor, coordinates.scaleFactor);
    final line = smoothWallLine(wall.points(path))
        .map((point) => point - wall.center + middle)
        .toList();
    return CustomPaint(
      painter: WallPainter(
        line: line,
        team: wallTeamColor(
          ability.isAlly,
          neutralTeamColors: settings.useNeutralTeamColors,
        ),
        width: wallStrokeWidth(mapScale),
        edge: wallStrokeEdge(),
      ),
      child: child,
    );
  }
}

/// The dots that shape [ability]'s wall, shown while it's hovered or selected:
/// white on each point, pale between them, and the wall's length at its end.
class PlacedWallHandles extends ConsumerStatefulWidget {
  const PlacedWallHandles({super.key, required this.ability});

  final PlacedAbility ability;

  @override
  ConsumerState<PlacedWallHandles> createState() => _PlacedWallHandlesState();
}

class _PlacedWallHandlesState extends ConsumerState<PlacedWallHandles>
    with _WallPointer<PlacedWallHandles> {
  /// The point of the path under the pointer, while a dot is dragged.
  int? _dragged;
  List<Offset> _path = const [];

  /// How long this drag may make the wall: its longest, or as long as it
  /// already was, so a wall past the limit can shrink and not grow.
  double _limit = 0;

  String get _id => widget.ability.id;

  double get _mapScale =>
      Maps.mapScale[ref.read(mapProvider).currentMap] ?? 1;

  double get _longest {
    final ability = widget.ability.data.abilityData as GuidedWallAbility;
    return ability.maxLengthMeters * wallWorldPerMeter(_mapScale);
  }

  /// Starts dragging point [index]. A new point starts at [at], on the wall,
  /// so it can't begin past the longest wall.
  void _begin(int index, {required bool adding, required Offset at}) {
    ref.read(wallHoverProvider.notifier).enter(_id);
    final current = [...?widget.ability.wallPath];
    _limit = math.max(_longest, wallPathLength(current));
    final path = adding
        ? wallPathWithPoint(current, index, at, limit: _limit)
        : current;
    _path = path;
    _dragged = index;
    ref.read(wallDraftProvider.notifier).set((id: _id, path: path));
  }

  /// Moves the dragged point to [target], stopping where the wall reaches
  /// [_limit].
  void _drag(Offset target) {
    final index = _dragged;
    if (index == null) return;
    List<Offset> withPoint(Offset point) =>
        [..._path]..[index] = point;
    var path = withPoint(target);
    if (wallPathLength(path) > _limit) {
      final from = _path[index];
      var near = 0.0;
      var far = 1.0;
      for (var i = 0; i < 12; i++) {
        final middle = (near + far) / 2;
        if (wallPathLength(withPoint(Offset.lerp(from, target, middle)!)) >
            _limit) {
          far = middle;
        } else {
          near = middle;
        }
      }
      path = withPoint(Offset.lerp(from, target, near)!);
    }
    _path = path;
    ref.read(wallDraftProvider.notifier).set((id: _id, path: path));
  }

  void _end() {
    if (_dragged == null) return;
    _dragged = null;
    ref.read(wallDraftProvider.notifier).set(null);
    ref.read(abilityProvider.notifier).setWallPath(_id, _path);
    // A pointer still on the dot keeps it showing. Touch never hovered.
    if (_heldId == null) ref.read(wallHoverProvider.notifier).leave(_id);
  }

  void _cancel() {
    if (_dragged == null) return;
    _dragged = null;
    ref.read(wallDraftProvider.notifier).set(null);
    if (_heldId == null) ref.read(wallHoverProvider.notifier).leave(_id);
  }

  @override
  void dispose() {
    // A pan under a disposed dot ends without a word, and its draft would
    // draw over the saved wall from then on.
    if (_dragged != null) {
      final container = _container!;
      final id = _id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Another finger may be shaping another wall by now.
        if (container.read(wallDraftProvider)?.id == id) {
          container.read(wallDraftProvider.notifier).set(null);
        }
      });
    }
    super.dispose();
  }

  void _removePoint(int index) {
    final path = [...?widget.ability.wallPath];
    path.removeAt(index);
    ref.read(abilityProvider.notifier).setWallPath(_id, path);
    _pointerExited();
  }

  Offset _local(Offset global) =>
      (context.findRenderObject()! as RenderBox).globalToLocal(global);

  Widget _dot({
    required Offset center,
    required double diameter,
    required bool pale,
    bool hidden = false,
    required void Function(Offset local) onStart,
    VoidCallback? onRemove,
    required WallOnScreen wall,
    required int pointIndex,
  }) {
    final size = CoordinateSystem.instance.scale(diameter);
    final hitSize = size + 6;
    return Positioned(
      key: ValueKey('wall-dot-${pale ? 'pale' : 'point'}-$pointIndex'),
      left: center.dx - hitSize / 2,
      top: center.dy - hitSize / 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        onEnter: (_) => _pointerEntered(_id),
        onExit: (_) => _pointerExited(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => onStart(_local(details.globalPosition)),
          onPanUpdate: (details) =>
              _drag(wall.saved(_local(details.globalPosition))),
          onPanEnd: (_) => _end(),
          onPanCancel: _cancel,
          onSecondaryTap: onRemove,
          child: SizedBox(
            width: hitSize,
            height: hitSize,
            child: Center(
              child: hidden ? null : Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: pale
                      ? Colors.white.withValues(alpha: 0.38)
                      : Colors.white,
                  border: pale
                      ? Border.all(color: Colors.white, width: 1)
                      : null,
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The page under a drag changed: what's held belongs to the last one.
    ref.listen(strategyProvider.select((state) => state.activePageId), (_, __) {
      _cancel();
    });
    final hovered = ref.watch(wallHoverProvider) == _id;
    // Touch has no hover: selecting the wall's icon shows its dots.
    final selected = ref.watch(
      canvasSelectionProvider.select(
        (selection) => selection.length == 1 && selection.single.id == _id,
      ),
    );
    final carried = ref.watch(wallCarriedProvider) == _id;
    final path = _draftPathOf(ref, _id) ?? widget.ability.wallPath;
    // A dot being dragged has to stay: taking it away would end the drag.
    if ((!hovered && !selected && _dragged == null) ||
        carried ||
        path == null ||
        path.isEmpty ||
        ref.watch(screenshotProvider)) {
      _releaseAfterFrame();
      return const SizedBox.shrink();
    }
    final mapState = ref.watch(mapProvider);
    final mapScale = Maps.mapScale[mapState.currentMap] ?? 1;
    final wall = WallOnScreen.of(
      widget.ability,
      mapScale: mapScale,
      abilitySize: ref.watch(strategySettingsProvider).abilitySize,
      isAttack: mapState.isAttack,
    );
    final points = wall.points(path);
    final meters = wallPathLength(path) / wallWorldPerMeter(mapScale);
    final data = widget.ability.data.abilityData as GuidedWallAbility;
    final atLongest = meters >= data.maxLengthMeters - 0.05;
    final dragging = _dragged != null;
    final canAdd = dragging || path.length < maxWallPathPoints;
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: points.last.dx + 12,
            top: points.last.dy - 12,
            child: IgnorePointer(
              child: CanvasTag(
                text: atLongest
                    ? '${data.maxLengthMeters.round()} m, the longest'
                    : '${meters.round()} m',
              ),
            ),
          ),
          if (canAdd)
            for (final (index, middle) in wallStretchMiddles(points).indexed)
              _dot(
                center: middle,
                diameter: _pullDotDiameter,
                pale: true,
                hidden: dragging,
                wall: wall,
                pointIndex: index,
                onStart: (local) {
                  _begin(index, adding: true, at: wall.saved(middle));
                  _drag(wall.saved(local));
                },
              ),
          for (var index = 0; index < path.length; index++)
            _dot(
              center: points[index + 1],
              diameter: _dotDiameter,
              pale: false,
              wall: wall,
              pointIndex: index,
              onStart: (_) => _begin(index, adding: false, at: Offset.zero),
              onRemove: path.length < 2 ? null : () => _removePoint(index),
            ),
        ],
      ),
    );
  }
}

/// A short label on the canvas, for what's under the pointer.
class CanvasTag extends StatelessWidget {
  const CanvasTag({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Settings.abilityBGColor,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Settings.tacticalVioletTheme.foreground,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
