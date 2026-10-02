import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/map_svg_color_mapper.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
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
                const Color(0xff18181b),
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
                      for (final placed in widgets)
                        staticPlacedWidgetView(
                          widget: placed,
                          mapScale: Maps.mapScale[widget.map]!,
                          abilitySize:
                              preferences.defaultAbilitySizeForNewStrategies,
                          agentSize:
                              preferences.defaultAgentSizeForNewStrategies,
                          isAttack: isAttack,
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
