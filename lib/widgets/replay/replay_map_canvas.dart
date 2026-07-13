import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/replay_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/replay/replay_ability_audit.dart';
import 'package:icarus/replay/replay_track.dart';
import 'package:icarus/replay/valorant_map_transform.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_view_cone_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const UtilityType _replayViewConeType = UtilityType.viewCone90;
const double _replayViewConeLength = 74;
const AbilityVisualState _replayProjectileVisualState = AbilityVisualState(
  showRangeOutline: false,
  showRangeFill: false,
  showInnerOutline: false,
  showInnerFill: false,
);

class _MapSvgColorMapper extends ColorMapper {
  const _MapSvgColorMapper(this.replacements);

  final Map<int, Color> replacements;

  @override
  Color substitute(
    String? id,
    String elementName,
    String attributeName,
    Color color,
  ) {
    final opaqueColorValue = (color.toARGB32() & 0x00FFFFFF) | 0xFF000000;
    final replacement = replacements[opaqueColorValue];
    if (replacement == null) {
      return color;
    }
    final alpha = (color.a * 255.0).round().clamp(0, 255);
    return replacement.withAlpha(alpha);
  }
}

class ReplayMapCanvas extends ConsumerStatefulWidget {
  const ReplayMapCanvas({super.key});

  @override
  ConsumerState<ReplayMapCanvas> createState() => _ReplayMapCanvasState();
}

class _ReplayMapCanvasState extends ConsumerState<ReplayMapCanvas> {
  static const Color _mapBaseSourceColor = Color(0xFF271406);
  static const Color _mapDetailSourceColor = Color(0xFFB27C40);
  static const Color _mapHighlightSourceColor = Color(0xFFF08234);

  final _controller = TransformationController();
  Size? _lastViewportSize;
  Size? _lastPlayAreaSize;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final replayState = ref.watch(replayProvider);
    final track = replayState.track;
    final effectivePalette = ref.watch(effectiveMapThemePaletteProvider);
    final mapColorMapper = _MapSvgColorMapper({
      _mapBaseSourceColor.toARGB32(): effectivePalette.baseColor,
      _mapDetailSourceColor.toARGB32(): effectivePalette.detailColor,
      _mapHighlightSourceColor.toARGB32(): effectivePalette.highlightColor,
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final worldWidth = height * (16 / 9);
        final playAreaSize = Size(worldWidth, height);
        CoordinateSystem(playAreaSize: playAreaSize);
        final coordinateSystem = CoordinateSystem.instance;
        final viewportSize = Size(constraints.maxWidth, height);

        if (_lastViewportSize != viewportSize ||
            _lastPlayAreaSize != playAreaSize) {
          final currentScale = _controller.value.getMaxScaleOnAxis();
          final safeScale = currentScale == 0 ? 1.0 : currentScale;
          final centeredOffsetX =
              (constraints.maxWidth - (worldWidth * safeScale)) / 2;
          final centeredOffsetY = (height - (height * safeScale)) / 2;
          final matrix = Matrix4.identity()
            ..scaleByDouble(safeScale, safeScale, safeScale, 1);
          matrix.translateByDouble(
            centeredOffsetX / safeScale,
            centeredOffsetY / safeScale,
            0,
            1,
          );
          _controller.value = matrix;
          _lastViewportSize = viewportSize;
          _lastPlayAreaSize = playAreaSize;
        }

        final map = track?.map ?? MapValue.ascent;
        final mapName = Maps.mapNames[map]!;
        final mapWidth = height * coordinateSystem.mapAspectRatio;
        final mapLeft = (worldWidth - mapWidth) / 2;
        final frames = track?.framesAt(
              replayState.currentTimeMs,
              visiblePlayerIds: replayState.visiblePlayerIds,
            ) ??
            const <ReplayPlayerFrame>[];

        return Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.45,
              colors: [
                const Color(0xff18181b),
                ShadTheme.of(context).colorScheme.background,
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _controller,
                  constrained: false,
                  alignment: Alignment.topLeft,
                  minScale: 1.0,
                  maxScale: 8.0,
                  child: SizedBox(
                    width: worldWidth,
                    height: height,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: replayState.pendingAuditMapIssue == null
                          ? null
                          : (details) => ref
                              .read(replayProvider.notifier)
                              .placePendingMapAudit(
                                coordinateSystem.screenToCoordinate(
                                  details.localPosition,
                                ),
                              ),
                      child: MouseRegion(
                        cursor: replayState.pendingAuditMapIssue == null
                            ? SystemMouseCursors.basic
                            : SystemMouseCursors.precise,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            const Positioned.fill(
                              child: Padding(
                                padding: EdgeInsets.all(4.0),
                                child: DotGrid(),
                              ),
                            ),
                            Positioned(
                              left: mapLeft,
                              top: 0,
                              width: mapWidth,
                              height: height,
                              child: SvgPicture.asset(
                                'assets/maps/${mapName}_map.svg',
                                colorMapper: mapColorMapper,
                                semanticsLabel: 'Replay map',
                                fit: BoxFit.contain,
                              ),
                            ),
                            Positioned(
                              left: mapLeft,
                              top: 0,
                              width: mapWidth,
                              height: height,
                              child: SvgPicture.asset(
                                'assets/maps/${mapName}_call_outs.svg',
                                semanticsLabel: 'Replay callouts',
                                fit: BoxFit.contain,
                              ),
                            ),
                            if (track != null)
                              Positioned.fill(
                                child: _ReplayOverlay(
                                  track: track,
                                  frames: frames,
                                  currentTimeMs: replayState.currentTimeMs,
                                  reviewWindowStartMs:
                                      replayState.reviewWindowStartMs,
                                  reviewWindowEndMs:
                                      replayState.reviewWindowEndMs,
                                  showReviewTrails:
                                      replayState.showReviewTrails,
                                  visiblePlayerIds:
                                      replayState.visiblePlayerIds,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (track == null) const Center(child: _EmptyReplayState()),
              if (replayState.pendingAuditMapIssue != null)
                Positioned(
                  top: 14,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _AuditPlacementPrompt(
                      issue: replayState.pendingAuditMapIssue!,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ReplayOverlay extends ConsumerWidget {
  const _ReplayOverlay({
    required this.track,
    required this.frames,
    required this.currentTimeMs,
    required this.reviewWindowStartMs,
    required this.reviewWindowEndMs,
    required this.showReviewTrails,
    required this.visiblePlayerIds,
  });

  final ReplayTrack track;
  final List<ReplayPlayerFrame> frames;
  final int currentTimeMs;
  final int reviewWindowStartMs;
  final int reviewWindowEndMs;
  final bool showReviewTrails;
  final Set<String> visiblePlayerIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final auditState = ref.watch(replayProvider);
    final activeUtilityActors = track.utilityActorsAt(currentTimeMs);
    final activeUtilityActorIds = {
      for (final actor in activeUtilityActors) actor.stableId,
    };
    final placementCasts = [
      for (final cast in track.abilityCastsAt(currentTimeMs))
        if (!cast.linkedUtilityActorIds.any(activeUtilityActorIds.contains))
          cast,
    ];
    final markers = [
      for (final frame in frames)
        _ResolvedReplayMarker(
          frame: frame,
          position: _samplePosition(track, frame.sample),
          angleRadians: _sampleAngle(track, frame.sample),
        ),
    ];

    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (showReviewTrails)
          Positioned.fill(
            child: CustomPaint(
              painter: _ReplayTrailPainter(
                coordinateSystem: coordinateSystem,
                track: track,
                visiblePlayerIds: visiblePlayerIds,
                startMs: reviewWindowStartMs,
                endMs: reviewWindowEndMs,
              ),
            ),
          ),
        for (final cast in placementCasts)
          for (final location in cast.displayLocations)
            _ReplayAbilityCastMarker(
              track: track,
              cast: cast,
              location: location,
            ),
        for (final utilityActor in activeUtilityActors)
          _ReplayUtilityActorMarker(
            track: track,
            utilityActor: utilityActor,
            currentTimeMs: currentTimeMs,
          ),
        if (auditState.abilityAuditEnabled)
          for (var index = 0;
              index < auditState.abilityAuditEntries.length;
              index += 1)
            if (auditState.abilityAuditEntries[index].icarusPosition != null)
              _ReplayAuditMapMarker(
                entry: auditState.abilityAuditEntries[index],
                number: index + 1,
              ),
        for (final marker in markers)
          _ReplayPlayerMarker(
            track: track,
            marker: marker,
            screenPosition: coordinateSystem.coordinateToScreen(
              marker.position,
            ),
          ),
      ],
    );
  }
}

class _ReplayUtilityActorMarker extends ConsumerWidget {
  const _ReplayUtilityActorMarker({
    required this.track,
    required this.utilityActor,
    required this.currentTimeMs,
  });

  final ReplayTrack track;
  final ReplayUtilityActor utilityActor;
  final int currentTimeMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final agent = _agentDataFromReplayName(
      utilityActor.icarusAgentType ?? utilityActor.agent,
    );
    final ability = _abilityInfoForUtilityActor(agent, utilityActor);
    final abilityData = ability?.abilityData;
    if (ability == null || abilityData == null) {
      return const SizedBox.shrink();
    }

    final mapScale = Maps.mapScale[track.map] ?? 1;
    final position = _utilityActorPosition(
      track,
      utilityActor,
      currentTimeMs,
    );
    final screenPosition = coordinateSystem.coordinateToScreen(position);
    final anchor = abilityData
        .getAnchorPoint(mapScale: mapScale, abilitySize: Settings.abilitySize)
        .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);
    final rotation = _utilityActorRotation(
      track,
      utilityActor,
      currentTimeMs,
    );
    final ownerIsAlly = _utilityActorOwnerIsAlly(
      track,
      utilityActor,
      currentTimeMs,
    );
    final abilityChild = abilityData.createWidget(
      id: null,
      isAlly: ownerIsAlly ?? true,
      mapScale: mapScale,
      rotation: rotation,
      length: 0,
      visualState: _visualStateForUtilityActor(utilityActor),
      watchMouse: false,
    );
    final child = _withUnknownOwnerTreatment(abilityChild, ownerIsAlly);

    final selectedTarget = ref.watch(replayProvider).selectedAbilityAuditTarget;
    final selected = selectedTarget?.matches(
          ReplayAbilityAuditTargetType.utilityActor,
          utilityActor.stableId,
        ) ??
        false;
    return Positioned(
      left: screenPosition.dx - anchor.dx,
      top: screenPosition.dy - anchor.dy,
      child: GestureDetector(
        onTap: () => ref
            .read(replayProvider.notifier)
            .selectUtilityActor(utilityActor.stableId),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: selected
                ? Border.all(
                    color: Settings.tacticalVioletTheme.primary,
                    width: 2,
                  )
                : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: isRotatable(abilityData)
              ? Transform.rotate(
                  angle: rotation,
                  alignment: Alignment.topLeft,
                  origin: anchor,
                  child: child,
                )
              : child,
        ),
      ),
    );
  }
}

class _ReplayAbilityCastMarker extends ConsumerWidget {
  const _ReplayAbilityCastMarker({
    required this.track,
    required this.cast,
    required this.location,
  });

  final ReplayTrack track;
  final ReplayAbilityCast cast;
  final ReplayActorPosition location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final agent = _agentDataForAbilityCast(track, cast);
    final ability = _abilityInfoForAbilityCast(agent, cast);
    final abilityData = ability?.abilityData;
    if (ability == null || abilityData == null) {
      return const SizedBox.shrink();
    }

    final mapScale = Maps.mapScale[track.map] ?? 1;
    final position = _replayPositionToIcarus(track, location);
    final screenPosition = coordinateSystem.coordinateToScreen(position);
    final anchor = abilityData
        .getAnchorPoint(mapScale: mapScale, abilitySize: Settings.abilitySize)
        .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);
    const rotation = 0.0;
    final ownerIsAlly = _abilityCastOwnerIsAlly(track, cast);
    final abilityChild = abilityData.createWidget(
      id: null,
      isAlly: ownerIsAlly ?? true,
      mapScale: mapScale,
      rotation: rotation,
      length: 0,
      watchMouse: false,
    );
    final child = _withUnknownOwnerTreatment(abilityChild, ownerIsAlly);

    final selectedTarget = ref.watch(replayProvider).selectedAbilityAuditTarget;
    final selected = selectedTarget?.matches(
          ReplayAbilityAuditTargetType.abilityCast,
          cast.id,
        ) ??
        false;
    return Positioned(
      left: screenPosition.dx - anchor.dx,
      top: screenPosition.dy - anchor.dy,
      child: GestureDetector(
        onTap: () =>
            ref.read(replayProvider.notifier).selectAbilityCast(cast.id),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: selected
                ? Border.all(
                    color: Settings.tacticalVioletTheme.primary,
                    width: 2,
                  )
                : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: isRotatable(abilityData)
              ? Transform.rotate(
                  angle: rotation,
                  alignment: Alignment.topLeft,
                  origin: anchor,
                  child: child,
                )
              : child,
        ),
      ),
    );
  }
}

class _ReplayAuditMapMarker extends StatelessWidget {
  const _ReplayAuditMapMarker({required this.entry, required this.number});

  final ReplayAbilityAuditEntry entry;
  final int number;

  @override
  Widget build(BuildContext context) {
    final point = CoordinateSystem.instance.coordinateToScreen(
      entry.icarusPosition!,
    );
    return Positioned(
      left: point.dx - 11,
      top: point.dy - 11,
      child: IgnorePointer(
        child: Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Settings.tacticalVioletTheme.primary,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xfffafafa), width: 1.5),
            boxShadow: const [Settings.cardForegroundBackdrop],
          ),
          child: Text(
            '$number',
            style: const TextStyle(
              color: Color(0xfffafafa),
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _AuditPlacementPrompt extends ConsumerWidget {
  const _AuditPlacementPrompt({required this.issue});

  final ReplayAbilityAuditIssue issue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Settings.tacticalVioletTheme.primary),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.my_location, size: 16, color: Color(0xfffafafa)),
          const SizedBox(width: 8),
          Text(
            issue == ReplayAbilityAuditIssue.missing
                ? 'Click where the missing ability should be'
                : 'Click the correct ability position',
            style: const TextStyle(
              color: Color(0xfffafafa),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          ShadIconButton.ghost(
            onPressed: ref.read(replayProvider.notifier).cancelPendingMapAudit,
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }
}

AbilityVisualState? _visualStateForUtilityActor(
  ReplayUtilityActor utilityActor,
) {
  if (utilityActor.isProjectilePhase) return _replayProjectileVisualState;
  return null;
}

class _ReplayTrailPainter extends CustomPainter {
  const _ReplayTrailPainter({
    required this.coordinateSystem,
    required this.track,
    required this.visiblePlayerIds,
    required this.startMs,
    required this.endMs,
  });

  final CoordinateSystem coordinateSystem;
  final ReplayTrack track;
  final Set<String> visiblePlayerIds;
  final int startMs;
  final int endMs;

  @override
  void paint(Canvas canvas, Size size) {
    for (final player in track.players) {
      if (!visiblePlayerIds.contains(player.id)) continue;
      final samples = player.samplesBetween(startMs, endMs);
      if (samples.isEmpty) continue;

      final color = player.teamColor;
      final path = Path();
      var hasContinuousSegment = false;
      for (var index = 0; index < samples.length; index += 1) {
        final sample = samples[index];
        final point = coordinateSystem.coordinateToScreen(
          _samplePosition(track, sample),
        );
        if (index == 0 ||
            sample.timeMs - samples[index - 1].timeMs >
                ReplayPlayerTrack.maxInterpolationGapMs) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
          hasContinuousSegment = true;
        }
      }

      if (hasContinuousSegment) {
        canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: 0.34)
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = coordinateSystem.scale(2.2),
        );
      }

      for (final sample in samples) {
        final point = coordinateSystem.coordinateToScreen(
          _samplePosition(track, sample),
        );
        canvas.drawCircle(
          point,
          coordinateSystem.scale(3.2),
          Paint()..color = color.withValues(alpha: 0.54),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ReplayTrailPainter oldDelegate) {
    return oldDelegate.track != track ||
        oldDelegate.visiblePlayerIds != visiblePlayerIds ||
        oldDelegate.startMs != startMs ||
        oldDelegate.endMs != endMs ||
        oldDelegate.coordinateSystem != coordinateSystem;
  }
}

class _ResolvedReplayMarker {
  const _ResolvedReplayMarker({
    required this.frame,
    required this.position,
    required this.angleRadians,
  });

  final ReplayPlayerFrame frame;
  final Offset position;
  final double angleRadians;
}

class _ReplayPlayerMarker extends StatelessWidget {
  const _ReplayPlayerMarker({
    required this.track,
    required this.marker,
    required this.screenPosition,
  });

  final ReplayTrack track;
  final _ResolvedReplayMarker marker;
  final Offset screenPosition;

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final actor = _ReplayActorVisualData.fromMarker(track, marker);
    final agent = actor.agent;
    final scaledSize = coordinateSystem.scale(actor.agentSize);
    if (agent != null) {
      final anchor = ViewConeWidget.anchorPointVirtual.scale(
        coordinateSystem.scaleFactor,
        coordinateSystem.scaleFactor,
      );

      return Positioned(
        left: screenPosition.dx - anchor.dx,
        top: screenPosition.dy - anchor.dy,
        child: IgnorePointer(
          child: ViewConeAgentComposite(
            agent: actor.asPlacedViewConeAgent(agent.type),
            rotation: actor.viewConeRotation,
            length: _replayViewConeLength,
            forcedAgentSize: actor.agentSize,
          ),
        ),
      );
    }

    return _UnknownReplayActorWithViewCone(
      actor: actor,
      screenPosition: screenPosition,
      scaledMarkerSize: scaledSize,
    );
  }
}

class _ReplayActorVisualData {
  const _ReplayActorVisualData({
    required this.frame,
    required this.isAlly,
    required this.teamColor,
    required this.state,
    this.stateSample,
    required this.agentSize,
    required this.viewConeRotation,
    this.agent,
  });

  final ReplayPlayerFrame frame;
  final bool isAlly;
  final Color teamColor;
  final AgentState state;
  final ReplayPlayerStateSample? stateSample;
  final double agentSize;
  final double viewConeRotation;
  final AgentData? agent;

  factory _ReplayActorVisualData.fromMarker(
    ReplayTrack track,
    _ResolvedReplayMarker marker,
  ) {
    final frame = marker.frame;
    final stateSample = frame.player.stateSampleAt(frame.sample.timeMs);
    final isAlly = _isReplayActorAlly(
      track,
      frame.player,
      frame.sample.timeMs,
    );
    return _ReplayActorVisualData(
      frame: frame,
      agent: _agentDataFromReplayName(frame.player.agent),
      isAlly: isAlly,
      teamColor: isAlly ? Settings.allyBGColor : Settings.enemyBGColor,
      state: stateSample?.state ?? frame.player.stateAt(frame.sample),
      stateSample: stateSample,
      agentSize: Settings.agentSize,
      viewConeRotation: _viewConeRotationFromCanvasRadians(
        marker.angleRadians,
      ),
    );
  }

  PlacedViewConeAgent asPlacedViewConeAgent(AgentType type) {
    return PlacedViewConeAgent(
      type: type,
      position: Offset.zero,
      id: '',
      isAlly: isAlly,
      state: state,
      presetType: _replayViewConeType,
      rotation: viewConeRotation,
      length: _replayViewConeLength,
    );
  }

  // Future replay ability-recognition overlays should branch from this visual
  // data object so identity, life state, equipped ability, and frame position
  // stay together.
}

class _UnknownReplayActorWithViewCone extends StatelessWidget {
  const _UnknownReplayActorWithViewCone({
    required this.actor,
    required this.screenPosition,
    required this.scaledMarkerSize,
  });

  final _ReplayActorVisualData actor;
  final Offset screenPosition;
  final double scaledMarkerSize;

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final anchor = ViewConeWidget.anchorPointVirtual.scale(
      coordinateSystem.scaleFactor,
      coordinateSystem.scaleFactor,
    );
    final topLeft = screenPosition - anchor;
    final size = Size(
      coordinateSystem.scale(ViewConeWidget.totalWidthVirtual),
      coordinateSystem.scale(ViewConeWidget.totalHeightVirtual),
    );

    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      width: size.width,
      height: size.height,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: actor.viewConeRotation,
          alignment: Alignment.topLeft,
          origin: anchor,
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ViewConeWidget(
                  id: null,
                  angle: UtilityData.getViewConeAngle(_replayViewConeType),
                  length: _replayViewConeLength,
                  showCenterMarker: false,
                ),
                Positioned(
                  left: anchor.dx - (scaledMarkerSize / 2),
                  top: anchor.dy - (scaledMarkerSize / 2),
                  child: Transform.rotate(
                    angle: -actor.viewConeRotation,
                    child: _UnknownReplayActorMarker(
                      actor: actor,
                      scaledSize: scaledMarkerSize,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnknownReplayActorMarker extends StatelessWidget {
  const _UnknownReplayActorMarker({
    required this.actor,
    required this.scaledSize,
  });

  final _ReplayActorVisualData actor;
  final double scaledSize;

  @override
  Widget build(BuildContext context) {
    final color =
        actor.state == AgentState.dead ? Colors.grey.shade700 : actor.teamColor;

    return Container(
      width: scaledSize,
      height: scaledSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(scaledSize / 2),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.72),
          width: 1.4,
        ),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      child: Text(
        actor.state == AgentState.dead ? 'X' : '?',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyReplayState extends StatelessWidget {
  const _EmptyReplayState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 360,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: const Text(
        'Load a replay track JSON or open the demo track to inspect player paths.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, height: 1.35),
      ),
    );
  }
}

Offset _samplePosition(ReplayTrack track, ReplaySample sample) {
  switch (track.coordinateSpace) {
    case ReplayCoordinateSpace.game:
      return ValorantMapTransforms.gameToIcarus(
        map: track.map,
        gameX: sample.x,
        gameY: sample.y,
      );
    case ReplayCoordinateSpace.percent:
      return ValorantMapTransforms.percentToIcarus(u: sample.x, v: sample.y);
    case ReplayCoordinateSpace.icarus:
      return Offset(sample.x, sample.y);
  }
}

double _sampleAngle(ReplayTrack track, ReplaySample sample) {
  switch (track.coordinateSpace) {
    case ReplayCoordinateSpace.game:
      return ValorantMapTransforms.gameYawToCanvasRadians(
        map: track.map,
        gameX: sample.x,
        gameY: sample.y,
        yawDegrees: sample.yawDegrees,
      );
    case ReplayCoordinateSpace.percent:
    case ReplayCoordinateSpace.icarus:
      return sample.yawDegrees * math.pi / 180.0;
  }
}

double _viewConeRotationFromCanvasRadians(double angleRadians) {
  return angleRadians + (math.pi / 2);
}

Offset _replayPositionToIcarus(
  ReplayTrack track,
  ReplayActorPosition position,
) {
  switch (track.coordinateSpace) {
    case ReplayCoordinateSpace.game:
      return ValorantMapTransforms.gameToIcarus(
        map: track.map,
        gameX: position.x,
        gameY: position.y,
      );
    case ReplayCoordinateSpace.percent:
      return ValorantMapTransforms.percentToIcarus(
        u: position.x,
        v: position.y,
      );
    case ReplayCoordinateSpace.icarus:
      return Offset(position.x, position.y);
  }
}

Offset _utilityActorPosition(
  ReplayTrack track,
  ReplayUtilityActor actor,
  int currentTimeMs,
) {
  return _replayPositionToIcarus(track, actor.positionAt(currentTimeMs));
}

double _utilityActorRotation(
  ReplayTrack track,
  ReplayUtilityActor actor,
  int currentTimeMs,
) {
  final yawDegrees = actor.yawDegreesAt(currentTimeMs);
  if (yawDegrees == null) return 0;
  final position = actor.positionAt(currentTimeMs);

  final canvasRadians = switch (track.coordinateSpace) {
    ReplayCoordinateSpace.game => ValorantMapTransforms.gameYawToCanvasRadians(
        map: track.map,
        gameX: position.x,
        gameY: position.y,
        yawDegrees: yawDegrees,
      ),
    ReplayCoordinateSpace.percent ||
    ReplayCoordinateSpace.icarus =>
      yawDegrees * math.pi / 180.0,
  };
  return _viewConeRotationFromCanvasRadians(canvasRadians);
}

AbilityInfo? _abilityInfoForAbilityCast(
  AgentData? agent,
  ReplayAbilityCast cast,
) {
  if (agent == null) return null;

  final index = _abilityIndexForAbilityCast(cast);
  if (index == null || index < 0 || index >= agent.abilities.length) {
    return null;
  }
  return agent.abilities[index];
}

AgentData? _agentDataForAbilityCast(
  ReplayTrack track,
  ReplayAbilityCast cast,
) {
  return _agentDataFromReplayName(cast.icarusAgentType ?? cast.agent) ??
      _agentDataFromReplayName(
          track.playerByNetGuid(cast.playerNetGuid)?.agent) ??
      _agentDataFromReplayName(cast.sourceAbilityClass);
}

AbilityInfo? _abilityInfoForUtilityActor(
  AgentData? agent,
  ReplayUtilityActor actor,
) {
  if (agent == null) return null;

  final index = _abilityIndexForUtilityActor(actor);
  if (index == null || index < 0 || index >= agent.abilities.length) {
    return null;
  }
  return agent.abilities[index];
}

int? _abilityIndexForAbilityCast(ReplayAbilityCast cast) {
  return _abilityIndexForSlotAndFallback(cast.abilitySlot, cast.abilityIndex);
}

int? _abilityIndexForUtilityActor(ReplayUtilityActor actor) {
  return _abilityIndexForSlotAndFallback(actor.abilitySlot, actor.abilityIndex);
}

int? _abilityIndexForSlotAndFallback(String? slotValue, int? fallback) {
  // The parser emits app-facing indexes when an agent has a non-standard
  // visual layout (currently Miks has five visuals across four replay slots).
  // Prefer that explicit identity and retain slot mapping for older tracks.
  if (fallback != null && fallback >= 0) return fallback;

  final slot = slotValue?.trim().toLowerCase();
  switch (slot) {
    case 'c':
    case 'grenade':
    case 'ability0':
      return 0;
    case 'q':
    case 'ability1':
      return 1;
    case 'e':
    case 'ability2':
    case 'signature':
      return 2;
    case 'x':
    case 'ultimate':
    case 'ability3':
      return 3;
  }
  return null;
}

AgentData? _agentDataFromReplayName(String? value) {
  final normalized = _normalizeAgentName(value);
  if (normalized.isEmpty) return null;

  final alias = _replayAgentAliases[normalized] ??
      _replayAgentAliases[_agentPathToken(value)];
  if (alias != null) {
    return AgentData.agents[alias];
  }

  for (final agent in AgentData.agents.values) {
    if (_normalizeAgentName(agent.name) == normalized) return agent;
  }

  return null;
}

bool? _abilityCastOwnerIsAlly(
  ReplayTrack track,
  ReplayAbilityCast cast,
) {
  final owner = track.playerByNetGuid(cast.playerNetGuid) ??
      track.playerBySubject(cast.playerSubject);
  if (owner == null) return null;
  return _knownReplayAbilityOwnerIsAlly(track, owner, cast.timeMs);
}

bool? _utilityActorOwnerIsAlly(
  ReplayTrack track,
  ReplayUtilityActor actor,
  int timeMs,
) {
  var owner = track.playerByNetGuid(actor.ownerPlayerNetGuid) ??
      track.playerBySubject(actor.ownerSubject);
  if (owner == null && actor.sourceCastId != null) {
    final sourceCast = track.abilityCastById(actor.sourceCastId);
    owner = track.playerByNetGuid(sourceCast?.playerNetGuid) ??
        track.playerBySubject(sourceCast?.playerSubject);
  }
  if (owner == null) return null;
  return _knownReplayAbilityOwnerIsAlly(track, owner, timeMs);
}

bool? _knownReplayAbilityOwnerIsAlly(
  ReplayTrack track,
  ReplayPlayerTrack player,
  int timeMs,
) {
  final initialIsAlly = _initialReplayActorIsAlly(player);
  if (initialIsAlly == null) return null;
  final switchCount =
      track.sideSwitchEvents.where((event) => event.timeMs <= timeMs).length;
  return switchCount.isOdd ? !initialIsAlly : initialIsAlly;
}

Widget _withUnknownOwnerTreatment(Widget child, bool? ownerIsAlly) {
  if (ownerIsAlly != null) return child;
  return ColorFiltered(
    colorFilter: const ColorFilter.matrix(<double>[
      0.2126,
      0.7152,
      0.0722,
      0,
      0,
      0.2126,
      0.7152,
      0.0722,
      0,
      0,
      0.2126,
      0.7152,
      0.0722,
      0,
      0,
      0,
      0,
      0,
      0.72,
      0,
    ]),
    child: child,
  );
}

bool _isReplayActorAlly(
  ReplayTrack track,
  ReplayPlayerTrack player,
  int timeMs,
) {
  final initialIsAlly = _initialReplayActorIsAlly(player);
  if (initialIsAlly != null) {
    if (track.sideSwitchEvents.isNotEmpty) {
      final switchCount = track.sideSwitchEvents
          .where((event) => event.timeMs <= timeMs)
          .length;
      return switchCount.isOdd ? !initialIsAlly : initialIsAlly;
    }

    // Compatibility for older track JSON that predates switchTeams events.
    final roundIndex = _roundIndexAt(track.roundStartEvents, timeMs);
    if (roundIndex != null) {
      if (roundIndex >= 24) {
        return (roundIndex - 24).isOdd ? !initialIsAlly : initialIsAlly;
      }
      if (roundIndex >= 12) return !initialIsAlly;
    }
    return initialIsAlly;
  }

  final identity = '${player.id} ${player.displayName}'.toLowerCase();
  if (identity.contains('defender') ||
      identity.startsWith('d-') ||
      identity.contains(' d-')) {
    return true;
  }
  if (identity.contains('attacker') ||
      identity.startsWith('a-') ||
      identity.contains(' a-')) {
    return false;
  }

  final allyDistance = _colorDistance(player.teamColor, Settings.allyBGColor);
  final enemyDistance = _colorDistance(player.teamColor, Settings.enemyBGColor);
  return allyDistance <= enemyDistance;
}

bool? _initialReplayActorIsAlly(ReplayPlayerTrack player) {
  switch (player.initialSide) {
    case 'defender':
      return true;
    case 'attacker':
      return false;
  }

  final loadoutIndex = player.loadoutIndex;
  if (loadoutIndex != null) {
    if (loadoutIndex >= 0 && loadoutIndex < 5) return true;
    if (loadoutIndex >= 5 && loadoutIndex < 10) return false;
  }

  return null;
}

int? _roundIndexAt(List<ReplayRoundStartEvent> roundStartEvents, int timeMs) {
  int? current;
  for (var index = 0; index < roundStartEvents.length; index += 1) {
    final event = roundStartEvents[index];
    if (event.timeMs <= timeMs) {
      current = event.roundIndex ?? index;
    }
  }
  return current;
}

double _colorDistance(Color a, Color b) {
  final red = (a.r - b.r) * 255;
  final green = (a.g - b.g) * 255;
  final blue = (a.b - b.b) * 255;
  return (red * red) + (green * green) + (blue * blue);
}

String _normalizeAgentName(String? value) {
  return (value ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

String _agentPathToken(String? value) {
  final rawToken = (value ?? '')
      .split('/')
      .last
      .split('.')
      .last
      .replaceFirst(RegExp('^Default__', caseSensitive: false), '')
      .replaceFirst(RegExp('_PC_C\$', caseSensitive: false), '');
  return _normalizeAgentName(rawToken);
}

const Map<String, AgentType> _replayAgentAliases = {
  'aggrobot': AgentType.gekko,
  'astra': AgentType.astra,
  'bountyhunter': AgentType.fade,
  'breach': AgentType.breach,
  'cable': AgentType.deadlock,
  'cashew': AgentType.tejo,
  'kayo': AgentType.kayo,
  'pheonix': AgentType.pheonix,
  'phoenix': AgentType.pheonix,
  'clay': AgentType.raze,
  'deadeye': AgentType.chamber,
  'grenadier': AgentType.kayo,
  'guide': AgentType.skye,
  'gumshoe': AgentType.cypher,
  'harbor': AgentType.harbor,
  'hunter': AgentType.sova,
  'iris': AgentType.miks,
  'jett': AgentType.jett,
  'killjoy': AgentType.killjoy,
  'mage': AgentType.harbor,
  'miks': AgentType.miks,
  'nox': AgentType.vyse,
  'pandemic': AgentType.viper,
  'pine': AgentType.veto,
  'raze': AgentType.raze,
  'rift': AgentType.astra,
  'sage': AgentType.sage,
  'sarge': AgentType.brimstone,
  'sequoia': AgentType.iso,
  'smonk': AgentType.clove,
  'sprinter': AgentType.neon,
  'stealth': AgentType.yoru,
  'terra': AgentType.waylay,
  'thorne': AgentType.sage,
  'vampire': AgentType.reyna,
  'viper': AgentType.viper,
  'wraith': AgentType.omen,
  'wushu': AgentType.jett,
  'yoru': AgentType.yoru,
};
