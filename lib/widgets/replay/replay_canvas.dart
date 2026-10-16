import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/view_cone/cone_coverage.dart';
import 'package:icarus/replay/replay_drawing.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_range_opacity.dart';
import 'package:icarus/widgets/map_svg_color_mapper.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:icarus/widgets/replay/replay_cones.dart';
import 'package:icarus/widgets/replay/replay_drawing_layer.dart';
import 'package:icarus/widgets/replay/replay_effects.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The map as the editor draws it, with the replay's current moment on top
/// and what the user drew over it above that. Pans and zooms like the
/// editor, except that while the pen is out a drag draws instead of
/// panning; [reservedRight] keeps the map clear of the roster panel.
class ReplayCanvas extends ConsumerStatefulWidget {
  const ReplayCanvas({
    super.key,
    required this.playback,
    required this.drawing,
    required this.map,
    required this.reservedRight,
  });

  final ReplayPlayback playback;
  final ReplayDrawing drawing;
  final MapValue map;
  final double reservedRight;

  @override
  ConsumerState<ReplayCanvas> createState() => _ReplayCanvasState();
}

/// How strongly ranges and areas players stand in are drawn, so the agents
/// and cones beneath stay readable. Their icons stay solid.
const _rangeOpacity = 0.3;

/// [view] with [wrap] around it. A placed widget comes back positioned on
/// the canvas, so the wrapper goes inside its position.
Widget _inside(Widget view, Widget Function(Widget) wrap) {
  if (view is! Positioned) return wrap(view);
  return Positioned(
    key: view.key,
    left: view.left,
    top: view.top,
    right: view.right,
    bottom: view.bottom,
    width: view.width,
    height: view.height,
    child: wrap(view.child),
  );
}

/// [view] drawn at [opacity].
Widget _faded(Widget view, double opacity) =>
    _inside(view, (child) => Opacity(opacity: opacity, child: child));

/// [view] at [opacity]. At full strength it is left unwrapped: an
/// [Opacity] is a layer of its own, which no agent should cost while no one
/// is watched.
Widget _steppedBack(Widget view, double opacity) =>
    opacity == 1 ? view : _faded(view, opacity);

/// [view] with its range drawn faint and its icon solid.
Widget _faintRange(Widget view) => _inside(
    view, (child) => AbilityRangeOpacity(opacity: _rangeOpacity, child: child));

/// How strongly everyone but the watched player is drawn, so the one being
/// watched stands out.
const _othersOpacity = 0.55;

/// How close the camera comes, at least, to a player picked to watch.
const _watchScale = 2.0;

/// How far past its icon's edge a click still picks an agent, as a share of
/// the icon's radius.
const _agentHitSlop = 0.25;

/// Where [agent]'s icon is centred on the canvas, in canvas pixels.
Offset _agentCentre(PlacedAgentNode agent, {required bool isAttack}) {
  final coordinates = CoordinateSystem.instance;
  final anchor = CoordinateSystem.virtualToWorld(storedAgentAnchor);
  return coordinates.coordinateToScreen(coordinates.positionForSide(
    canonicalPosition: agent.position + anchor,
    reflectionOffset: Offset.zero,
    isAttack: isAttack,
  ));
}

/// The agent drawn under [point], in canvas pixels: of those whose icon
/// (drawn [agentSize] across, grown a little) holds it, the nearest.
@visibleForTesting
PlacedAgentNode? replayAgentAt(
  Iterable<PlacedAgentNode> agents,
  Offset point, {
  required bool isAttack,
  required double agentSize,
}) {
  var reach =
      CoordinateSystem.instance.scale(agentSize) / 2 * (1 + _agentHitSlop);
  PlacedAgentNode? nearest;
  for (final agent in agents) {
    final distance = (_agentCentre(agent, isAttack: isAttack) - point).distance;
    if (distance > reach) continue;
    reach = distance;
    nearest = agent;
  }
  return nearest;
}

/// The camera looking at [focus] (canvas pixels) from the centre of
/// [viewport], at [scale].
@visibleForTesting
Matrix4 replayCameraOn(Offset focus, double scale, Size viewport) =>
    Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        viewport.width / 2 - focus.dx * scale,
        viewport.height / 2 - focus.dy * scale,
        0,
      );

/// [camera] held so the [world] box stays in view: along each axis the box
/// covers [viewport] when it is the larger, moved no further than that
/// takes, and sits centred in it when it is the smaller. The map can never
/// be panned away.
@visibleForTesting
Matrix4 replayCameraClamped(Matrix4 camera, Size world, Size viewport) {
  final scale = camera.getMaxScaleOnAxis();
  final at = camera.getTranslation();
  double held(double from, double content, double room) => content <= room
      ? (room - content) / 2
      : from.clamp(room - content, 0.0);
  final x = held(at.x, world.width * scale, viewport.width);
  final y = held(at.y, world.height * scale, viewport.height);
  if (x == at.x && y == at.y) return camera;
  return camera.clone()..setTranslationRaw(x, y, at.z);
}

/// The canvas's camera, held to [replayCameraClamped] however it moves: a
/// pan, a zoom, or following a player.
class _MapCamera extends TransformationController {
  /// The box the dot grid and map are drawn in, in canvas pixels.
  Size world = Size.zero;

  /// The part of the canvas the roster leaves clear.
  Size viewport = Size.zero;

  /// While set, only [place] moves the camera. A fling still coasting from
  /// before a player was picked would otherwise carry it off them.
  bool held = false;

  @override
  set value(Matrix4 camera) {
    if (!held) place(camera);
  }

  /// Moves the camera, held or not.
  void place(Matrix4 camera) => super.value =
      world.isEmpty ? camera : replayCameraClamped(camera, world, viewport);
}

class _ReplayCanvasState extends ConsumerState<ReplayCanvas>
    with SingleTickerProviderStateMixin {
  final _controller = _MapCamera();
  Size? _lastViewport;

  /// The agents' own cones, while no worker cuts them (it is starting, or
  /// it failed), painted together as in the editor.
  final _cones = ConeCoverage();

  /// Carries the camera to a player picked to watch; once there, it keeps
  /// them centred each frame.
  late final AnimationController _approach;
  var _approaching = false;

  /// Where the camera looked, and how close, as the approach began, and how
  /// close it ends.
  var _approachFrom = Offset.zero;
  var _approachFromScale = 1.0;
  var _approachToScale = 1.0;

  /// The player the camera follows, by subject.
  String? _followed;

  /// Whether the user's hands are on the map: a drag, a pinch, a scroll.
  var _touching = false;

  /// Whether a drag pans, as it does unless the pen is out.
  late bool _panEnabled = !widget.drawing.active;

  @override
  void initState() {
    super.initState();
    // Made here, not on first use: a canvas that never watched anyone
    // would otherwise make it in dispose, after its ticker mode is gone.
    _approach = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(_follow);
    widget.playback.addListener(_playbackChanged);
    widget.drawing.addListener(_drawingChanged);
  }

  @override
  void didUpdateWidget(ReplayCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      oldWidget.playback.removeListener(_playbackChanged);
      widget.playback.addListener(_playbackChanged);
    }
    if (oldWidget.drawing == widget.drawing) return;
    oldWidget.drawing.removeListener(_drawingChanged);
    widget.drawing.addListener(_drawingChanged);
    _panEnabled = !widget.drawing.active;
  }

  void _drawingChanged() {
    if (_panEnabled == !widget.drawing.active) return;
    setState(() => _panEnabled = !widget.drawing.active);
  }

  @override
  void dispose() {
    widget.playback.removeListener(_playbackChanged);
    _approach.dispose();
    widget.drawing.removeListener(_drawingChanged);
    _controller.dispose();
    _cones.dispose();
    super.dispose();
  }

  /// Starts following a player as they are picked, and keeps them centred
  /// as they move.
  void _playbackChanged() {
    final playback = widget.playback;
    final followed = playback.following ? playback.watching : null;
    if (followed != _followed) {
      _followed = followed;
      _holdCamera();
      if (followed != null) {
        _approachWatched();
      } else {
        _approach.stop();
        _approaching = false;
      }
      return;
    }
    if (followed != null && !_approach.isAnimating) _follow();
  }

  /// Glides to the watched player, coming in to [_watchScale] when further
  /// out than that.
  void _approachWatched() {
    final viewport = _lastViewport;
    if (viewport == null) return;
    final scale = _controller.value.getMaxScaleOnAxis();
    _approachFrom = _controller.toScene(viewport.center(Offset.zero));
    _approachFromScale = scale;
    _approachToScale = math.max(scale, _watchScale);
    _approaching = true;
    _approach.forward(from: 0);
  }

  /// Centres the watched player in the part of the canvas the roster leaves
  /// clear, as nearly as the map's edges allow; part way there while
  /// approaching.
  void _follow() {
    final viewport = _lastViewport;
    final at = _watchedCentre();
    if (viewport == null || at == null) return;
    var focus = at;
    var scale = _controller.value.getMaxScaleOnAxis();
    if (_approaching) {
      final t = Curves.easeOutCubic.transform(_approach.value);
      focus = Offset.lerp(_approachFrom, at, t)!;
      scale = lerpDouble(_approachFromScale, _approachToScale, t)!;
      if (_approach.value == 1) _approaching = false;
    }
    _controller.place(replayCameraOn(focus, scale, viewport));
  }

  /// While following, the camera answers only to the follow and to the
  /// user's own hands.
  void _holdCamera() => _controller.held = _followed != null && !_touching;

  /// Where the watched player's icon is, when they are on the map.
  Offset? _watchedCentre() {
    final subject = widget.playback.watching;
    if (subject == null) return null;
    final frame = widget.playback.frame;
    final id = ReplayFrameBuilder.agentIdOf(subject);
    for (final agent in frame.agents) {
      if (agent.id == id) return _agentCentre(agent, isAttack: frame.isAttack);
    }
    return null;
  }

  /// A click on an agent watches them; one on empty map does nothing, so
  /// the watch is never lost by accident. [point] is in canvas pixels.
  void _tapped(Offset point) {
    // With the pen out, a click is the start of a stroke.
    if (widget.drawing.active) return;
    final playback = widget.playback;
    final frame = playback.frame;
    final agent = replayAgentAt(
      frame.agents,
      point,
      isAttack: frame.isAttack,
      agentSize:
          ref.read(appPreferencesProvider).defaultAgentSizeForNewStrategies,
    );
    if (agent == null) return;
    for (final player in playback.document.players) {
      if (ReplayFrameBuilder.agentIdOf(player.subject) == agent.id) {
        playback.watch(player.subject);
        return;
      }
    }
  }

  /// Zooming keeps the followed player centred; moving the map by hand
  /// stops following them.
  void _interactionStarted(ScaleStartDetails details) {
    _approach.stop();
    _approaching = false;
    _touching = true;
    _holdCamera();
  }

  /// The coasting that follows a fling is not the user's hands.
  void _interactionEnded(ScaleEndDetails details) {
    _touching = false;
    _holdCamera();
  }

  void _interactionUpdated(ScaleUpdateDetails details) {
    final playback = widget.playback;
    if (!playback.following) return;
    if (details.scale == 1 && details.focalPointDelta != Offset.zero) {
      playback.stopFollowing();
    } else {
      _follow();
    }
  }

  /// The theme a captured strategy starts with, so the map looks the same
  /// here and in the editor afterwards.
  MapThemePalette _palette() {
    final profiles = ref.watch(mapThemeProfilesProvider);
    final profile = profiles.profiles.firstWhere(
      (profile) => profile.id == profiles.defaultProfileIdForNewStrategies,
      orElse: () => MapThemeProfilesProvider.immutableDefaultProfile,
    );
    return profile.palette;
  }

  @override
  Widget build(BuildContext context) {
    final palette = _palette();
    // Marker sizes a captured strategy starts with, for the same reason.
    final preferences = ref.watch(appPreferencesProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final worldWidth = height * 16 / 9;
        CoordinateSystem(playAreaSize: Size(worldWidth, height));
        final coordinates = CoordinateSystem.instance;
        final viewportWidth = (constraints.maxWidth - widget.reservedRight)
            .clamp(0.0, constraints.maxWidth);
        final viewport = Size(viewportWidth, height);
        _controller
          ..world = Size(worldWidth, height)
          ..viewport = viewport;
        if (_lastViewport != viewport) {
          _lastViewport = viewport;
          _controller.place(Matrix4.identity()
            ..translateByDouble((viewportWidth - worldWidth) / 2, 0, 0, 1));
          if (widget.playback.following) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _follow();
            });
          }
        }
        final mapWidth = height * coordinates.mapAspectRatio;
        final mapLeft = (worldWidth - mapWidth) / 2;

        final canvas = DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 1.5,
              colors: [
                ShadTheme.of(context).colorScheme.card,
                ShadTheme.of(context).colorScheme.background,
              ],
            ),
          ),
          child: InteractiveViewer(
            transformationController: _controller,
            constrained: false,
            alignment: Alignment.topLeft,
            minScale: 1,
            maxScale: 8,
            panEnabled: _panEnabled,
            // The camera keeps the map in view itself. The viewer's own
            // bounds would count the space under the roster as room, and
            // would zoom in past 1 on a canvas wider than the map's box.
            boundaryMargin: const EdgeInsets.all(double.infinity),
            onInteractionStart: _interactionStarted,
            onInteractionUpdate: _interactionUpdated,
            onInteractionEnd: _interactionEnded,
            child: SizedBox(
              width: worldWidth,
              height: height,
              child: ListenableBuilder(
                listenable: widget.playback,
                // Built once here, not every frame: it repaints only when
                // the strokes change.
                child: ReplayDrawingLayer(
                  drawing: widget.drawing,
                  playback: widget.playback,
                ),
                builder: (context, strokes) {
                  final frame = widget.playback.frame;
                  final isAttack = frame.isAttack;
                  final mapName = Maps.mapNames[widget.map];
                  final widgets = frame.widgets
                    ..sort(PageLayering.comparePlacedWidgets);
                  final mapScale = Maps.mapScale[widget.map]!;
                  final abilitySize =
                      preferences.defaultAbilitySizeForNewStrategies;
                  final agentSize =
                      preferences.defaultAgentSizeForNewStrategies;
                  Widget view(PlacedWidget placed) => staticPlacedWidgetView(
                        widget: placed,
                        mapScale: mapScale,
                        abilitySize: abilitySize,
                        agentSize: agentSize,
                        isAttack: isAttack,
                      );
                  final exits = frame.effects.whereType<ReplayExit>();
                  // Cones cut on the worker are drawn in one layer.
                  final cuts = widget.playback.coneCuts;
                  final flights = frame.effects.whereType<ReplayFlight>();
                  final flashed = {
                    for (final flash in frame.effects.whereType<ReplayFlashed>())
                      flash.agentId: flash,
                  };
                  // While one player is watched, everyone else steps back.
                  // The watched agent is never wrapped, so its cone keeps
                  // its state; the rest are drawn without cones.
                  final watching = widget.playback.watching;
                  final watchedId = watching == null
                      ? null
                      : ReplayFrameBuilder.agentIdOf(watching);
                  // The watched agent is drawn last, so no one stands on
                  // them.
                  final agents = [
                    for (final placed in widgets)
                      if (placed is PlacedAgentNode && placed.id != watchedId)
                        placed,
                    for (final placed in widgets)
                      if (placed is PlacedAgentNode && placed.id == watchedId)
                        placed,
                  ];
                  double opacityOf(PlacedWidget placed) =>
                      watchedId == null || placed.id == watchedId
                          ? 1
                          : _othersOpacity;
                  // The map as cones reveal it.
                  final revealedMap = Stack(
                    children: [
                      Positioned(
                        left: mapLeft,
                        top: 0,
                        width: mapWidth,
                        height: height,
                        child: CanonicalMapArtwork(
                          map: widget.map,
                          isAttack: isAttack,
                          child: SvgPicture.asset(
                            'assets/maps/${mapName}_map'
                            '${isAttack ? '' : '_defense'}.svg',
                            colorMapper: MapSvgColorMapper.revealed(palette),
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ],
                  );
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Positioned.fill(
                        child: Padding(
                          padding: EdgeInsets.all(4),
                          child: RepaintBoundary(child: DotGrid()),
                        ),
                      ),
                      Positioned(
                        left: mapLeft,
                        top: 0,
                        width: mapWidth,
                        height: height,
                        child: RepaintBoundary(
                          child: CanonicalMapArtwork(
                            map: widget.map,
                            isAttack: isAttack,
                            child: SvgPicture.asset(
                              'assets/maps/${mapName}_map'
                              '${isAttack ? '' : '_defense'}.svg',
                              colorMapper: MapSvgColorMapper.forPalette(palette),
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                      // View cones: the map as they reveal it, shown
                      // wherever one reaches, under everything placed (as in
                      // the editor). Without a worker, the agents' own cones
                      // join a coverage layer instead.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: switch (cuts) {
                            final cuts? => RevealedFloor(
                                cones: ReplayConesPainter(
                                  cones: frame.cones.values,
                                  occluders: frame.occluders,
                                  model: isAttack
                                      ? cuts.attackModel
                                      : cuts.defenseModel,
                                  map: widget.map,
                                  isAttack: isAttack,
                                  apertureDegrees: cuts.apertureDegrees,
                                ),
                                floor: SvgHeightMapTransform.forMap(
                                        widget.map)
                                    .floorOnScreen(
                                  isAttack
                                      ? cuts.attackModel
                                      : cuts.defenseModel,
                                  isAttack: isAttack,
                                ),
                                child: revealedMap,
                              ),
                            null => ConeCoverageLayer(
                                coverage: _cones,
                                child: revealedMap,
                              ),
                          },
                        ),
                      ),
                      // Areas swept so far, under the icons they run from.
                      for (final sweep
                          in frame.effects.whereType<ReplaySweep>())
                        Positioned.fill(
                          child: IgnorePointer(
                            child: _steppedBack(
                              ClipPath(
                                clipper: ReplaySweepClipper(
                                  sweep: sweep,
                                  isAttack: isAttack,
                                  iconSide: CoordinateSystem.instance
                                      .scale(abilitySize),
                                ),
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [view(sweep.area)],
                                ),
                              ),
                              sweep.opacity,
                            ),
                          ),
                        ),
                      // Utility moves far less than players do: its own
                      // layer, rebuilt only when it changes, so its
                      // picture (faded ranges and all) is drawn from cache.
                      Positioned.fill(
                        child: _UtilityLayer(
                          // How it is drawn, beyond the pieces themselves.
                          look: (isAttack, abilitySize, mapScale, height),
                          placed: [
                            for (final placed in widgets)
                              if (placed is! PlacedAgentNode) placed,
                          ],
                          dimmed: frame.dimmed,
                          view: view,
                        ),
                      ),
                      for (final exit in exits)
                        _faded(
                          exit.dimmed
                              ? _faintRange(view(exit.ability))
                              : view(exit.ability),
                          1 - exit.progress,
                        ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: ReplayEffectsPainter(
                              effects: frame.effects,
                              isAttack: isAttack,
                              iconSize:
                                  CoordinateSystem.instance.scale(abilitySize),
                            ),
                          ),
                        ),
                      ),
                      for (final flight in flights)
                        ReplayFlightIcon(
                          flight: flight,
                          isAttack: isAttack,
                          abilitySize: abilitySize,
                        ),
                      for (final placed in agents) ...[
                          cuts == null
                              ? ConeCoverageScope(
                                  key: ValueKey(placed.id),
                                  coverage: _cones,
                                  child: _steppedBack(
                                      view(placed), opacityOf(placed)),
                                )
                              : ViewConesDrawnElsewhere(
                                  key: ValueKey(placed.id),
                                  child: _steppedBack(
                                      view(placed), opacityOf(placed)),
                                ),
                          // Washed with its agent, under any stacked above.
                          if (flashed[placed.id] case final flash?)
                            Positioned.fill(
                              key: ValueKey('flash-${placed.id}'),
                              child: IgnorePointer(
                                child: _steppedBack(
                                  CustomPaint(
                                    painter: ReplayFlashPainter(
                                      flash: flash,
                                      isAttack: isAttack,
                                      agentSize: agentSize,
                                      neutralTeamColors: ref
                                          .watch(strategySettingsProvider)
                                          .useNeutralTeamColors,
                                    ),
                                  ),
                                  opacityOf(placed),
                                ),
                              ),
                            ),
                        ],
                      // What the user drew, above everything on the map.
                      Positioned.fill(child: strokes!),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) =>
              _tapped(_controller.toScene(details.localPosition)),
          child: canvas,
        );
      },
    );
  }
}

/// The utility on the map, rebuilt only when a piece of it appears, moves,
/// turns or goes, and kept on its own layer so an unchanged picture is
/// reused rather than redrawn every frame.
class _UtilityLayer extends StatefulWidget {
  const _UtilityLayer({
    required this.look,
    required this.placed,
    required this.dimmed,
    required this.view,
  });

  final Object look;
  final List<PlacedWidget> placed;
  final Set<String> dimmed;
  final Widget Function(PlacedWidget placed) view;

  @override
  State<_UtilityLayer> createState() => _UtilityLayerState();
}

class _UtilityLayerState extends State<_UtilityLayer> {
  List<Object?>? _shownKey;
  Widget? _shown;

  /// What the layer draws, as values: each piece's identity and placement.
  List<Object?> get _key => [
        widget.look,
        for (final placed in widget.placed) ...[
          placed.id,
          placed.position,
          if (placed is PlacedAbility) ...[
            placed.rotation,
            placed.length,
            ...placed.armLengthsMeters,
          ],
          widget.dimmed.contains(placed.id),
        ],
      ];

  @override
  Widget build(BuildContext context) {
    final key = _key;
    if (_shown == null || !listEquals(key, _shownKey)) {
      _shownKey = key;
      _shown = RepaintBoundary(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final placed in widget.placed)
              widget.dimmed.contains(placed.id)
                  ? _faintRange(widget.view(placed))
                  : widget.view(placed),
          ],
        ),
      );
    }
    return _shown!;
  }
}
