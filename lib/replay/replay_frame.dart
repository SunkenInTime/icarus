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

  /// Whether [player] is alive at [timeMs]. Health is the truth when the
  /// replay has it (it sees revives); otherwise the player is dead from their
  /// death until the next round starts.
  bool isAlive(ReplayPlayer player, int timeMs, ReplayRound? round) {
    final vitals = document.vitals[player.subject]?.at(timeMs);
    if (vitals != null) return vitals.health > 0;
    final roundStart = round?.startMs ?? 0;
    for (final death in _deathsBySubject[player.subject] ?? const []) {
      if (death.timeMs >= roundStart && death.timeMs <= timeMs) return false;
    }
    return true;
  }

  ReplayPlayerState playerState(ReplayPlayer player, int timeMs) {
    final round = document.roundAt(timeMs);
    final alive = isAlive(player, timeMs, round);
    final track = document.movement[player.subject];
    ReplayPose? pose = track?.poseAt(timeMs);
    if (!alive && pose == null && track != null) {
      // The body is gone from the stream; keep where it fell.
      final death = _lastDeathBefore(player.subject, timeMs);
      if (death != null) {
        final index = track.indexAtOrBefore(death.timeMs);
        if (index >= 0) pose = track.poseAtIndex(index);
      }
    }
    final vitals = document.vitals[player.subject]?.at(timeMs);
    return ReplayPlayerState(
      player: player,
      alive: alive,
      pose: pose,
      health: vitals?.health,
      armor: vitals?.armor,
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

  ReplayPlayer? ownerOf(ReplayUtility utility, ReplayAbilityEntry entry) =>
      document.playerBySubject(utility.owner) ??
      _soleCasterByAgent[entry.agent];

  ReplayFrame frameAt(int timeMs, {required ReplayTeam perspective}) {
    final round = document.roundAt(timeMs);
    final isAttack = (round?.attackingTeam ?? ReplayTeam.red) == perspective;
    final coordinates = CoordinateSystem.instance;
    final agentAnchor = coordinates.virtualOffsetToWorld(storedAgentAnchor);

    final agents = <PlacedAgentNode>[];
    for (final player in document.players) {
      final type = replayAgentType(player.agentId);
      if (type == null) continue;
      final state = playerState(player, timeMs);
      final pose = state.pose;
      if (pose == null) continue;
      final position =
          projection.toWorld(pose.position.x, pose.position.y) - agentAnchor;
      final isAlly = player.team == perspective;
      final id = 'replay-player-${player.subject}';
      agents.add(
        state.alive
            ? PlacedViewConeAgent(
                id: id,
                type: type,
                position: position,
                presetType: UtilityType.viewCone180,
                rotation: projection.rotationForYaw(pose.yaw),
                length: _coneLength,
                isAlly: isAlly,
              )
            : PlacedAgent(
                id: id,
                type: type,
                position: position,
                isAlly: isAlly,
                state: AgentState.dead,
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
      if (owner == null) continue;
      abilities.add(
        entry.place(
          utility: utility,
          projection: projection,
          timeMs: timeMs,
          id: 'replay-utility-${utility.id}',
          isAlly: owner.team == perspective,
        ),
      );
    }

    final utilities = <PlacedUtility>[];
    final plant = round?.plant;
    if (round != null &&
        plant != null &&
        timeMs >= plant.timeMs &&
        timeMs < round.endMs) {
      final spike = PlacedUtility(
        id: 'replay-spike-${round.index}',
        type: UtilityType.spike,
        position: Offset.zero,
      );
      spike.position = projection.toWorld(plant.position.x, plant.position.y) -
          coordinates.virtualOffsetToWorld(
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
