import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/replay/replay_ability_catalog.dart';
import 'package:icarus/replay/replay_agents.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_weapons.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
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
  });

  final int timeMs;
  final ReplayRound? round;

  /// Whether the perspective team attacks this round: the side the map is
  /// drawn from, as in the editor.
  final bool isAttack;
  final List<PlacedAgentNode> agents;
  final List<PlacedAbility> abilities;
  final List<PlacedUtility> utilities;

  List<PlacedWidget> get widgets => [...utilities, ...abilities, ...agents];
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
  static const _coneLength = ViewConeUtility.maxLength;

  late final Map<String, List<ReplayKill>> _deathsBySubject = () {
    final deaths = <String, List<ReplayKill>>{};
    for (final kill in document.kills) {
      (deaths[kill.victim] ??= []).add(kill);
    }
    return deaths;
  }();

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

  /// The moment at [timeMs]. [poseTimeOf] may give a player's pose an
  /// earlier time; see [ReplayPlayerState] and `ReplayPlayback.frame`.
  ReplayFrame frameAt(
    int timeMs, {
    required ReplayTeam perspective,
    int Function(ReplayPlayer player)? poseTimeOf,
  }) {
    final round = document.roundAt(timeMs);
    final isAttack = (round?.attackingTeam ?? ReplayTeam.red) == perspective;
    final agentAnchor = CoordinateSystem.virtualToWorld(storedAgentAnchor);

    final agents = <PlacedAgentNode>[];
    for (final player in document.players) {
      final type = replayAgentType(player.agentId);
      final team = player.team;
      // Without an agent or a team there is nothing honest to draw.
      if (type == null || team == null) continue;
      final state = playerState(
        player,
        timeMs,
        poseTimeMs: poseTimeOf?.call(player),
      );
      final pose = state.pose;
      if (pose == null) continue;
      final standing = projection.toWorld(pose.position.x, pose.position.y);
      // Iso's Kill Contract duels in an arena off the map; while there, the
      // player has no place on it (the roster still lists them).
      if (!_onCanvas(standing)) continue;
      final position = standing - agentAnchor;
      final isAlly = team == perspective;
      final id = 'replay-player-${player.subject}';
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
                rotation: projection.rotationForYaw(pose.yaw),
                length: _coneLength,
                visionElevation: _visionElevation(pose),
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
    for (final utility in document.utility) {
      if (utility.spawnMs > timeMs) break;
      if (!utility.isActiveAt(timeMs)) continue;
      final entry = replayAbilityFor(utility.classPath);
      if (entry == null) continue;
      final owner = ownerOf(utility, entry);
      // An unknown owner among duplicate agents would be a guess at the
      // team colour; leave it out instead.
      final ownerTeam = owner?.team;
      if (ownerTeam == null) continue;
      abilities.add(
        entry.place(
          utility: utility,
          projection: projection,
          timeMs: timeMs,
          id: 'replay-utility-${utility.id}',
          isAlly: ownerTeam == perspective,
        ),
      );
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
    );
  }
}
