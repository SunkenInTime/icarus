import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/map_svg_color_mapper.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:icarus/widgets/replay/replay_cones.dart';
import 'package:icarus/widgets/replay/replay_effects.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The map as the editor draws it, with the replay's current moment on top.
/// Pans and zooms like the editor; [reservedRight] keeps the map clear of the
/// roster panel.
class ReplayCanvas extends ConsumerStatefulWidget {
  const ReplayCanvas({
    super.key,
    required this.playback,
    required this.map,
    required this.reservedRight,
  });

  final ReplayPlayback playback;
  final MapValue map;
  final double reservedRight;

  @override
  ConsumerState<ReplayCanvas> createState() => _ReplayCanvasState();
}

/// How strongly ranges and areas players stand in are drawn, so the agents
/// and cones beneath stay readable.
const _rangeOpacity = 0.3;

/// [view] drawn at [opacity]. A placed widget comes back positioned on the
/// canvas, so the fade goes inside its position.
Widget _faded(Widget view, double opacity) {
  if (view is! Positioned) return Opacity(opacity: opacity, child: view);
  return Positioned(
    key: view.key,
    left: view.left,
    top: view.top,
    right: view.right,
    bottom: view.bottom,
    width: view.width,
    height: view.height,
    child: Opacity(opacity: opacity, child: view.child),
  );
}

class _ReplayCanvasState extends ConsumerState<ReplayCanvas> {
  final _controller = TransformationController();
  Size? _lastViewport;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The theme a captured strategy starts with, so the map looks the same
  /// here and in the editor afterwards.
  MapSvgColorMapper _colorMapper() {
    final profiles = ref.watch(mapThemeProfilesProvider);
    final profile = profiles.profiles.firstWhere(
      (profile) => profile.id == profiles.defaultProfileIdForNewStrategies,
      orElse: () => MapThemeProfilesProvider.immutableDefaultProfile,
    );
    return MapSvgColorMapper.forPalette(profile.palette);
  }

  @override
  Widget build(BuildContext context) {
    final colorMapper = _colorMapper();
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
        if (_lastViewport != viewport) {
          _lastViewport = viewport;
          _controller.value = Matrix4.identity()
            ..translateByDouble((viewportWidth - worldWidth) / 2, 0, 0, 1);
        }
        final mapWidth = height * coordinates.mapAspectRatio;
        final mapLeft = (worldWidth - mapWidth) / 2;

        return DecoratedBox(
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
            boundaryMargin: const EdgeInsets.all(double.infinity),
            child: SizedBox(
              width: worldWidth,
              height: height,
              child: ListenableBuilder(
                listenable: widget.playback,
                builder: (context, _) {
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
                              colorMapper: colorMapper,
                              fit: BoxFit.contain,
                            ),
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
                          view(exit.ability),
                          (1 - exit.progress) *
                              (exit.dimmed ? _rangeOpacity : 1),
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
                      if (cuts != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: ReplayConesPainter(
                                cones: frame.cones.values,
                                occluders: frame.occluders,
                                model: isAttack
                                    ? cuts.attackModel
                                    : cuts.defenseModel,
                                map: widget.map,
                                isAttack: isAttack,
                              ),
                            ),
                          ),
                        ),
                      for (final placed in widgets)
                        if (placed is PlacedAgentNode)
                          cuts == null
                              ? view(placed)
                              : ViewConesDrawnElsewhere(
                                  key: ValueKey(placed.id),
                                  child: view(placed),
                                ),
                    ],
                  );
                },
              ),
            ),
          ),
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
                  ? _faded(widget.view(placed), _rangeOpacity)
                  : widget.view(placed),
          ],
        ),
      );
    }
    return _shown!;
  }
}
