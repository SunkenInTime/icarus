import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/replay/replay_ability_catalog.dart';
import 'package:icarus/replay/replay_cone_cuts.dart';
import 'package:icarus/replay/replay_agents.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_weapons.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/vision_occluders.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

/// One moment of a replay as Icarus draws it: the same placed widgets a page
/// holds. The viewer paints these, and capturing the moment saves them.
class ReplayFrame {
  const ReplayFrame({
    required this.timeMs,
    required this.round,
    required this.isAttack,
    required this.agents,
    required this.abilities,
    required this.utilities,
    this.occluders = const [],
    this.cones = const {},
    this.dimmed = const {},
    this.effects = const [],
  });

  final int timeMs;
  final ReplayRound? round;

  /// Whether the perspective team attacks this round: the side the map is
  /// drawn from, as in the editor.
  final bool isAttack;
  final List<PlacedAgentNode> agents;
  final List<PlacedAbility> abilities;
  final List<PlacedUtility> utilities;

  /// Smokes and smoke walls up at this moment, which cut the view cones.
  final List<VisionOccluder> occluders;

  /// Each living agent's latest cone cut, by agent id, when cones are cut
  /// on a worker (see [ReplayConeCuts]). Empty when each cone cuts its own.
  final Map<String, ReplayConeSource> cones;

  /// Abilities drawn faintly, by id: ranges and areas players stand in, so
  /// the agents and cones under them stay readable. Smokes stay solid.
  final Set<String> dimmed;

  /// What the viewer animates around the placed widgets: utility arriving,
  /// leaving, and in flight. Never part of a capture.
  final List<ReplayEffect> effects;

  List<PlacedWidget> get widgets => [...utilities, ...abilities, ...agents];
}

/// A player's view cone as drawn: where it is aimed now, and its latest cut
/// (see [ReplayConeCuts]), which may lag the aim by a frame or two and is
/// carried along to it. No cut yet draws no cone.
typedef ReplayConeSource = ({ReplayConeAim aim, ReplayConeCut? cut});

/// Something the viewer animates for a moment. Positions are canonical
/// world units, like placed widgets'.
sealed class ReplayEffect {
  const ReplayEffect({required this.isAlly});

  final bool isAlly;
}

/// A utility activating: a ring spreading from it as it arrives.
class ReplayActivation extends ReplayEffect {
  const ReplayActivation({
    required this.centre,
    required this.radius,
    required this.progress,
    required super.isAlly,
  });

  final Offset centre;

  /// How far the ring spreads, world units.
  final double radius;

  /// 0 as it activates, 1 when the ring has faded.
  final double progress;
}

/// A utility ending (destroyed, expired, or popped): its ability fading out
/// where it last stood, with a ring bursting from it.
class ReplayExit extends ReplayEffect {
  const ReplayExit({
    required this.ability,
    required this.centre,
    required this.radius,
    required this.progress,
    required this.dimmed,
    required super.isAlly,
  });

  final PlacedAbility ability;
  final Offset centre;
  final double radius;

  /// 0 as it ends, 1 when it is gone.
  final double progress;

  /// Whether the ability was drawn faintly while it was up.
  final bool dimmed;
}

/// A thrown utility in flight: its ability's icon where it is now, and the
/// path it took over the last moment.
class ReplayFlight extends ReplayEffect {
  const ReplayFlight({
    required this.iconPath,
    required this.trail,
    required super.isAlly,
  });

  final String iconPath;

  /// Oldest first; the last point is where it is now.
  final List<Offset> trail;
}

/// How a player stands at one moment.
class ReplayPlayerState {
  const ReplayPlayerState({
    required this.player,
    required this.alive,
    this.pose,
    this.health,
    this.armor,
  });

  final ReplayPlayer player;
  final bool alive;

  /// Where they are, or where they fell. Null when they have not appeared yet
  /// this round.
  final ReplayPose? pose;
  final double? health;
  final double? armor;
}

/// Builds frames from a decoded replay. Holds the per-replay lookups so a
/// frame per animation tick stays cheap.
class ReplayFrameBuilder {
  ReplayFrameBuilder(this.document, this.projection);

  final ReplayDocument document;
  final ReplayMapProjection projection;

  /// The map's attack-side SVG height model, once loaded. Until then cones
  /// stand on the level they pick by themselves.
  SvgHeightVisibility? heightModel;

  /// Cone length the editor allows at most; walls cut it down.
  static const coneLength = ViewConeUtility.maxLength;

  late final Map<String, List<ReplayKill>> _deathsBySubject = () {
    final deaths = <String, List<ReplayKill>>{};
    for (final kill in document.kills) {
      (deaths[kill.victim] ??= []).add(kill);
    }
    return deaths;
  }();

  /// Each utility's catalog entry, looked up once rather than every frame.
  late final List<ReplayAbilityEntry?> _entries = [
    for (final utility in document.utility) replayAbilityFor(utility.classPath),
  ];

  /// The owner of each utility actor when the replay does not name one but
  /// only one player could have cast it.
  late final Map<AgentType, ReplayPlayer?> _soleCasterByAgent = () {
    final byAgent = <AgentType, ReplayPlayer?>{};
    for (final player in document.players) {
      final agent = replayAgentType(player.agentId);
      if (agent == null) continue;
      byAgent[agent] = byAgent.containsKey(agent) ? null : player;
    }
    return byAgent;
  }();

  /// Whether [player] is alive at [timeMs]: whichever came last this round
  /// of the round starting (alive), a health reading (alive above 0, which
  /// sees revives) and a recorded death.
  bool isAlive(ReplayPlayer player, int timeMs, ReplayRound? round) {
    final roundStart = round?.startMs ?? 0;
    var alive = true;
    var decidedAt = roundStart;
    final vitals = document.vitals[player.subject]?.at(timeMs);
    if (vitals != null && vitals.timeMs >= roundStart) {
      alive = vitals.health > 0;
      decidedAt = vitals.timeMs;
    }
    final death = _lastDeathBefore(player.subject, timeMs);
    if (death != null && death.timeMs >= decidedAt) alive = false;
    return alive;
  }

  /// [player] at [timeMs]. Their pose may be taken at [poseTimeMs] instead,
  /// a moment earlier, when playback moves players a few at a time.
  ReplayPlayerState playerState(
    ReplayPlayer player,
    int timeMs, {
    int? poseTimeMs,
  }) {
    final round = document.roundAt(timeMs);
    final poseTime = poseTimeMs ?? timeMs;
    final roundStart = round?.startMs ?? 0;
    final alive = isAlive(player, timeMs, round);
    final track = document.movement[player.subject];
    ReplayPose? pose;
    if (track != null) {
      if (alive) {
        // A quiet stream means standing still, not vanishing.
        pose = track.poseAt(poseTime) ??
            track.heldPose(poseTime, notBeforeMs: roundStart);
      } else {
        // Dead this round: keep where they fell.
        final death = _lastDeathBefore(player.subject, timeMs);
        if (death != null && death.timeMs >= roundStart) {
          pose = track.heldPose(death.timeMs, notBeforeMs: roundStart);
        }
      }
    }
    final vitals = document.vitals[player.subject]?.at(timeMs);
    final vitalsCurrent = vitals != null && vitals.timeMs >= roundStart;
    return ReplayPlayerState(
      player: player,
      alive: alive,
      pose: pose,
      health: vitalsCurrent ? vitals.health : null,
      armor: vitalsCurrent ? vitals.armor : null,
    );
  }

  ReplayKill? _lastDeathBefore(String subject, int timeMs) {
    ReplayKill? last;
    for (final death in _deathsBySubject[subject] ?? const []) {
      if (death.timeMs > timeMs) break;
      last = death;
    }
    return last;
  }

  /// The spike stays planted until it is defused, it detonates, or the
  /// round ends.
  static int _spikeGoneMs(ReplayRound round) => [
        round.endMs,
        if (round.defuse case final defuse?) defuse.timeMs,
        if (round.detonateMs case final detonateMs?) detonateMs,
      ].reduce(math.min);

  static bool _onCanvas(Offset world) =>
      world.dx >= 0 &&
      world.dy >= 0 &&
      world.dx <= SvgHeightMapTransform.worldWidth &&
      world.dy <= SvgHeightMapTransform.worldHeight;

  /// The level the player stands on, when it is not the one the cone picks.
  double? _visionElevation(ReplayPose pose) {
    final model = heightModel;
    if (model == null) return null;
    final p = pose.position;
    return projection.visionElevationFor(model, p.x, p.y, p.z);
  }

  ReplayPlayer? ownerOf(ReplayUtility utility, ReplayAbilityEntry entry) =>
      document.playerBySubject(utility.owner) ??
      _soleCasterByAgent[entry.agent];

  /// How long a utility's arrival ring and its exit last.
  static const activationMs = 450;
  static const exitMs = 500;

  /// How much of a thrown utility's path trails behind it.
  static const trailMs = 350;

  /// The moment at [timeMs]. With [cuts], each living player's cone is
  /// asked for where they are now and drawn from its latest cut; see
  /// [ReplayFrame.cones].
  ReplayFrame frameAt(
    int timeMs, {
    required ReplayTeam perspective,
    ReplayConeCuts? cuts,
  }) {
    final round = document.roundAt(timeMs);
    final isAttack = (round?.attackingTeam ?? ReplayTeam.red) == perspective;
    final agentAnchor = CoordinateSystem.virtualToWorld(storedAgentAnchor);

    final agents = <PlacedAgentNode>[];
    final cones = <String, ReplayConeSource>{};
    for (final player in document.players) {
      final type = replayAgentType(player.agentId);
      final team = player.team;
      // Without an agent or a team there is nothing honest to draw.
      if (type == null || team == null) continue;
      final state = playerState(player, timeMs);
      final pose = state.pose;
      if (pose == null) continue;
      final standing = projection.toWorld(pose.position.x, pose.position.y);
      // Iso's Kill Contract duels in an arena off the map; while there, the
      // player has no place on it (the roster still lists them).
      if (!_onCanvas(standing)) continue;
      final position = standing - agentAnchor;
      final isAlly = team == perspective;
      final id = 'replay-player-${player.subject}';
      final visionElevation = _visionElevation(pose);
      final rotation = projection.rotationForYaw(pose.yaw);
      if (state.alive && cuts != null) {
        final aim = ReplayConeAim(
          origin: standing,
          rotation: rotation,
          isAttack: isAttack,
          elevationCm: visionElevation,
        );
        cuts.want(player.subject, aim);
        final cut = cuts.latest(player.subject);
        cones[id] = (
          aim: aim,
          // A cut from the other side's map is no cut at all.
          cut: cut != null && cut.aim.isAttack == isAttack ? cut : null,
        );
      }
      // What they carried out of the buy phase.
      final weapon =
          replayWeaponType(round?.economyFor(player.subject)?.weapon);
      agents.add(
        state.alive
            ? PlacedViewConeAgent(
                id: id,
                type: type,
                position: position,
                presetType: UtilityType.viewCone180,
                rotation: rotation,
                length: coneLength,
                visionElevation: visionElevation,
                isAlly: isAlly,
                weapon: weapon,
              )
            : PlacedAgent(
                id: id,
                type: type,
                position: position,
                isAlly: isAlly,
                state: AgentState.dead,
                weapon: weapon,
              ),
      );
    }

    final abilities = <PlacedAbility>[];
    final occluders = <VisionOccluder>[];
    final dimmed = <String>{};
    final effects = <ReplayEffect>[];
    final mapScale = Maps.mapScale[projection.map] ?? 1.0;
    for (var i = 0; i < document.utility.length; i++) {
      final utility = document.utility[i];
      if (utility.spawnMs > timeMs) break;
      final endMs = utility.endMs;
      final active = utility.isActiveAt(timeMs);
      // An ending utility lingers a moment to fade out.
      final leaving = !active && endMs != null && timeMs - endMs < exitMs;
      if (!active && !leaving) continue;
      final entry = _entries[i];
      if (entry == null) continue;
      final owner = ownerOf(utility, entry);
      // An unknown owner among duplicate agents would be a guess at the
      // team colour; leave it out instead.
      final ownerTeam = owner?.team;
      if (ownerTeam == null) continue;
      final isAlly = ownerTeam == perspective;

      if (entry.kind == ReplayUtilityKind.flight) {
        if (active) {
          effects.add(ReplayFlight(
            iconPath: entry.ability.iconPath,
            trail: [
              for (final point in utility.trail(timeMs - trailMs, timeMs))
                projection.toWorld(point.x, point.y),
            ],
            isAlly: isAlly,
          ));
        }
        continue;
      }

      // Where it last stood, for one that has just ended.
      final shownAt = active ? timeMs : endMs! - 1;
      final ability = entry.place(
        utility: utility,
        projection: projection,
        timeMs: shownAt,
        id: 'replay-utility-${utility.id}',
        isAlly: isAlly,
      );
      final at = utility.positionAt(shownAt);
      final centre = projection.toWorld(at.x, at.y);
      final radius = _radiusOf(entry, mapScale);
      final faint =
          (entry.kind == ReplayUtilityKind.area && entry.blocks == null) ||
              entry.kind == ReplayUtilityKind.rectangle;
      if (!active) {
        effects.add(ReplayExit(
          ability: ability,
          centre: centre,
          radius: radius,
          progress: (timeMs - endMs!) / exitMs,
          dimmed: faint,
          isAlly: isAlly,
        ));
        continue;
      }
      abilities.add(ability);
      if (faint) dimmed.add(ability.id);
      final occluder = _occluderOf(entry, utility, timeMs, centre, radius);
      if (occluder != null) occluders.add(occluder);
      final age = timeMs - utility.spawnMs;
      if (age < activationMs) {
        effects.add(ReplayActivation(
          centre: centre,
          radius: radius,
          progress: age / activationMs,
          isAlly: isAlly,
        ));
      }
    }

    final utilities = <PlacedUtility>[];
    final plant = round?.plant;
    final plantedAt = plant?.position;
    if (round != null &&
        plant != null &&
        plantedAt != null &&
        timeMs >= plant.timeMs &&
        timeMs < _spikeGoneMs(round)) {
      final spike = PlacedUtility(
        id: 'replay-spike-${round.index}',
        type: UtilityType.spike,
        position: Offset.zero,
      );
      spike.position = projection.toWorld(plantedAt.x, plantedAt.y) -
          CoordinateSystem.virtualToWorld(
            storedUtilityAnchor(
              utility: spike,
              mapScale: Maps.mapScale[projection.map]!,
            ),
          );
      utilities.add(spike);
    }

    return ReplayFrame(
      timeMs: timeMs,
      round: round,
      isAttack: isAttack,
      agents: agents,
      abilities: abilities,
      utilities: utilities,
      occluders: occluders,
      cones: cones,
      dimmed: dimmed,
      effects: effects,
    );
  }

  /// How far an ability reaches from its centre, world units: half of a
  /// circle or image as drawn (smoke art fills its square to the edge),
  /// otherwise about an icon's width.
  static double _radiusOf(ReplayAbilityEntry entry, double mapScale) {
    final virtual = switch (entry.ability.abilityData) {
      CircleAbility(:final size) || ImageAbility(:final size) =>
        size * mapScale / 2,
      _ => 18.0,
    };
    return CoordinateSystem.virtualLengthInWorld(virtual);
  }

  /// What [utility] hides from sight now, when it is a smoke or a wall of
  /// smoke or fire.
  VisionOccluder? _occluderOf(
    ReplayAbilityEntry entry,
    ReplayUtility utility,
    int timeMs,
    Offset centre,
    double radius,
  ) {
    switch (entry.blocks) {
      case null:
        return null;
      case ReplayVisionBlock.sphere:
        return CircleOccluder(centre, radius);
      case ReplayVisionBlock.line:
        // A wall raised point by point stands along its points; a guided
        // one (High Tide) along where its head has been.
        final points = utility.points.length >= 2
            ? utility.points
            : utility.trail(utility.spawnMs, timeMs);
        if (points.length < 2) return null;
        return LineOccluder([
          for (final point in points) projection.toWorld(point.x, point.y),
        ]);
    }
  }
}
